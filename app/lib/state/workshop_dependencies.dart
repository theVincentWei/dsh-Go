import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../companion/companion_float.dart' show companionFloatStoreProvider;
import '../notify/apphub_base.dart' show appHubBase;
import '../pets/overlay_channel.dart' show petOverlayChannelProvider;
import '../pets/pet_library.dart';
import '../pets/pet_prefs.dart';
import '../pets/pet_sheets.dart';
import '../pets/pet_signals.dart' show petPackProvider, userPetsProvider;
import '../workshop/apphub_pet_update.dart';
import '../workshop/workshop_auto_update.dart';
import '../workshop/workshop_client.dart';
import '../workshop/workshop_http.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';
import 'app_info.dart';

/// The owner supplies a deployment, either with this provider or at build time.
/// An absent deployment is a state error, never an implicit third-party host.
final workshopOriginProvider = Provider<Uri?>((ref) {
  const configured = String.fromEnvironment('DSH_WORKSHOP_ORIGIN');
  if (configured.isEmpty) return null;
  final parsed = Uri.tryParse(configured);
  if (parsed == null) workshopInvalid('workshop_untrusted_origin');
  return workshopOrigin(parsed);
});

/// Tests replace the existing storage/network seams, without loading a page.
final workshopDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => () async => Directory('${(await getApplicationSupportDirectory()).path}/workshop'),
);
final workshopHttpFactoryProvider = Provider<WorkshopHttp Function(Uri)>(
  (ref) => IoWorkshopHttp.new,
);
final workshopAppVersionProvider = Provider<String>((ref) => AppInfo.version);

final workshopClientProvider = FutureProvider<WorkshopClient>((ref) async {
  final configured = ref.watch(workshopOriginProvider);
  final directory = ref.watch(workshopDirectoryProvider);
  final createHttp = ref.watch(workshopHttpFactoryProvider);
  var disposed = false;
  WorkshopClient? owned;
  ref.onDispose(() {
    disposed = true;
    owned?.close();
  });
  if (configured == null) workshopInvalid('workshop_unconfigured');
  final origin = workshopOrigin(configured);
  final root = await directory();
  if (disposed || !ref.mounted) workshopInvalid('workshop_cancelled');
  final client = WorkshopClient(
    origin: origin,
    cacheFile: File('${root.path}/catalog.json'),
    http: createHttp(origin),
  );
  owned = client;
  return client;
}, retry: (_, _) => null);

/// Local receipts and receipt-fenced removal work without a configured Worker.
/// Stores are borrowed; this provider never closes a companion reader/store.
final workshopPackagesProvider = FutureProvider<WorkshopPackages>((ref) async {
  final pets = ref.watch(petLibraryProvider);
  final loadCompanion = ref.watch(companionFloatStoreProvider);
  final companion = await loadCompanion();
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  return LocalWorkshopPackages(pets: pets, companion: companion);
}, retry: (_, _) => null);

final workshopRepositoryProvider = FutureProvider<WorkshopRepository>((ref) async {
  final clientFuture = ref.watch(workshopClientProvider.future);
  final packagesFuture = ref.watch(workshopPackagesProvider.future);
  final directory = ref.watch(workshopDirectoryProvider);
  final version = ref.watch(workshopAppVersionProvider);
  // Capture every watched dependency before the first suspension. The client
  // provider owns the connection; this repository only borrows it.
  final dependencies = await Future.wait<Object>([clientFuture, packagesFuture, directory()]);
  final client = dependencies[0] as WorkshopClient;
  final packages = dependencies[1] as WorkshopPackages;
  final root = dependencies[2] as Directory;
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  return WorkshopRepository(
    client: client,
    packages: packages,
    downloadDirectory: Directory('${root.path}/downloads'),
    appVersion: version,
  );
}, retry: (_, _) => null);

/// Called only by explicit actions. Healthy dependencies remain shared/open.
void retryWorkshopDependencies(Ref ref, {bool includeLocal = false}) {
  final clientFailed = ref.exists(workshopClientProvider) && ref.read(workshopClientProvider).hasError;
  final packagesFailed = includeLocal && ref.exists(workshopPackagesProvider) &&
      ref.read(workshopPackagesProvider).hasError;
  final repositoryFailed = includeLocal && ref.exists(workshopRepositoryProvider) &&
      ref.read(workshopRepositoryProvider).hasError;
  if (clientFailed) ref.invalidate(workshopClientProvider);
  if (packagesFailed) ref.invalidate(workshopPackagesProvider);
  if (repositoryFailed) ref.invalidate(workshopRepositoryProvider);
}

