import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/ui/applet/applet_bridge.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory engine: files keyed by absolute path, one directory to list.
class FakeTransport implements AppletTransport {
  FakeTransport({Map<String, String>? files, Map<String, List<String>>? dirs, this.listError})
      : files = files ?? <String, String>{},
        dirs = dirs ?? <String, List<String>>{};

  static const String home = '/home/eng';
  final Map<String, String> files;
  final Map<String, List<String>> dirs;

  /// When set, listDir throws this instead of consulting [dirs].
  final Object? listError;
  int homeCalls = 0;

  @override
  Future<String> engineHome() async {
    homeCalls += 1;
    return home;
  }

  @override
  Future<Uint8List> readBytes(String absolutePath, {required int maxBytes}) async {
    final String? content = files[absolutePath];
    if (content == null) {
      throw DshRemoteException('workspace-file/not-found', 'missing: $absolutePath');
    }
    if (content.length > maxBytes) {
      throw DshRemoteException('workspace-file/too-large', 'too large: $absolutePath');
    }
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  Future<List<String>> listDir(String absolutePath) async {
    if (listError != null) throw listError!;
    // Entries as the real adapter delivers them: dot-prefixed names stand in
    // for `hidden: true` and are already gone by the time the bridge sees them.
    return (dirs[absolutePath] ?? <String>[]).where((name) => !name.startsWith('.')).toList();
  }
}

AppletFsBridge bridge(FakeTransport transport) =>
    AppletFsBridge(transport: transport, appId: 'ledger');

void main() {
  group('read', () {
    test('json files come back parsed, with reqId echoed', () async {
      final FakeTransport transport = FakeTransport(files: {
        '/home/eng/dsh/apps/ledger/data/ledger.json':
            '{"transactions":[{"amount":-30}]}',
      });
      final Map<String, Object?> reply = await bridge(transport).handle(<Object?, Object?>{
        'op': 'read',
        'path': 'ledger.json',
        'reqId': 'r1',
      });
      expect(reply['ok'], isTrue);
      expect(reply['reqId'], 'r1');
      expect((reply['data'] as Map<dynamic, dynamic>)['transactions'], hasLength(1));
    });

    test('non-json files come back as text', () async {
      final FakeTransport transport = FakeTransport(files: {
        '/home/eng/dsh/apps/ledger/data/notes.txt': '记得记账',
      });
      final Map<String, Object?> reply =
          await bridge(transport).handle(<Object?, Object?>{'op': 'read', 'path': 'notes.txt', 'reqId': 'r2'});
      expect(reply['ok'], isTrue);
      expect(reply['data'], '记得记账');
    });

    test('missing files are NOT_FOUND, not transport errors', () async {
      final Map<String, Object?> reply = await bridge(FakeTransport())
          .handle(<Object?, Object?>{'op': 'read', 'path': 'nope.json', 'reqId': 'r3'});
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'NOT_FOUND');
    });

    test('oversized files are TOO_LARGE', () async {
      final Map<String, Object?> reply = await bridge(FakeTransport(files: {
        '/home/eng/dsh/apps/ledger/data/big.json': 'x' * (AppletFsBridge.maxFileBytes + 1),
      })).handle(<Object?, Object?>{'op': 'read', 'path': 'big.json', 'reqId': 'r4'});
      // The fake throws the engine's code when the file exceeds the bridge's
      // cap; the bridge maps it to the contract code.
      expect(reply['error'], 'TOO_LARGE');
    });
  });

