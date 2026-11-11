// Conversation titles in the list (sessionsProvider), as an SSH host serves
// them. DSH 0.2.1-rc.4's `session/list` gives a conversation the Host process
// isn't holding the title from its projection cache, read once when the
// process starts: one another DSH process wrote since (the desktop app, the
// TUI, a headless run — on an SSH host the app's `dsh web` lives on between
// connections) comes with no projections at all, and showed 「未命名」 until
// opened (ccch1mneyyy/dsh-go#57, item 1). Checked against two rc.4 processes
// on one DSH_HOME: the long-lived one lists the other's conversation with no
// projections, and answers `session/projections` with its title.
//
// And a race: a refresh asked for while the first list of a (re)connection
// was being read was dropped, so a conversation started meanwhile kept the
// list from before it — no title — until some later event.

import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart';

class _Host extends ActiveHostController {
  _Host(this.id);
  final String id;
  @override
  HostRef build() => HostRef.ssh(id);
}

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready);
}

class _WorkspacePrefs extends WorkspacePrefsController {
  @override
  WorkspacePrefs build() => const WorkspacePrefs(loaded: true);
}

/// A `session/list` row. [title] null with [cold]: what a long-lived process
/// lists for a conversation another process wrote (no projections at all).
/// [hinted]: what the projection cache serves for a row it has cells for —
/// a title without a second line.
Map<String, Object?> _row(String id, {String? title, bool cold = false, int updatedAt = 1793000000000}) => {
  'sessionId': id,
  'updatedAt': updatedAt,
  'running': false,
  'blank': false,
  'agentAvailable': !cold,
  if (!cold)
    'projections': {
      'kind': 'sequenced',
      'asOfSeq': 7,
      'values': {'title': title},
    },
};

Map<String, Object?> _hintedRow(String id, {required String title, int updatedAt = 1793000000000}) => {
  'sessionId': id,
  'updatedAt': updatedAt,
  'running': false,
  'blank': false,
  'agentAvailable': true,
  'projections': {
    'kind': 'cached',
    'asOfSeq': 7,
    'values': {'title': title},
  },
};

/// `session/projections` for a conversation the process isn't holding.
/// [prompt]/[response] add a two-turn `turnOutline`, the second turn's
/// halves settable so the fold's fallbacks are exercised.
Map<String, Object?> _folded({String? title, bool blank = false, String? prompt, String? response}) => {
  'kind': 'sequenced',
  'asOfSeq': 12,
  'values': {
    'title': title,
    'sessionListMetadata': {'blank': blank},
    if (prompt != null || response != null)
      'turnOutline': [
        {'turn': 0, 'seq': 1, 'prompt': 'First ask', 'response': 'First answer'},
        {'turn': 1, 'seq': 5, 'prompt': prompt ?? '', 'response': response ?? ''},
      ],
  },
};

class _SshHost {
  _SshHost([this.id = 'studio']) {
    carrier.handlers['session/list'] = (_) {
      final reply = {'items': rows};
      if (holdLists) {
        final held = Completer<Object?>();
        lists.add(held);
        return held.future;
      }
      return reply;
    };
    carrier.handlers['session/projections'] = (args) {
      final id = (args['request'] as Map)['sessionId'] as String;
      reads.add(id);
      if (failReads.isNotEmpty) throw failReads.removeAt(0);
      if (holdReads) {
        final held = Completer<Object?>();
        heldReads.add((id, held));
        return held.future;
      }
      return folded[id];
    };
    carrier.handlers['session/page'] = (args) {
      final address = ((args['request'] as Map)['address']) as Map;
      final id = address['sessionId'] as String;
      return pages[id];
    };
    client = DshClient.withCarrier(carrier);
  }

  final String id;
  final carrier = FakePluginCarrier();
  late final DshClient client;
  List<Map<String, Object?>> rows = [];
  final folded = <String, Object?>{};
  final pages = <String, Object?>{};
  final reads = <String>[];

  /// What the next reads fail with, in turn (a Host or proxy erring just then).
  final failReads = <Object>[];

  bool holdLists = false;
  final lists = <Completer<Object?>>[];
  bool holdReads = false;
  final heldReads = <(String, Completer<Object?>)>[];

  int get listCalls => carrier.argsOf('session/list').length;

