// 工坊宠物包自动更新 (docs/design/pets.md §9): installed pet packs from this
// deployment's workshop are replaced by newer catalog releases, without any
// timer or retry loop — the caller (cold start, 宠物设置) decides when to run.
// The ordinary install path keeps its own fresh-catalog revalidation, so a
// stale cached snapshot here can never install a withdrawn release.

import 'workshop_models.dart';
import 'workshop_repository.dart';

/// What one pass did, for the settings page to show.
class WorkshopAutoUpdateResult {
  const WorkshopAutoUpdateResult({required this.updated, required this.skipped, required this.errors});
  final List<WorkshopInstalled> updated;

  /// Receipts left as they are, by `kind/id`: a stable reason code each.
  final Map<String, String> skipped;

  /// One package's failure never stops its neighbours; the error stays here
  /// keyed the same way, and is not swallowed.
  final Map<String, Object> errors;

  bool get quiet => updated.isEmpty && errors.isEmpty;
}

Future<WorkshopAutoUpdateResult> runWorkshopAutoUpdate({
  required WorkshopRepository repository,
  required Iterable<WorkshopLocalEntry> installed,
}) async {
  final client = repository.client;
  // The ordinary cached pull: a network failure falls back to the cache the
  // client already keeps, and any stale view is re-checked before installing.
  final catalog = (await client.catalog()).catalog;
  final updated = <WorkshopInstalled>[];
  final skipped = <String, String>{};
  final errors = <String, Object>{};
  for (final item in installed) {
    if (item is! WorkshopInstalled) continue;
    final receipt = item.receipt;
    // Other origins and kinds are not this deployment's business at all.
    if (receipt.kind != 'pet' || receipt.origin != client.origin) continue;
    final entry = catalog.find('pet', receipt.id);
    if (entry == null) {
      skipped[receipt.identity] = 'workshop_not_found';
      continue;
    }
    // Withdrawn, blocked and min-app releases all read unavailable here.
    final reason = catalog.unavailable(entry, repository.appVersion);
    if (reason != null) {
      skipped[receipt.identity] = reason;
      continue;
    }
    final comparison = WorkshopVersion.tryParse(entry.metadata.version)!
        .compareTo(WorkshopVersion.tryParse(receipt.version)!);
    if (comparison <= 0) {
      skipped[receipt.identity] = 'workshop_up_to_date';
      continue;
    }
    try {
      updated.add(await repository.install(entry, replaceExisting: true));
    } on Object catch (error) {
      errors[receipt.identity] = error;
    }
  }
  return WorkshopAutoUpdateResult(updated: updated, skipped: skipped, errors: errors);
}