typedef WorkshopPackageChanged = Future<void> Function(
  WorkshopInstalled item, {
  required bool removed,
});

/// 工坊 + AppHub 两个宠物源一次跑完的合计结果。设置页只看更新了几只、
/// 有没有失败;来源细节留在各自 pass 的 result 里。
class PetAutoUpdateOutcome {
  const PetAutoUpdateOutcome({required this.updatedCount, required this.hasErrors});
  final int updatedCount;
  final bool hasErrors;
  bool get quiet => updatedCount == 0 && !hasErrors;
}

/// 宠物包自动更新:冷启动 (app.dart) 与宠物设置页各拉起一次,不设定时器。
/// 工坊源(上游创意工坊)与 AppHub 源(家端)各跑一遍:
///   - 工坊:没有工坊、偏好未加载或开关关闭时跳过;工坊自身的异常不吞,
///     由调用方决定怎么展示(与旧行为一致)。
///   - AppHub:受同一个「宠物自动更新」开关管;家端不在家(连不上、非 200)
///     在 runAppHubPetAutoUpdate 里静默跳过——这是常态而不是故障。
/// 开关关闭或偏好未加载时返回 null,什么都不做。
final workshopPetAutoUpdateProvider = Provider<Future<PetAutoUpdateOutcome?> Function()>((ref) {
  return () async {
    final prefs = ref.read(petPrefsProvider);
    if (!prefs.loaded || !prefs.workshopAutoUpdate) return null;
    // Same question as ui/workshop's workshopAvailableProvider, without that
    // ui import here. The AppHub pass runs with or without a workshop: the
    // home source doesn't depend on the upstream one.
    WorkshopAutoUpdateResult? workshop;
    if (ref.read(workshopOriginProvider) != null) {
      final repository = await ref.read(workshopRepositoryProvider.future);
      workshop = await runWorkshopAutoUpdate(
          repository: repository, installed: await repository.installed());
    }
    final AppHubPetUpdateResult hub = await runAppHubPetAutoUpdate(
        pets: ref.read(petLibraryProvider), base: Uri.parse(appHubBase));
    return PetAutoUpdateOutcome(
      updatedCount: (workshop?.updated ?? const <WorkshopInstalled>[]).length +
          hub.updated.length,
      hasErrors: (workshop?.errors.isNotEmpty ?? false) || hub.errors.isNotEmpty,
    );
  };
});

Future<void> _waitPetPreferences(Ref ref) async {
  if (!ref.mounted) workshopInvalid('workshop_cancelled');
  if (ref.read(petPrefsProvider).loaded) return;
  final done = Completer<void>();
  void Function()? stopListening;
  final removeDispose = ref.onDispose(() {
    if (!done.isCompleted) done.completeError(const WorkshopException('workshop_cancelled'));
  });
  try {
    final subscription = ref.listen<bool>(
      petPrefsProvider.select((prefs) => prefs.loaded),
      (_, loaded) {
        if (loaded && !done.isCompleted) done.complete();
      },
      onError: (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      fireImmediately: true,
    );
    stopListening = subscription.close;
    await done.future;
  } finally {
    stopListening?.call();
    removeDispose();
  }
}

/// A successful filesystem mutation also refreshes the existing pet consumers.
/// Controllers report failure here separately: the package has already changed.
/// This hook does not watch the Worker, so an already-committed old-origin
/// operation can still refresh the local resource it changed.
final workshopPackageChangedProvider = Provider<WorkshopPackageChanged>((ref) {
  return (item, {required removed}) async {
    if (item.receipt.kind != 'pet') return;
    PetSheets.instance.forget(item.localId);
    if (!ref.mounted) return;
    ref.invalidate(petPackProvider(item.localId));
    ref.invalidate(userPetsProvider);
    try {
      if (removed) {
        await _waitPetPreferences(ref);
        if (!ref.mounted) return;
        if (ref.read(petPrefsProvider).packId == item.localId) {
          await ref.read(petPrefsProvider.notifier).replacePack(defaultPetId);
        }
      }
      if (ref.mounted) await ref.read(petOverlayChannelProvider).reloadPack(item.localId);
    } on Object {
      throw const WorkshopException('workshop_local_refresh');
    }
  };
});
