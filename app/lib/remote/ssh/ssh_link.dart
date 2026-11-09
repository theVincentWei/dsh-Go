import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../../notify/apphub_base.dart' show appHubBase, kAppHubRemotePort, resetAppHubBase;
import '../link_status.dart';
import 'remote_bootstrap.dart';
import 'remote_shell.dart';
import 'ssh_host_config.dart';
import 'ssh_transport.dart';
import 'ssh_tunnel.dart';

/// What the person is asked on first contact with a host.
class HostKeyPrompt {
  const HostKeyPrompt({required this.hostName, required this.address, required this.key});

  final String hostName;
  final String address;
  final PresentedHostKey key;
}

/// Shows the "trust this host?" question; true to pin and continue.
typedef HostKeyPrompter = Future<bool> Function(HostKeyPrompt prompt);

/// Persists a newly trusted key for the host.
typedef HostKeyPinner = Future<void> Function(PresentedHostKey key);

/// Logs in to the `dsh web` behind the tunnel.
typedef DshClientConnector = Future<DshClient> Function({
  required Uri baseUri,
  required String token,
  required String hostHeader,
});

Future<DshClient> _defaultConnector({required Uri baseUri, required String token, required String hostHeader}) =>
    DshClient.connect(baseUri: baseUri, token: token, hostHeader: hostHeader);

/// Trust-on-first-use check against the pinned fingerprint.
enum HostKeyVerdict { trusted, unknown, mismatch }

HostKeyVerdict checkHostKey(SshHostConfig config, PresentedHostKey key) {
  final pinned = config.hostKeyFingerprint;
  if (pinned == null || pinned.isEmpty) return HostKeyVerdict.unknown;
  return pinned == key.fingerprint ? HostKeyVerdict.trusted : HostKeyVerdict.mismatch;
}

HostLinkError hostKeyMismatchError(SshHostConfig config, PresentedHostKey key) => HostLinkError(
  HostLinkErrorKind.hostKeyMismatch,
  appL10n.remoteErrFingerprintChanged,
  detail: appL10n.remoteHostKeyMismatchDetail(config.hostKeyFingerprint.toString(), key.fingerprint, key.shortType),
);

