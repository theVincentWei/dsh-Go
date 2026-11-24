// AppHub 宠物源自动更新的行为:家端主权(首次纳管、覆盖工坊/手工装的同 id
// 宠物)、记录驱动的免下载跳过、版本比较、坏行隔离、目录级失败静默、sha 不
// 匹配拒装、撤包不卸载。真 PetLibrary + 临时目录;HTTP 是注入的假
// transport,不碰网络。目录行的 sha256 一律用真实 zip 的 digest——与生产
// 契约一致(publish 时算好入库)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/apphub_pet_update.dart';
import 'package:flutter_test/flutter_test.dart';

import '../pets/pet_library_test.dart' show packJson, png;

class _FakeHttp implements UpdateHttp {
  _FakeHttp(this.bodies);

  final Map<Uri, List<int>> bodies;

  @override
  Future<UpdateHttpResponse> get(Uri url,
      {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 15)}) async {
    final List<int>? body = bodies[url];
    if (body == null) return UpdateHttpResponse(status: 404, body: const Stream.empty());
    return UpdateHttpResponse(status: 200, body: Stream<List<int>>.value(body));
  }
}

/// The fake hub: packs by petId, each row carrying the *real* digest of its
/// zip the way publish does.
Map<Uri, List<int>> hub(Uri base, Map<String, List<int>> packs, Map<String, String> versions) {
  final rows = <Map<String, Object?>>[
    for (final MapEntry<String, List<int>> pack in packs.entries)
      <String, Object?>{
        'petId': pack.key,
        'name': '家里的${pack.key}',
        'version': versions[pack.key],
        'versionCode': 1,
        'packageUrl': base.resolve('/packages/pet-${pack.key}-1.zip').toString(),
        'sha256': crypto.sha256.convert(pack.value).toString(),
        'sizeBytes': pack.value.length,
      },
  ];
  return {
    base.resolve('/api/v1/pets'): utf8.encode(jsonEncode(<String, Object?>{'pets': rows})),
    for (final MapEntry<String, List<int>> pack in packs.entries)
      base.resolve('/packages/pet-${pack.key}-1.zip'): pack.value,
  };
}