  /// Nothing that opens a conversation was asked for.
  Iterable<String> get opened => carrier.calls
      .map((c) => c.$1)
      .where((e) => e == 'session/follow' || e == 'session/create' || e == 'session/prompt');
}

/// "Now" for the title reads' retries.
var _clock = DateTime(2026, 10, 30, 9);

ProviderContainer _container(_SshHost host) => ProviderContainer(
  overrides: [
    sessionTitleClockProvider.overrideWithValue(() => _clock),
    activeHostProvider.overrideWith(() => _Host(host.id)),
    activeConnectionProvider.overrideWithValue(
      AsyncData(HostConnection(client: host.client, isLocal: false, kind: HostKind.ssh, hostId: host.id)),
    ),
    readListIdentityProvider.overrideWithValue(ReadListIdentity.of(['ssh-a'])),
    workspacesProvider.overrideWith(_Workspaces.new),
    workspacePrefsProvider.overrideWith(_WorkspacePrefs.new),
    dsBotOwnedSessionsProvider.overrideWithValue(const {}),
  ],
);

/// Lets the reads started by a list land, and their re-emit run.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, String?> _titles(ProviderContainer c) => {
  for (final s in c.read(sessionsProvider).value!) s.sessionId: s.title,
};

Map<String, String?> _previews(ProviderContainer c) => {
  for (final s in c.read(sessionsProvider).value!) s.sessionId: s.previewText,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late _SshHost host;
  late ProviderContainer c;
  setUp(() {
    _clock = DateTime(2026, 10, 30, 9);
    host = _SshHost();
    c = ProviderContainer(overrides: const []);
  });
  tearDown(() async {
    c.dispose();
    await host.client.close();
  });

  ProviderContainer start() {
    c.dispose();
    return c = _container(host);
  }

  test('pendingSubtitleIds tracks rows until their read lands', () async {
    host.rows = [_row('desktop', cold: true)];
    host.holdReads = true;
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    // 读还在途:占位。
    expect(c.read(sessionsProvider.notifier).pendingSubtitleIds, {'desktop'});
    host.heldReads.single.$2.complete(_folded(title: 'Plan the garden party', response: 'Garden party moved to Sunday'));
    await _settle();
    // 读落地:占位消失,副标题就位。
    expect(c.read(sessionsProvider.notifier).pendingSubtitleIds, isEmpty);
    expect(_previews(c), {'desktop': 'Garden party moved to Sunday'});
  });

  test('a Host that can\'t read titles this way shows no pending placeholders', () async {
    host.carrier.handlers.remove('session/projections');
    host.rows = [_row('s0', cold: true), _row('own', title: 'Release notes')];
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(c.read(sessionsProvider.notifier).pendingSubtitleIds, isEmpty);
  });

  test('a host without turnOutline falls back to the event tail for the second line', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    host.pages['desktop'] = {
      'records': [
        {
          'event': {
            'type': 'user/message',
            'seq': 9,
            'time': 1,
            'data': {
              'source': {'kind': 'user'},
              'content': [
                {'type': 'text', 'text': 'When is the garden party?'},
              ],
            },
          },
        },
        {
          'event': {
            'type': 'assistant/message',
            'seq': 12,
            'time': 2,
            'data': {
              'turn': 0,
              'step': 2,
              'message': {
                'content': [
                  {'type': 'text', 'text': 'Garden party moved to Sunday'},
                ],
              },
            },
          },
        },
      ],
      'hasMore': false,
    };
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
    // 老主机没有 turnOutline:副标题从事件尾页取到回复。
    expect(_previews(c), {'desktop': 'Garden party moved to Sunday'});
    expect(host.opened, isEmpty);
  });

  test('a conversation another DSH process wrote gets its title read, without being opened', () async {
    host.rows = [_row('own', title: 'Release notes'), _row('desktop', cold: true)];
    host.folded['own'] = _folded(title: 'Release notes', response: 'Release notes are out');
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'own': 'Release notes', 'desktop': 'Plan the garden party'});
    // Both rows are read once — the Host-held one too, for its second line.
    expect(host.reads.toSet(), {'own', 'desktop'});
    expect(host.opened, isEmpty);
    // The lineage (agents_state) reads the same rows.
    expect(c.read(sessionsProvider.notifier).allSessions.map((s) => s.title), contains('Plan the garden party'));
  });

  test('a Host-held row is read once too, for its second line', () async {
    // Hints carry the title first-hand but never a preview: the row is read
    // once per version to fold one, and the hints' title stays authoritative
    // even when the read saw something else.
    host.rows = [_row('warm', title: 'Release notes')];
    host.folded['warm'] = _folded(title: 'Renamed elsewhere', response: 'Shipped the fix');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'warm': 'Release notes'});
    expect(_previews(c), {'warm': 'Shipped the fix'});
    expect(host.reads, ['warm']);
    // Unchanged rows are not read again.
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, ['warm']);
  });

  test('each row is read once, again only when it changed', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, ['desktop']);
    // Written to since: the older title shows until the new one lands.
    host.rows = [_row('desktop', cold: true, updatedAt: 1793000050000)];
    host.folded['desktop'] = _folded(title: 'Garden party, Saturday 3 pm');
    host.holdReads = true;
    await c.read(sessionsProvider.notifier).refresh();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
    host.heldReads.single.$2.complete(host.folded['desktop']);
    await _settle();
    expect(host.reads, ['desktop', 'desktop']);
    expect(_titles(c), {'desktop': 'Garden party, Saturday 3 pm'});
  });

  test('a cold conversation that turns out blank (a TUI that opened and left) stays out of the list', () async {
    host.rows = [_row('own', title: 'Release notes'), _row('tui', cold: true)];
    host.folded['tui'] = _folded(blank: true);
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c).keys, ['own']);
  });

  test('a conversation that really has no title yet is read once and stays untitled', () async {
    host.rows = [_row('image-only', cold: true)];
    host.folded['image-only'] = _folded();
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(_titles(c), {'image-only': null});
    expect(host.reads, ['image-only']);
  });

  test('a Host that can\'t read titles this way isn\'t asked again, and the list stands as served', () async {
    host.carrier.handlers.remove('session/projections');
    host.rows = [for (var i = 0; i < 6; i++) _row('s$i', cold: true, updatedAt: 1793000000000 - i)];
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    // The reads already under way when the first refusal came, no more.
    final first = host.carrier.argsOf('session/projections').length;
    expect(first, lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
    host.rows = [_row('s0', cold: true, updatedAt: 1793000090000), _row('c', cold: true)];
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.carrier.argsOf('session/projections'), hasLength(first));
    expect(_titles(c), {'s0': null, 'c': null});
  });

  test('a read the connection dropped is asked again by the next list', () async {
    host.rows = [_row('desktop', cold: true)];
    host.holdReads = true;
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    host.heldReads.single.$2.completeError(const DshCarrierLostException('tunnel closed'));
    await _settle();
    host.holdReads = false;
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
  });

  group('a read that failed just then is asked again by the next list', () {
    for (final (name, failure) in [
      // The Host couldn't read the log just then (session-controller wraps it).
      ('gateway/internal', const DshRemoteException('gateway/internal', 'EIO reading the conversation log')),
      // A tunnel or reverse proxy in front of `dsh web`.
      ('HTTP 502', const DshHttpException(502, 'HTTP 502 from /api/rpc')),
    ]) {
      test(name, () async {
        host.rows = [_row('desktop', cold: true)];
        host.folded['desktop'] = _folded(title: 'Plan the garden party');
        host.failReads.add(failure);
        start();
        await c.read(sessionsProvider.future);
        await _settle();
        expect(_titles(c), {'desktop': null});
        // Back up; the conversation is as it was (same updatedAt).
        await c.read(sessionsProvider.notifier).refresh();
        await _settle();
        expect(host.reads, ['desktop', 'desktop']);
        expect(_titles(c), {'desktop': 'Plan the garden party'});
      });
    }
  });

  test('a row that keeps failing is asked less and less often, at once when it changed', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    const internal = DshRemoteException('gateway/internal', 'EIO reading the conversation log');
    host.failReads.addAll([internal, internal, internal]);
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    Future<void> list() async {
      await c.read(sessionsProvider.notifier).refresh();
      await _settle();
    }

    // Failed once: the next list asks again.
    await list();
    expect(host.reads, hasLength(2));
    // Failed again: not before titleRetryAfter, then not before twice that.
    await list();
    expect(host.reads, hasLength(2));
    _clock = _clock.add(SessionsController.titleRetryAfter);
    await list();
    expect(host.reads, hasLength(3));
    _clock = _clock.add(SessionsController.titleRetryAfter);
    await list();
    expect(host.reads, hasLength(3));
    // Written to since: asked at once.
    host.rows = [_row('desktop', cold: true, updatedAt: 1793000050000)];
    await list();
    expect(host.reads, hasLength(4));
    expect(_titles(c), {'desktop': 'Plan the garden party'});
  });

  test('a title already read stays while reading the changed row fails just then', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    host.rows = [_row('desktop', cold: true, updatedAt: 1793000050000)];
    host.folded['desktop'] = _folded(title: 'Garden party, Saturday 3 pm');
    host.failReads.add(const DshRemoteException('gateway/internal', 'EIO reading the conversation log'));
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, ['desktop', 'desktop', 'desktop']);
    expect(_titles(c), {'desktop': 'Garden party, Saturday 3 pm'});
  });

  test('newest first, two at a time, a bounded number per list', () async {
    const many = SessionsController.titleReadsPerList + 5;
    host.rows = [for (var i = 0; i < many; i++) _row('s$i', cold: true, updatedAt: 1793000000000 - i * 1000)];
    host.holdReads = true;
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(host.reads, ['s0', 's1']);
    for (var done = 0; done < SessionsController.titleReadsPerList; done++) {
      final (id, held) = host.heldReads[done];
      expect(host.heldReads.length - done, lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
      held.complete(_folded(title: 'Title $id'));
      await _settle();
    }
    expect(host.reads, hasLength(SessionsController.titleReadsPerList));
    expect(host.reads.first, 's0');
    // The rest come with the next list.
    host.holdReads = false;
    for (var i = SessionsController.titleReadsPerList; i < many; i++) {
      host.folded['s$i'] = _folded(title: 'Title s$i');
    }
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, hasLength(many));
    expect(_titles(c).values.where((t) => t == null), isEmpty);
  });

  test('lists landing while titles are read share the two readers: two reads at a time in all', () async {
    // More cold rows than two lists read: every list that lands while the
    // first reads are still out has rows of its own to read.
    const many = 2 * SessionsController.titleReadsPerList + 5;
    host.rows = [for (var i = 0; i < many; i++) _row('s$i', cold: true, updatedAt: 1793000000000 - i * 1000)];
    host.holdReads = true;
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(host.reads, ['s0', 's1']);
    int out() => host.heldReads.where((h) => !h.$2.isCompleted).length;
    // A refresh and then another (an added conversation, a status change)
    // land with both reads still out: they queue, they don't read alongside.
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, ['s0', 's1']);
    // One lands: the next one starts, never more than two out.
    for (var done = 0; done < host.heldReads.length; done++) {
      expect(out(), lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
      final (id, held) = host.heldReads[done];
      held.complete(_folded(title: 'Title $id'));
      await _settle();
    }
    expect(out(), 0);
    // Each row once, newest first.
    expect(host.reads.toSet(), hasLength(host.reads.length));
    expect(host.reads.take(3), ['s0', 's1', 's2']);
    expect(_titles(c)['s2'], 'Title s2');
  });

  test('the connection going drops what it had queued; reads out land nowhere', () async {
    host.rows = [for (var i = 0; i < 6; i++) _row('s$i', cold: true, updatedAt: 1793000000000 - i * 1000)];
    host.holdReads = true;
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(host.reads, ['s0', 's1']);
    // Another host is chosen: this connection no longer serves the list.
    c.read(activeHostProvider.notifier).select(HostRef.ssh('laptop'));
    await c.read(sessionsProvider.future);
    for (final (id, held) in host.heldReads) {
      held.complete(_folded(title: 'Title $id'));
    }
    await _settle();
    expect(host.reads, ['s0', 's1']);
    // Back on it: a fresh list queues them all again.
    host.holdReads = false;
    for (var i = 0; i < 6; i++) {
      host.folded['s$i'] = _folded(title: 'Title s$i');
    }
    c.read(activeHostProvider.notifier).select(HostRef.ssh(host.id));
    await c.read(sessionsProvider.future);
    await _settle();
    expect(host.reads.skip(2), ['s0', 's1', 's2', 's3', 's4', 's5']);
    expect(_titles(c).values, everyElement(startsWith('Title ')));
  });

  test('a refresh asked for while the first list is read reads once more after it', () async {
    // Reconnected: the first list goes out. Meanwhile a conversation starts
    // (its added and status events ask for a refresh), after the Host had
    // already answered the first list without it.
    host.holdLists = true;
    host.rows = [_row('old', title: 'Release notes')];
    start();
    final first = c.read(sessionsProvider.future);
    await _settle();
    expect(host.lists, hasLength(1));
    final refresh = c.read(sessionsProvider.notifier).refresh();
    final refreshAgain = c.read(sessionsProvider.notifier).refresh();
    host.lists.single.complete({
      'items': [_row('old', title: 'Release notes')],
    });
    await first;
    await _settle();
    // One more read for both refreshes, which now sees the new conversation.
    expect(host.lists, hasLength(2));
    host.lists.last.complete({
      'items': [
        _row('old', title: 'Release notes'),
        _row('new', title: 'Plan the garden party', updatedAt: 1793000060000),
      ],
    });
    await Future.wait([refresh, refreshAgain]);
    expect(_titles(c), {'new': 'Plan the garden party', 'old': 'Release notes'});
    expect(host.listCalls, 2);
  });

  group('host events while the first list is read', () {
    /// Waits out the list's 400 ms debounce of host events.
    Future<void> debounce() => Future<void>.delayed(const Duration(milliseconds: 500));

    Future<Future<List<SessionSummary>>> connect() async {
      host.holdLists = true;
      host.rows = [_row('old', title: 'Release notes')];
      start();
      final first = c.read(sessionsProvider.future);
      // The event stream opens (and says ready) with the first list out.
      for (var i = 0; i < 20 && host.carrier.link == null; i++) {
        await _settle();
      }
      await _settle();
      expect(host.lists, hasLength(1));
      return first;
    }

    test('a conversation started meanwhile is read once more, title and all', () async {
      final first = await connect();
      host.carrier.link!.push({
        'type': 'emit',
        'event': 'api-session/status',
        'args': ['new', true],
      });
      await debounce();
      host.lists.single.complete({
        'items': [_row('old', title: 'Release notes')],
      });
      await first;
      await _settle();
      expect(host.lists, hasLength(2));
      host.lists.last.complete({
        'items': [
          _row('old', title: 'Release notes'),
          _row('new', title: 'Plan the garden party', updatedAt: 1793000060000),
        ],
      });
      await _settle();
      expect(_titles(c), {'new': 'Plan the garden party', 'old': 'Release notes'});
    });

    test('ready alone changes no conversation: no second read', () async {
      final first = await connect();
      await debounce();
      host.lists.single.complete({
        'items': [_row('old', title: 'Release notes')],
      });
      await first;
      await debounce();
      expect(host.lists, hasLength(1));
    });
  });

  test('the second line folds from the same read\'s outline, newest turn first', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party', response: 'Garden party moved to Sunday');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
    expect(_previews(c), {'desktop': 'Garden party moved to Sunday'});
    // One read covers both, and the conversation was not opened.
    expect(host.reads, ['desktop']);
    expect(host.opened, isEmpty);
  });

  test('a turn still without its answer shows the prompt as the second line', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party', prompt: 'When is the garden party?');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_previews(c), {'desktop': 'When is the garden party?'});
    // An outline with no text at all leaves the row without a second line.
    host.rows = [_row('desktop', cold: true, updatedAt: 1793000050000)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(_previews(c), {'desktop': null});
  });

  test('a row served a title is still read once, for its second line', () async {
    // The projection cache answers `session/list` with a title but never a
    // preview; the row is read once per version to fold one, then left alone.
    host.rows = [_hintedRow('cached', title: 'Served title')];
    host.folded['cached'] = _folded(title: 'Served title', response: 'Latest news');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'cached': 'Served title'});
    expect(_previews(c), {'cached': 'Latest news'});
    expect(host.reads, ['cached']);
    // Unchanged rows are not read again.
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(host.reads, ['cached']);
  });

  test('switching hosts drops the titles read on the previous one', () async {
    host.rows = [_row('desktop', cold: true)];
    host.folded['desktop'] = _folded(title: 'Plan the garden party');
    start();
    await c.read(sessionsProvider.future);
    await _settle();
    expect(_titles(c), {'desktop': 'Plan the garden party'});
    final other = _SshHost('laptop')..rows = [_row('desktop', cold: true)];
    addTearDown(other.client.close);
    c.dispose();
    c = _container(other);
    await c.read(sessionsProvider.future);
    expect(_titles(c), {'desktop': null});
  });
}