/// SSH remote host: connect → verify host key → start/reuse `dsh web` →
/// local forward → DshClient login; then keepalive and reconnect.
///
/// Mirrors dsh-tauri's SSH plugin flow (`bootstrap.utils.ts`, `transport.ts`):
/// the remote server binds 127.0.0.1 only, the token comes from its log, and
/// the client presents `Host: 127.0.0.1:<remote port>` so DSH's Host fence
/// accepts requests that arrive through the tunnel.
class SshHostLink implements HostLink {
  SshHostLink({
    required this._config,
    required this._loadSecrets,
    this.promptHostKey,
    this.pinHostKey,
    SshTunnel? tunnel,
    SshTransportFactory? transportFactory,
    DshClientConnector? connectClient,
    Stream<void>? kicks,
    Backoff? backoff,
    this.remoteEnvironment = const {},
    this.keepAliveInterval = const Duration(seconds: 15),
    this.keepAliveTimeout = const Duration(seconds: 10),
    this.tunnelProbeTimeout = const Duration(seconds: 10),
    this.retryFirstOpen = true,
    int? appHubLocalPort,
  }) : _tunnel = tunnel ??
           // A caller that names a transport factory runs the tunnel engine
           // in-process (tests with a fake server); without one, production
           // gets the engine in its own isolate, off the UI thread.
           (transportFactory != null
               ? LocalSshTunnel(
                   SshTunnelEngine(transportFactory: transportFactory, probeTimeout: tunnelProbeTimeout),
                 )
               : IsolateSshTunnel()),
       _connectClient = connectClient ?? _defaultConnector,
       // 退避不封顶(null = 永远重试,间隔 30s 封顶):主机卡死/离线一旦超过
       // 原 8 次预算(约 2-4 分钟),链路就永久躺平,只能杀 App 重连——主机
       // 恢复后永远等不到。非重试错误(密码/主机钥匙)仍走 _fail 停下等人。
       _backoff = backoff ?? Backoff(maxAttempts: null),
       // 小程序硬编码 127.0.0.1:7610(网关是后端唯一对外口),真机侧转发必须
       // 绑同一个固定口;测试注入别的口,免得占用真 7610。
       _appHubLocalPort = appHubLocalPort ?? kAppHubRemotePort {
    _kickSub = kicks?.listen((_) => kick());
    _lostSub = _tunnel.lost.listen((_) {
      if (_closed || _recovering) return;
      if (_status.phase != HostLinkPhase.connected) return;
      _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshDisconnected, retryable: true));
    });
  }

  SshHostConfig _config;
  final Future<SshSecrets> Function() _loadSecrets;
  final HostKeyPrompter? promptHostKey;
  final HostKeyPinner? pinHostKey;

  /// Where dartssh2 and the forward listener run. Production spawns them in
  /// their own isolate (SSH crypto must not compete with frame rendering);
  /// tests inject [LocalSshTunnel] with a fake transport factory.
  final SshTunnel _tunnel;
  final DshClientConnector _connectClient;
  final Backoff _backoff;

  /// 本地绑死的 AppHub 转发口(默认 = kAppHubRemotePort):小程序硬编码
  /// `http://127.0.0.1:7610`,与仿真器 adb reverse tcp:7610 同款语义。
  final int _appHubLocalPort;
  final Map<String, String> remoteEnvironment;
  final Duration keepAliveInterval;
  final Duration keepAliveTimeout;

  /// Bounds the initial probe and subsequent forwarded channel opens.
  final Duration tunnelProbeTimeout;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<void>? _lostSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  HostLinkStatus _status = HostLinkStatus.idle;

  RemoteDshEndpoint? _endpoint;
  DshClient? _client;
  Future<DshClient>? _opening;
  Timer? _keepAlive;
  int _missedPings = 0;
  bool _closed = false;
  bool _recovering = false;
  bool _needsRelogin = false;
  bool _forceRestart = false;

  SshHostConfig get config => _config;

  /// Takes a rename, a new working directory or a re-pinned key without
  /// touching the SSH session (a new address or login needs a new link).
  void updateConfig(SshHostConfig next) {
    _config = _config.copyWith(
      name: next.name,
      workingDirectory: () => next.workingDirectory,
      hostKeyType: () => next.hostKeyType,
      hostKeyFingerprint: () => next.hostKeyFingerprint,
    );
  }

  RemoteDshEndpoint? get endpoint => _endpoint;

  /// The local forward port (null before the first tunnel).
  int? get localPort => _tunnel.localPort;

  /// Configured working directory with `~` resolved on the remote.
  String? get resolvedWorkingDirectory => RemoteDshBootstrap.absolutePath(_config.workingDirectory, _endpoint?.home);

  @override
  HostLinkStatus get status => _status;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openFirst().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openFirst() async {
    _backoff.reset();
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      return await _connectOnce();
    } on HostLinkError catch (e) {
      if (!e.retryable || !retryFirstOpen) {
        _fail(e);
        rethrow;
      }
      return _recover(e);
    } catch (e) {
      final error = HostLinkError(
        HostLinkErrorKind.other,
        appL10n.commonConnectionFailed,
        detail: '$e',
        retryable: true,
      );
      if (!retryFirstOpen) {
        _fail(error);
        throw error;
      }
      return _recover(error);
    }
  }

  void _fail(HostLinkError error) {
    _teardownTransport();
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: error));
  }

  void _checkOpen() {
    if (_closed) throw StateError('link closed');
  }

  /// One full attempt. Reuses the forwarder and, when the remote endpoint is
  /// unchanged, the existing DshClient.
  Future<DshClient> _connectOnce() async {
    var step = _status.withStep(HostLinkStep.connect);
    void at(HostLinkStep s, {String? detail}) {
      step = step.withStep(s, detail: detail);
      _emit(step);
    }

    at(HostLinkStep.connect, detail: _config.address);
    final secrets = await _loadSecrets();
    _checkOpen();
    await _tunnel.connect(SshConnectParams.of(_config, secrets), (key) async {
      if (_closed) return false;
      at(HostLinkStep.verifyHostKey, detail: '${key.shortType} ${key.fingerprint}');
      switch (checkHostKey(_config, key)) {
        case HostKeyVerdict.trusted:
          return true;
        case HostKeyVerdict.mismatch:
          throw hostKeyMismatchError(_config, key);
        case HostKeyVerdict.unknown:
          final prompt = promptHostKey;
          if (prompt == null) {
            throw HostLinkError(
              HostLinkErrorKind.hostKeyUnverified,
              appL10n.remoteErrFingerprintUnconfirmed,
              detail: '${key.shortType} ${key.fingerprint}',
            );
          }
          final ok = await prompt(HostKeyPrompt(hostName: _config.name, address: _config.address, key: key));
          if (_closed) return false;
          if (!ok) {
            throw HostLinkError(HostLinkErrorKind.hostKeyRejected, appL10n.remoteHostTrustCancelled);
          }
          _config = _config.copyWith(hostKeyType: () => key.type, hostKeyFingerprint: () => key.fingerprint);
          await pinHostKey?.call(key);
          if (_closed) return false;
          return true;
      }
    });
    // Own the authenticated connection while bootstrap/probe are pending.
    at(HostLinkStep.startDsh, detail: appL10n.remoteCheckingDsh);
    try {
      final bootstrap = RemoteDshBootstrap(
        _WorkerShell(_tunnel),
        launchCommand: _config.launchCommand,
        workingDirectory: _config.workingDirectory,
        environment: remoteEnvironment,
      );
      final endpoint = await bootstrap.ensureRunning(
        forceRestart: _forceRestart,
        onDetail: (d) => at(HostLinkStep.startDsh, detail: d),
      );
      _checkOpen();
      _forceRestart = false;

      at(HostLinkStep.tunnel, detail: '127.0.0.1:${endpoint.port}');
      final probe = await _tunnel.probeTunnel(endpoint.port, timeout: tunnelProbeTimeout);
      if (probe.refused || probe.error != null) {
        // A reused DSH whose port no longer answers: start a fresh one.
        if (endpoint.reused && probe.refused) _forceRestart = true;
        throw HostLinkError(
          HostLinkErrorKind.tunnelFailed,
          appL10n.remoteErrDshPort,
          detail: '${probe.error ?? probe.refused}',
          retryable: true,
        );
      }
      _checkOpen();
      final previous = _endpoint;
      _endpoint = endpoint;
      await _tunnel.setEndpoint(endpoint.port);
      // AppHub: when the host also runs the AppHub server, carry it on the
      // same SSH session as a second forward. Fire-and-forget — the engine
      // link proceeds regardless, and a host without AppHub keeps the
      // loopback default base.
      unawaited(_ensureAppHubForward());

      at(HostLinkStep.login);
      final client = await _ensureClient(endpoint, previous);
      _checkOpen();
      _emit(
        HostLinkStatus(
          HostLinkPhase.connected,
          completed: HostLinkStep.values.toSet(),
          detail: endpoint.reused ? appL10n.remoteDshReused : appL10n.remoteDshStarted,
        ),
      );
      _startKeepAlive();
      return client;
    } catch (e) {
      _tunnel.reset();
      // No live transport: point the AppHub base back at loopback so the
      // market fails fast instead of queueing on a dead forward listener.
      resetAppHubBase();
      rethrow;
    }
  }

  /// Carries the host's AppHub port ([kAppHubRemotePort]) as a second
  /// loopback forward pinned to the same port locally ([_appHubLocalPort]):
  /// mini programs hardcode `http://127.0.0.1:7610` — the AppHub gateway is
  /// the only door to mini-program backends (miniprogram-spec §7) — the same
  /// way `adb reverse tcp:7610` serves emulators, so the app's own market
  /// base stays the loopback default. Probe first: a host without AppHub
  /// keeps the default base. If the pinned local port is taken (another
  /// linked host bound it first) that existing listener keeps serving —
  /// first linked AppHub host wins. Never throws into the connect path —
  /// AppHub is a passenger here, not the cargo.
  Future<void> _ensureAppHubForward() async {
    try {
      final probe = await _tunnel.probeTunnel(kAppHubRemotePort, timeout: tunnelProbeTimeout);
      if (_closed) return;
      if (probe.refused || probe.error != null) {
        resetAppHubBase();
        return;
      }
      await _tunnel.setExtraEndpoint(kAppHubRemotePort, localPort: _appHubLocalPort);
    } on Object {
      // 本地口被占或绑定失败:已有监听继续答(首占为主),base 保持默认。
      resetAppHubBase();
    }
  }

  Future<DshClient> _ensureClient(RemoteDshEndpoint endpoint, RemoteDshEndpoint? previous) async {
    final existing = _client;
    final sameServer = previous != null && previous.port == endpoint.port && previous.token == endpoint.token;
    if (existing != null && sameServer && !_needsRelogin) {
      // Same process behind the same port: the cookie still works and the mux
      // reconnects through the forwarder by itself. Skip its backoff.
      existing.mux.reconnect();
      return existing;
    }
    final DshClient client;
    try {
      client = await _connectClient(
        baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: _tunnel.localPort!),
        token: endpoint.token,
        hostHeader: endpoint.authority,
      );
    } on DshHttpException catch (e) {
      if (e.statusCode == 401 && endpoint.reused) {
        // Stale log from a process that's gone or restarted: start fresh.
        _forceRestart = true;
      }
      throw HostLinkError(
        HostLinkErrorKind.loginFailed,
        e.statusCode == 401 ? appL10n.remoteErrDshTokenRejected : appL10n.remoteErrDshSignIn,
        detail: '$e',
        retryable: true,
      );
    } on DshException catch (e) {
      throw HostLinkError(HostLinkErrorKind.tunnelFailed, appL10n.remoteErrDshTunnel, detail: '$e', retryable: true);
    }
    if (_closed) {
      await client.close().catchError((_) {});
      throw StateError('link closed');
    }
    _needsRelogin = false;
    _client = client;
    _watchMux(client);
    if (existing != null) {
      _clients.add(client);
      unawaited(existing.close().catchError((_) {}));
    }
    return client;
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _muxSub = client.mux.states.listen((state) {
      if (state == DshConnectionState.unauthorized && identical(client, _client)) {
        _needsRelogin = true;
        _lost(HostLinkError(HostLinkErrorKind.loginFailed, appL10n.remoteErrDshSignInExpired, retryable: true));
      }
    });
  }

  /// SSH answers but the mux can't get through: if nothing listens on DSH's
  /// port any more, reconnect, which starts it again.
  Future<void> _probeDsh() async {
    final endpoint = _endpoint;
    if (endpoint == null || !_status.isConnected) return;
    final probe = await _tunnel.probeTunnel(endpoint.port, timeout: const Duration(seconds: 5));
    if (probe.refused || probe.error != null) {
      _backoff.reset();
      _lost(HostLinkError(HostLinkErrorKind.dshStartFailed, appL10n.remoteErrDshStopped, retryable: true));
    }
  }

  void _teardownTransport() {
    _keepAlive?.cancel();
    _keepAlive = null;
    _tunnel.reset();
    // The forward listeners stay bound across reconnects, but until a
    // transport is back the extra forward cannot serve anything: fail fast.
    resetAppHubBase();
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    _missedPings = 0;
    _keepAlive = Timer.periodic(keepAliveInterval, (_) => unawaited(_keepAliveTick()));
  }

  Future<void> _keepAliveTick() async {
    if (!await _ping(keepAliveTimeout)) return;
    final mux = _client?.mux.state;
    if (mux == DshConnectionState.connecting || mux == DshConnectionState.reconnecting) await _probeDsh();
  }

  Future<bool> _ping(Duration timeout) async {
    if (_closed) return false;
    final alive = await _tunnel.ping(timeout: timeout);
    if (alive) {
      _missedPings = 0;
      return true;
    }
    _missedPings++;
    if (_missedPings >= 2) {
      _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshUnresponsive, retryable: true));
    }
    return false;
  }

  void _lost(HostLinkError reason) {
    if (_closed || _recovering || _status.phase == HostLinkPhase.failed) return;
    if (_status.phase != HostLinkPhase.connected) return;
    _teardownTransport();
    unawaited(_recover(reason).then((_) {}, onError: (_) {}));
  }

  /// Reconnect loop with backoff. Resolves with the (possibly new) client.
  Future<DshClient> _recover(HostLinkError reason) async {
    _recovering = true;
    var last = reason;
    try {
      while (!_closed) {
        if (_backoff.exhausted) {
          final error = HostLinkError(
            last.kind,
            last.message,
            detail: [if (last.detail != null) last.detail!, appL10n.remoteRetryCount(_backoff.attempt)].join('\n'),
            retryable: true,
          );
          _fail(error);
          throw error;
        }
        final delay = _backoff.next();
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
        await _delay.wait(delay);
        if (_closed) break;
        try {
          final client = await _connectOnce();
          _backoff.reset();
          return client;
        } on HostLinkError catch (e) {
          if (_closed) break;
          if (!e.retryable) {
            _fail(e);
            rethrow;
          }
          last = e;
        } catch (e) {
          if (_closed) break;
          last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, detail: '$e', retryable: true);
        }
      }
      throw StateError('link closed');
    } finally {
      _recovering = false;
    }
  }

  /// Kills the current SSH connection as if the network dropped (live tests).
  void debugDropTransport() => _tunnel.debugDropTransport();

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        // Network changed under us: a quick ping tells whether the socket
        // survived; a dead one triggers reconnect without waiting for the
        // regular keepalive.
        unawaited(() async {
          final alive = await _ping(const Duration(seconds: 5));
          if (!alive) {
            _backoff.reset();
            _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrSshNetworkChanged, retryable: true));
          }
        }());
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  @override
  void retry() {
    if (_closed || _status.isBusy && _status.phase != HostLinkPhase.reconnecting) return;
    if (_status.phase == HostLinkPhase.reconnecting) {
      _backoff.reset();
      _delay.skip();
      return;
    }
    if (_status.phase == HostLinkPhase.connected) unawaited(_probeDsh());
    if (_status.phase == HostLinkPhase.failed || _status.phase == HostLinkPhase.idle) {
      unawaited(open().then((_) {}, onError: (_) {}));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    await _kickSub?.cancel();
    await _lostSub?.cancel();
    await _muxSub?.cancel();
    _teardownTransport();
    await _tunnel.close();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}

/// Runs bootstrap and management scripts through the tunnel worker; the
/// low-rate command path, not the data path.
class _WorkerShell implements RemoteShell {
  const _WorkerShell(this._tunnel);

  final SshTunnel _tunnel;

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) =>
      _tunnel.run(script, timeout: timeout);
}

/// Connects just far enough to read the server's host key, without logging
/// in: used to ask "trust this host?" before a host becomes active.
Future<PresentedHostKey> fetchHostKey(SshHostConfig config, {SshTransportFactory? transportFactory}) async {
  PresentedHostKey? seen;
  // A dummy password: verification happens before authentication, and the
  // verifier refuses, so nothing is ever sent.
  final params = SshConnectParams(
    host: config.host.trim(),
    port: config.port,
    username: config.user.trim(),
    auth: SshAuthMethod.password,
    secrets: const SshSecrets(password: 'x'),
  );
  try {
    final transport = await (transportFactory ?? DartSshTransport.connect)(params, (key) {
      seen = key;
      return false;
    });
    transport.close();
  } catch (e) {
    if (seen != null) return seen!;
    if (e is HostLinkError) rethrow;
    throw HostLinkError(HostLinkErrorKind.unreachable, appL10n.remoteErrReadFingerprint, detail: '$e', retryable: true);
  }
  if (seen != null) return seen!;
  throw HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrNoFingerprint);
}