List<int> packZip(String id, String version) {
  final Map<String, Object?> json = packJson(id: id)..['version'] = version;
  final Archive archive = Archive()
    ..add(ArchiveFile.bytes('pack.json', utf8.encode(jsonEncode(json))))
    ..add(ArchiveFile.bytes('idle.png', png(32, 16)));
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory temp;
  late PetLibrary pets;
  late Uri base;
  late _FakeHttp http;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('apphub-pet-update');
    pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    base = Uri.parse('http://hub.test:7610');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  void serve(Map<String, List<int>> packs, Map<String, String> versions) {
    http = _FakeHttp(hub(base, packs, versions));
  }

  test('first pass installs a pack the phone never had and records it', () async {
    // Zip entries carry timestamps: build the zip once and reuse the same
    // bytes everywhere, so digests are comparable.
    final bytes = packZip('home-cat', '1.0.0');
    serve({'home-cat': bytes}, {'home-cat': '1.0.0'});
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, ['home-cat']);
    expect(result.quiet, isFalse);
    expect(result.errors, isEmpty);
    expect((await pets.load('user-home-cat')).id, 'user-home-cat');
    final record =
        jsonDecode(await File('${temp.path}/pets/user-home-cat/.apphub-pet.json').readAsString())
            as Map<String, Object?>;
    expect(record['petId'], 'home-cat');
    expect(record['version'], '1.0.0');
    expect(record['sha256'], crypto.sha256.convert(bytes).toString());
  });

  test('the home server hands out loopback package URLs — rebuilt on the app base', () async {
    // 生产形态:家端把 packageUrl 发成自己的回环地址(127.0.0.1:7610),手机上
    // 该地址指向手机自身,下载必然失败。修复 = 环回包地址重解析到 AppHub base。
    const loopbackBase = 'http://127.0.0.1:7610';
    final bytes = packZip('loop-cat', '1.0.0');
    // 包文件与目录都按 base 提供(手机经 base 到达家端),目录行却发环回地址。
    http = _FakeHttp({
      Uri.parse('$base/api/v1/pets'): utf8.encode(jsonEncode(<String, Object?>{'pets': [
            <String, Object?>{
              'petId': 'loop-cat',
              'name': '家里的loop-cat',
              'version': '1.0.0',
              'versionCode': 1,
              'packageUrl': '$loopbackBase/packages/pet-loop-cat-1.zip',
              'sha256': crypto.sha256.convert(bytes).toString(),
              'sizeBytes': bytes.length,
            },
          ]})),
      Uri.parse('$base/packages/pet-loop-cat-1.zip'): bytes,
    });
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, ['loop-cat']);
    expect(result.errors, isEmpty);
    expect((await pets.load('user-loop-cat')).id, 'user-loop-cat');
  });

  test('the same release skips; a newer version replaces; an older one is kept', () async {
    serve({'home-cat': packZip('home-cat', '1.0.0')}, {'home-cat': '1.0.0'});
    await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);

    // Same release again: quiet.
    var result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, isEmpty);
    expect(result.skipped['pet/home-cat'], 'workshop_up_to_date');

    // The home side publishes 1.1.0: replaced, record follows.
    serve({'home-cat': packZip('home-cat', '1.1.0')}, {'home-cat': '1.1.0'});
    result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, ['home-cat']);
    expect((await pets.load('user-home-cat')).id, 'user-home-cat');

    // 1.0.0 again (a mistaken downgrade publish): the phone keeps 1.1.0.
    serve({'home-cat': packZip('home-cat', '1.0.0')}, {'home-cat': '1.0.0'});
    result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, isEmpty);
    expect(result.skipped['pet/home-cat'], 'workshop_up_to_date');
  });

  test('the home side wins over a pack installed from the workshop or by hand', () async {
    // Installed without any AppHub record (receipt path or plain import).
    final File manual = File('${temp.path}/manual.zip');
    await manual.writeAsBytes(packZip('home-cat', '1.0.0'), flush: true);
    await pets.install(manual, replaceExisting: true);

    serve({'home-cat': packZip('home-cat', '1.0.0')}, {'home-cat': '1.0.0'});
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, ['home-cat']);
    final record =
        jsonDecode(await File('${temp.path}/pets/user-home-cat/.apphub-pet.json').readAsString())
            as Map<String, Object?>;
    expect(record['version'], '1.0.0');
  });

  test('a broken catalog row never hides its neighbours', () async {
    final bytes = packZip('home-cat', '1.0.0');
    http = _FakeHttp({
      base.resolve('/api/v1/pets'): utf8.encode(jsonEncode(<String, Object?>{
        'pets': <Object?>[
          <String, Object?>{
            'petId': 'home-dog',
            'version': 'not semver at all',
            'packageUrl': base.resolve('/packages/pet-home-dog-1.zip').toString(),
            'sha256': 'zz',
          },
          <String, Object?>{
            'petId': 'home-cat',
            'version': '1.0.0',
            'versionCode': 1,
            'packageUrl': base.resolve('/packages/pet-home-cat-1.zip').toString(),
            'sha256': crypto.sha256.convert(bytes).toString(),
            'sizeBytes': bytes.length,
          },
        ],
      })),
      base.resolve('/packages/pet-home-cat-1.zip'): bytes,
    });
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, ['home-cat']);
    expect(result.errors, isEmpty);
  });

  test('a digest mismatch refuses to install and is reported', () async {
    // The row names a digest the bytes don't match (a lying/tampered hub).
    final bytes = packZip('home-cat', '1.0.0');
    http = _FakeHttp({
      base.resolve('/api/v1/pets'): utf8.encode(jsonEncode(<String, Object?>{
        'pets': <Object?>[
          <String, Object?>{
            'petId': 'home-cat',
            'version': '1.0.0',
            'versionCode': 1,
            'packageUrl': base.resolve('/packages/pet-home-cat-1.zip').toString(),
            'sha256': 'b' * 64,
            'sizeBytes': bytes.length,
          },
        ],
      })),
      base.resolve('/packages/pet-home-cat-1.zip'): bytes,
    });
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.updated, isEmpty);
    expect(result.errors['pet/home-cat'], 'workshop_checksum_failed');
  });

  test('the hub being away is quiet, not an error', () async {
    http = _FakeHttp(const {}); // everything 404s
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.quiet, isTrue);
    expect(result.errors, isEmpty);
    expect(result.updated, isEmpty);
  });

  test('a pet the home side dropped stays on the phone (no remote uninstall)', () async {
    serve({'home-cat': packZip('home-cat', '1.0.0')}, {'home-cat': '1.0.0'});
    await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    serve(const {}, const {}); // home side withdrew it
    final result = await runAppHubPetAutoUpdate(pets: pets, base: base, http: http);
    expect(result.quiet, isTrue);
    expect((await pets.load('user-home-cat')).id, 'user-home-cat');
  });

  test('an id the APK ships built-in is skipped, not shadowed by the home side', () async {
    serve({'home-cat': packZip('home-cat', '1.0.0')}, {'home-cat': '1.0.0'});
    final result = await runAppHubPetAutoUpdate(
        pets: pets, base: base, http: http, skipPetIds: {'home-cat'});
    expect(result.updated, isEmpty);
    expect(result.skipped['pet/home-cat'], 'apphub_builtin');
    expect(await pets.list(), isEmpty);
  });
}
