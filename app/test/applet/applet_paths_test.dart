import 'dart:convert';

import 'package:dsh_app/ui/applet/applet_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const String home = '/home/eng';

  group('isValidAppletId', () {
    test('accepts lowercase, digits, hyphens', () {
      expect(isValidAppletId('ledger'), isTrue);
      expect(isValidAppletId('a'), isTrue);
      expect(isValidAppletId('habit-tracker-2'), isTrue);
    });

    test('rejects dots, slashes, uppercase, whitespace, empties', () {
      expect(isValidAppletId(''), isFalse);
      expect(isValidAppletId('Ledger'), isFalse);
      expect(isValidAppletId('ledger.json'), isFalse);
      expect(isValidAppletId('a/b'), isFalse);
      expect(isValidAppletId('a b'), isFalse);
      expect(isValidAppletId('../x'), isFalse);
      expect(isValidAppletId('-ledger'), isFalse);
    });
  });

  group('resolveWithinAppletData', () {
    test('plain and nested names land in the data dir', () {
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: 'ledger.json'),
        '$home/dsh/apps/ledger/data/ledger.json',
      );
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: 'a/b/c.json'),
        '$home/dsh/apps/ledger/data/a/b/c.json',
      );
    });

    test('dot segments fold, trailing slashes are fine, empty is the root', () {
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: './a/./b.json'),
        '$home/dsh/apps/ledger/data/a/b.json',
      );
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: 'a/'),
        '$home/dsh/apps/ledger/data/a',
      );
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: ''),
        '$home/dsh/apps/ledger/data',
      );
    });

    test('internal .. stays inside', () {
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: 'a/../b.json'),
        '$home/dsh/apps/ledger/data/b.json',
      );
    });

    test('escapes are refused', () {
      // Straight ascent beyond the data root.
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: '../ledger/app.json'),
        isNull,
      );
      // Deep nesting that climbs out.
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: 'a/b/../../../etc'),
        isNull,
      );
      // Absolute paths never resolve.
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: '/etc/passwd'),
        isNull,
      );
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: '/home/eng/dsh/apps/ledger/data/x'),
        isNull,
      );
    });

    test('invalid app ids are refused', () {
      expect(
        resolveWithinAppletData(engineHome: home, appId: '../other', relative: 'x'),
        isNull,
      );
      expect(
        resolveWithinAppletData(engineHome: home, appId: '', relative: 'x'),
        isNull,
      );
    });

    test('other apps’ data dirs are not reachable by name games', () {
      // "ledger2" is a sibling app, not this app's data.
      expect(
        resolveWithinAppletData(engineHome: home, appId: 'ledger', relative: '../ledger2/data/x'),
        isNull,
      );
    });
  });

  test('utf8 round trip used by the bridge decode', () {
    const String source = '{"note":"午饭 ¥30"}';
    final Object? decoded = jsonDecode(source);
    expect(decoded, isA<Map<dynamic, dynamic>>());
  });
}
