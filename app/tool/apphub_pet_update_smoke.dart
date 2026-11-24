// 开发冒烟(不走 flutter test,本机缺测试字体):对一台真 AppHub 跑
// runAppHubPetAutoUpdate 的完整两遍——第一遍应把目录里的宠物装进临时
// PetLibrary 并写记录,第二遍应按记录跳过。用法:
//   dart run tool/apphub_pet_update_smoke.dart http://127.0.0.1:7699
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/apphub_pet_update.dart';

Future<void> main(List<String> args) async {
  final Uri base = Uri.parse(args.isNotEmpty ? args.first : 'http://127.0.0.1:7610');
  final Directory temp = await Directory.systemTemp.createTemp('apphub-pet-smoke');
  final PetLibrary pets = PetLibrary(() async => Directory('${temp.path}/pets'));
  try {
    final first = await runAppHubPetAutoUpdate(pets: pets, base: base);
    stdout.writeln('pass 1: updated=${first.updated} skipped=${first.skipped} errors=${first.errors}');
    final installed = await pets.list();
    stdout.writeln('installed: ${[for (final pack in installed) pack.id]}');
    for (final pack in installed) {
      final record = File('${temp.path}/pets/${pack.id}/.apphub-pet.json');
      stdout.writeln('  record ${pack.id}: ${record.existsSync() ? 'present' : 'MISSING'}'
          '${record.existsSync() ? ' ${jsonDecode(await record.readAsString())['version']}' : ''}');
    }
    final second = await runAppHubPetAutoUpdate(pets: pets, base: base);
    stdout.writeln('pass 2: updated=${second.updated} skipped=${second.skipped} errors=${second.errors}');
    if (first.updated.isEmpty) {
      stdout.writeln('SMOKE: nothing to install (hub empty or unreachable) — install path untested');
    } else if (second.updated.isNotEmpty || second.errors.isNotEmpty) {
      stdout.writeln('SMOKE: FAIL — second pass must be quiet');
      exitCode = 1;
    } else {
      stdout.writeln('SMOKE: OK');
    }
  } finally {
    await temp.delete(recursive: true);
  }
}
