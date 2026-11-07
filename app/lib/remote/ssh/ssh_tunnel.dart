// The SSH tunnel as a swappable unit: dartssh2 transport, the local forward
// listener and every byte of SSH crypto live inside one `SshTunnel`; the
// host link only sees awaitable results and a loopback port.
//
// Two implementations:
//  * [LocalSshTunnel] runs `SshTunnelEngine` in the caller's isolate (tests,
//    with a fake transport factory injected);
//  * [IsolateSshTunnel] spawns `SshTunnelEngine` in its own isolate, so SSH
//    packet crypto never competes with frame rendering — a download through
//    the tunnel saturates the worker, not the UI thread. The app talks to it
//    over the loopback port the engine binds inside the worker.
library;

import 'dart:async';
import 'dart:isolate';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'local_forward.dart';
import 'remote_shell.dart';
import 'ssh_transport.dart';

/// Owns one live SSH transport plus the local forward listener: everything
/// that touches a tunnel byte. Heavy pure-Dart work (packet crypto, channel
/// demux, socket pumping) stays in the isolate running this engine.
class SshTunnelEngine {
  SshTunnelEngine({SshTransportFactory? transportFactory, this.probeTimeout = const Duration(seconds: 10)})
    : _transportFactory = transportFactory ?? DartSshTransport.connect;

  final SshTransportFactory _transportFactory;

  /// Deadline for a forwarded channel-open (and the tunnel probe): a channel
  /// that opens after it is destroyed as a late success.
  final Duration probeTimeout;
  final _events = StreamController<Object>.broadcast();
  SshTransport? _transport;
  Completer<SshTransport>? _ready;
  LocalForwarder? _forwarder;
  int? _endpointPort;
  bool _closed = false;

  /// The transport died (network drop, server closed): the tunnel is down
  /// until the caller connects again. Not emitted for a deliberate reset.
  Stream<void> get lost => _events.stream.where((event) => event is SshTunnelLost);

  /// The loopback port the forward listener is bound to (stable across SSH
  /// reconnects); null before the first [setEndpoint].
  int? get localPort => _forwarder?.port;

  Future<void> connect(SshConnectParams params, HostKeyCheck verifyHostKey) async {
    if (_closed) throw StateError('tunnel closed');
    final transport = await _transportFactory(params, verifyHostKey);
    if (_closed) {
      transport.close();
      throw StateError('tunnel closed');
    }
    _transport = transport;
    _ready?.complete(transport);
    _ready = null;
    unawaited(
      transport.done.then((_) {
        if (!identical(_transport, transport) || _closed) return;
        reset();
        _events.add(SshTunnelLost());
      }),
    );
  }

  /// Binds (once) and returns the local forward port; [remotePort] is where
  /// every channel goes (the remote `dsh web`).
  Future<int> setEndpoint(int remotePort) async {
    _endpointPort = remotePort;
    final existing = _forwarder;
    if (existing != null) return existing.port;
    final forwarder = await LocalForwarder.bind(_openChannel);
    if (_closed) {
      await forwarder.close();
      throw StateError('tunnel closed');
    }
    _forwarder = forwarder;
    return forwarder.port;
  }

  Future<RemoteExecResult> run(String script, {required Duration timeout}) =>
      _withTransport((transport) => transport.run(script, timeout: timeout));