  group('sandbox', () {
    test('.. escape is refused with a stable code', () async {
      final Map<String, Object?> reply = await bridge(FakeTransport(files: {
        '/home/eng/dsh/apps/other/data/secret.json': '{"x":1}',
      })).handle(<Object?, Object?>{'op': 'read', 'path': '../other/data/secret.json', 'reqId': 'r5'});
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'SANDBOX_ESCAPE');
    });

    test('absolute paths are refused', () async {
      final Map<String, Object?> reply = await bridge(FakeTransport(files: {
        '/home/eng/dsh/apps/ledger/app.json': '{}',
      })).handle(<Object?, Object?>{'op': 'read', 'path': '/home/eng/dsh/apps/ledger/app.json', 'reqId': 'r6'});
      expect(reply['error'], 'SANDBOX_ESCAPE');
    });

    test('reads stay inside the requesting app even for sibling names', () async {
      final FakeTransport transport = FakeTransport(files: {
        '/home/eng/dsh/apps/ledger2/data/ledger.json': '{"sneaky":true}',
      });
      final AppletFsBridge ledgerBridge = AppletFsBridge(transport: transport, appId: 'ledger2');
      final Map<String, Object?> reply = await ledgerBridge
          .handle(<Object?, Object?>{'op': 'read', 'path': '../ledger/data/ledger.json', 'reqId': 'r7'});
      expect(reply['error'], 'SANDBOX_ESCAPE');
    });

    test('non-string paths are refused, not thrown', () async {
      final Map<String, Object?> reply =
          await bridge(FakeTransport()).handle(<Object?, Object?>{'op': 'read', 'path': 42, 'reqId': 'r8'});
      expect(reply['error'], 'SANDBOX_ESCAPE');
    });
  });

  group('list', () {
    test('returns sorted non-hidden names', () async {
      final FakeTransport transport = FakeTransport(dirs: {
        '/home/eng/dsh/apps/ledger/data': <String>['receipts', '.hidden', 'archive', 'backup'],
      });
      final Map<String, Object?> reply =
          await bridge(transport).handle(<Object?, Object?>{'op': 'list', 'path': '', 'reqId': 'r9'});
      expect(reply['ok'], isTrue);
      expect(reply['entries'], <String>['archive', 'backup', 'receipts']);
    });

    test('listing outside the data dir is refused', () async {
      final Map<String, Object?> reply =
          await bridge(FakeTransport()).handle(<Object?, Object?>{'op': 'list', 'path': '../../', 'reqId': 'r10'});
      expect(reply['error'], 'SANDBOX_ESCAPE');
    });
  });

  group('protocol', () {
    test('write is reserved with NOT_IMPLEMENTED', () async {
      final Map<String, Object?> reply = await bridge(FakeTransport())
          .handle(<Object?, Object?>{'op': 'write', 'path': 'x.json', 'reqId': 'r11', 'content': '{}'});
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'NOT_IMPLEMENTED');
    });

    test('unknown ops get BAD_OP', () async {
      final Map<String, Object?> reply =
          await bridge(FakeTransport()).handle(<Object?, Object?>{'op': 'delete', 'reqId': 'r12'});
      expect(reply['error'], 'BAD_OP');
    });

    test('transport failures settle the promise with TRANSPORT_ERROR', () async {
      final FakeTransport transport = FakeTransport(listError: StateError('boom'));
      final AppletFsBridge appletBridge = AppletFsBridge(transport: transport, appId: 'ledger');
      final Map<String, Object?> reply = await appletBridge.handle(<Object?, Object?>{
        'op': 'list',
        'path': 'receipts',
        'reqId': 'r13',
      });
      expect(reply['ok'], isFalse);
      expect(reply['error'], 'TRANSPORT_ERROR');
    });

    test('invalid app ids are a constructor error', () {
      expect(
        () => AppletFsBridge(transport: FakeTransport(), appId: 'Ledger'),
        throwsArgumentError,
      );
    });

    test('consecutive reads stay correct (home cache lives in the adapter)', () async {
      final FakeTransport transport = FakeTransport(files: {
        '/home/eng/dsh/apps/ledger/data/a.json': '1',
        '/home/eng/dsh/apps/ledger/data/b.json': '2',
      });
      final AppletFsBridge appletBridge = bridge(transport);
      final Map<String, Object?> first =
          await appletBridge.handle(<Object?, Object?>{'op': 'read', 'path': 'a.json', 'reqId': 'r14'});
      final Map<String, Object?> second =
          await appletBridge.handle(<Object?, Object?>{'op': 'read', 'path': 'b.json', 'reqId': 'r15'});
      expect(first['ok'], isTrue);
      expect(second['ok'], isTrue);
    });
  });
}