  Future<bool> ping({required Duration timeout}) async {
    final transport = _transport;
    if (transport == null || _closed) return false;
    try {
      await transport.ping(timeout: timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens and immediately closes a channel to [remotePort]. Refusal means
  /// nothing listens there any more (a reused `dsh web` must be restarted);
  /// any other failure is a tunnel error. A channel that opens after
  /// [timeout] is still destroyed.
  Future<({bool refused, Object? error})> probeTunnel(int remotePort, {required Duration timeout}) async {
    try {
      final transport = await _waitTransport(timeout);
      await transport.openTunnel('127.0.0.1', remotePort).then((channel) => channel.destroy()).timeout(timeout);
      return (refused: false, error: null);
    } on TunnelRefused catch (error) {
      return (refused: true, error: error);
    } on Object catch (error) {
      return (refused: false, error: error);
    }
  }

  /// Closes the SSH transport and every forwarded connection. The forward
  /// listener stays bound (the loopback port is stable across reconnects).
  void reset() {
    final transport = _transport;
    _transport = null;
    if (_ready?.isCompleted ?? false) _ready = null;
    transport?.close();
    _forwarder?.dropConnections();
  }

  /// Kills the current transport as if the network dropped (live tests).
  void debugDropTransport() => _transport?.close();

  Future<void> close() async {
    _closed = true;
    _transport?.close();
    _transport = null;
    await _forwarder?.close();
    _forwarder = null;
    await _events.close();
  }

  Future<T> _withTransport<T>(Future<T> Function(SshTransport transport) action) {
    final transport = _transport;
    if (transport == null || _closed) throw StateError('no live SSH transport');
    return action(transport);
  }

  /// Waits (bounded) for a live transport: forwarder connections opened
  /// while connecting or reconnecting queue here.
  Future<SshTransport> _waitTransport(Duration timeout) {
    final transport = _transport;
    if (transport != null) return Future.value(transport);
    return (_ready ??= Completer<SshTransport>()).future.timeout(timeout);
  }

  Future<TunnelChannel> _openChannel() async {
    if (_closed) throw StateError('tunnel closed');
    final transport = await _waitTransport(const Duration(seconds: 20));
    if (_closed) throw StateError('tunnel closed');
    final port = _endpointPort;
    if (port == null) throw StateError('no remote endpoint yet');
    var abandoned = false;
    try {
      return await transport.openTunnel('127.0.0.1', port).then((channel) {
        if (abandoned || _closed || !identical(transport, _transport)) {
          channel.destroy();
          throw StateError('SSH channel no longer active');
        }
        return channel;
      }).timeout(probeTimeout);
    } catch (_) {
      // A timeout does not cancel the SSH request: dispose a late success.
      abandoned = true;
      rethrow;
    }
  }
}

/// The tunnel is down (transport died, not reset by the caller).
class SshTunnelLost {
  const SshTunnelLost();
}

/// What a host link drives: a tunnel it can connect, probe, run scripts on,
/// and point at a remote port; byte handling is the implementation's.
abstract interface class SshTunnel {
  int? get localPort;

  /// The transport died; the tunnel is down until the next [connect].
  Stream<void> get lost;

  Future<void> connect(SshConnectParams params, HostKeyCheck verifyHostKey);

  /// Sets the remote `dsh web` port; returns the stable loopback port.
  Future<int> setEndpoint(int remotePort);

  Future<RemoteExecResult> run(String script, {required Duration timeout});

  Future<bool> ping({required Duration timeout});

  Future<({bool refused, Object? error})> probeTunnel(int remotePort, {required Duration timeout});

  /// Closes the transport and forwarded connections; the listener stays.
  void reset();

  /// Kills the current transport as if the network dropped (live tests).
  void debugDropTransport();

  Future<void> close();
}

/// Runs [SshTunnelEngine] in the caller's isolate: the test path, where a
/// fake transport factory is injected.
final class LocalSshTunnel implements SshTunnel {
  LocalSshTunnel(SshTunnelEngine engine) : _engine = engine;

  final SshTunnelEngine _engine;

  @override
  int? get localPort => _engine.localPort;

  @override
  Stream<void> get lost => _engine.lost;

  @override
  Future<void> connect(SshConnectParams params, HostKeyCheck verifyHostKey) => _engine.connect(params, verifyHostKey);

  @override
  Future<int> setEndpoint(int remotePort) => _engine.setEndpoint(remotePort);

  @override
  Future<RemoteExecResult> run(String script, {required Duration timeout}) =>
      _engine.run(script, timeout: timeout);

  @override
  Future<bool> ping({required Duration timeout}) => _engine.ping(timeout: timeout);

  @override
  Future<({bool refused, Object? error})> probeTunnel(int remotePort, {required Duration timeout}) =>
      _engine.probeTunnel(remotePort, timeout: timeout);

  @override
  void reset() => _engine.reset();

  @override
  void debugDropTransport() => _engine.debugDropTransport();

  @override
  Future<void> close() => _engine.close();
}

/// Runs `SshTunnelEngine` in its own isolate. The host link's SSH host key
/// decision is asked back over the ports; everything else is fire-and-await.
final class IsolateSshTunnel implements SshTunnel {
  Isolate? _isolate;
  SendPort? _inbox;
  ReceivePort? _events;
  Future<SendPort>? _starting;
  bool _broken = false;
  bool _closed = false;
  final _pending = <int, Completer<Object?>>{};
  HostKeyCheck? _verify;
  final _lostController = StreamController<void>.broadcast();
  int _nextId = 0;

  @override
  int? get localPort => _localPort;
  int? _localPort;

  @override
  Stream<void> get lost => _lostController.stream;

  @override
  Future<void> connect(SshConnectParams params, HostKeyCheck verifyHostKey) async {
    _verify = verifyHostKey;
    try {
      await _ask('connect', {'params': params, 'language': AppLocale.current.languageCode});
    } finally {
      _verify = null;
    }
  }

  @override
  Future<int> setEndpoint(int remotePort) async {
    final port = await _ask('endpoint', {'port': remotePort});
    return _localPort = port as int;
  }

  @override
  Future<RemoteExecResult> run(String script, {required Duration timeout}) async {
    final result = await _ask('run', {'script': script, 'timeout': timeout});
    return result as RemoteExecResult;
  }

  @override
  Future<bool> ping({required Duration timeout}) async => (await _ask('ping', {'timeout': timeout})) as bool;

  @override
  Future<({bool refused, Object? error})> probeTunnel(int remotePort, {required Duration timeout}) async {
    final result = await _ask('probe', {'port': remotePort, 'timeout': timeout}) as Map;
    return (refused: result['refused'] as bool, error: result['error']);
  }

  @override
  void reset() {
    if (_closed || _broken) return;
    unawaited(_ask('reset', const {}));
  }

  @override
  void debugDropTransport() {
    if (_closed || _broken) return;
    unawaited(_ask('debugDrop', const {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_broken) {
      try {
        await (_inbox != null ? _ask('close', const {}) : Future.value());
      } on Object {
        // The isolate is gone either way; killing it below is enough.
      }
    }
    await _lostController.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _events?.close();
    _events = null;
    _inbox = null;
    _broken = true;
    for (final completer in _pending.values) {
      completer.completeError(const _WorkerGone());
    }
    _pending.clear();
  }

  Future<void> _ask(String op, Map<String, Object?> args) async {
    final inbox = _inbox ?? await (_starting ??= _start());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    inbox.send({'id': id, 'op': op, ...args});
    final reply = await completer.future as Map;
    if (reply['ok'] != true) {
      final error = reply['error'];
      throw error is HostLinkError ? error : StateError('$error');
    }
    return reply['result'];
  }

  Future<SendPort> _start() async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    _startingHandshake = ready;
    late final StreamSubscription<Object?> subscription;
    subscription = events.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(_sshTunnelMain, events.sendPort, debugName: 'ssh-tunnel');
      // The worker answers with its inbox before doing anything else; if it
      // never does, this caller fails instead of hanging.
      return await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const _WorkerGone(),
      );
    } on Object {
      _broken = true;
      _starting = null;
      await subscription.cancel();
      events.close();
      throw const _WorkerGone();
    }
  }

  Completer<SendPort>? _startingHandshake;

  void _onMessage(Object? message) {
    final map = message as Map;
    if (map['inbox'] is SendPort) {
      _inbox = map['inbox'] as SendPort;
      _startingHandshake?.complete(_inbox!);
      return;
    }
    switch (map['event']) {
      case 'lost':
        _lostController.add(null);
      case 'hostKey':
        final verifyId = map['verifyId'] as int;
        final verify = _verify;
        final key = map['key'] as PresentedHostKey;
        if (verify == null) {
          _inbox?.send({'op': 'hostKeyAnswer', 'verifyId': verifyId, 'trust': false, 'error': null});
          return;
        }
        Future.sync(() => verify(key))
            .then((trust) {
              _inbox?.send({'op': 'hostKeyAnswer', 'verifyId': verifyId, 'trust': trust, 'error': null});
            })
            .catchError((Object error) {
              _inbox?.send({'op': 'hostKeyAnswer', 'verifyId': verifyId, 'trust': false, 'error': error});
            });
      default:
        final id = map['id'] as int?;
        if (id == null) return;
        _pending.remove(id)?.complete(map);
    }
  }
}

final class _WorkerGone implements Exception {
  const _WorkerGone();
}

/// The worker side: one engine, one inbox; replies and events share the
/// caller's port. The engine's localized errors keep the app language — the
/// language code arrives with the connect job.
void _sshTunnelMain(SendPort reply) {
  final inbox = ReceivePort();
  final engine = SshTunnelEngine();
  var nextVerifyId = 0;
  final verifyAnswers = <int, void Function(bool trust, Object? error)>{};

  void settle(int id, Object? result) => reply.send({'id': id, 'ok': true, 'result': result});
  void fail(int id, Object error) => reply.send({'id': id, 'ok': false, 'error': error});

  Future<bool> verify(PresentedHostKey key) {
    final verifyId = nextVerifyId++;
    final completer = Completer<bool>();
    verifyAnswers[verifyId] = (trust, error) {
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(trust);
      }
    };
    reply.send({'event': 'hostKey', 'verifyId': verifyId, 'key': key});
    return completer.future;
  }

  engine.lost.listen((Object? event) {
    if (event is SshTunnelLost) reply.send({'event': 'lost'});
  });

  inbox.listen((Object? message) {
    final job = message as Map;
    final id = job['id'] as int?;
    try {
      switch (job['op'] as String) {
        case 'connect':
          AppLocale.useLanguageCode(job['language'] as String);
          engine
              .connect(job['params'] as SshConnectParams, verify)
              .then((_) => settle(id!, null), onError: (Object error) => fail(id!, error));
        case 'run':
          engine
              .run(job['script'] as String, timeout: job['timeout'] as Duration)
              .then((result) => settle(id!, result), onError: (Object error) => fail(id!, error));
        case 'endpoint':
          engine
              .setEndpoint(job['port'] as int)
              .then((port) => settle(id!, port), onError: (Object error) => fail(id!, error));
        case 'ping':
          engine
              .ping(timeout: job['timeout'] as Duration)
              .then((ok) => settle(id!, ok), onError: (Object error) => fail(id!, error));
        case 'probe':
          engine
              .probeTunnel(job['port'] as int, timeout: job['timeout'] as Duration)
              .then((result) => settle(id!, result), onError: (Object error) => fail(id!, error));
        case 'reset':
          engine.reset();
          settle(id!, null);
        case 'debugDrop':
          engine.debugDropTransport();
          settle(id!, null);
        case 'close':
          engine.close().then((_) => settle(id!, null));
        default:
          if (id != null) fail(id, 'unknown tunnel op ${job['op']}');
      }
    } on Object catch (error) {
      if (id != null) fail(id, error);
    }
  });
  reply.send({'inbox': inbox.sendPort});
}
