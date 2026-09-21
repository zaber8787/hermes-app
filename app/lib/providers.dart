import 'package:flutter_riverpod/flutter_riverpod.dart';
// ProviderOrFamily (eviction drop target) lives in riverpod's misc export.
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;
import 'package:flutter_riverpod/legacy.dart';
import 'api/hermes_repository.dart';
import 'features/settings/local_store.dart';
import 'features/chat/chat_controller.dart';
import 'l10n/message_key.dart';
import 'models/session.dart';
import 'features/attachments/attachment_controller.dart';
import 'features/chat/viewers.dart';

// The locale state lives in l10n/locale_provider.dart; re-exported here so
// every surface imports providers.dart as before (network graph untouched).
export 'l10n/locale_provider.dart';

final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError(),
);
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);
final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(initialSettingsProvider);
  Future<void> save(AppSettings next) async {
    await ref.read(localStoreProvider).saveSettings(next);
    state = next;
  }
}

final repositoryProvider = Provider<HermesRepository>((ref) {
  final s = ref.watch(settingsProvider);
  final repo = HermesRepository(s.url, s.key);
  ref.onDispose(repo.close);
  return repo;
});
final compatibilityProvider = FutureProvider<void>((ref) async {
  if (!ref.watch(settingsProvider).configured) {
    throw const ApiException.local(MessageKey.connectionM001);
  }
  await ref.watch(repositoryProvider).checkCapabilities();
});
final sessionsProvider = FutureProvider<List<Session>>((ref) async {
  await ref.watch(compatibilityProvider.future);
  return ref.watch(repositoryProvider).sessions();
});
final skillsProvider = FutureProvider<List<Skill>>((ref) async {
  await ref.watch(compatibilityProvider.future);
  return ref.watch(repositoryProvider).skills();
});
final modelOptionsProvider =
    FutureProvider<({List<Map<String, dynamic>> models, String global})>((
      ref,
    ) async {
      await ref.watch(compatibilityProvider.future);
      return ref.watch(repositoryProvider).modelCatalog();
    });
final memoriesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  await ref.watch(compatibilityProvider.future);
  return ref.watch(repositoryProvider).memories();
});
final healthProvider = FutureProvider<bool>((ref) async {
  if (!ref.watch(settingsProvider).configured) return false;
  await ref.watch(compatibilityProvider.future);
  return ref.watch(repositoryProvider).health();
});
// Kept alive while navigating: leaving a chat must not cancel a running POST.
// AUDIT-16: "alive" is now bounded — evictIdleChatControllers() drops the
// oldest idle controllers past chatIdleCap. This family must NOT become
// autoDispose: a page pop intentionally keeps the running turn (and its
// detached poll) alive — that is the v0.12 background-survival contract.
final chatProvider = ChangeNotifierProvider.family<ChatController, String>((
  ref,
  sid,
) {
  return ChatController(
    ref.watch(repositoryProvider),
    ref.watch(localStoreProvider),
    sid,
    serverUrl: ref.watch(settingsProvider).url,
  );
});

/// How many idle (no page, no running turn) chat controllers may stay
/// resident at once. Sessions with a page on screen or an unfinished turn
/// are exempt and do not count against this.
const chatIdleCap = 8;

/// AUDIT-16: retire the least-recently-seen idle controllers (and their
/// attachment sidekicks) so a day of browsing N sessions costs a bounded
/// memory instead of N controllers + observers. Callers inject their read
/// and drop primitives (WidgetRef vs ProviderContainer differ in type
/// only). Takes the CURRENT alive-idle snapshot, evicts oldest first;
/// anything running is skipped without consuming the surplus budget.
void evictIdleChatControllers({
  required ChatController Function(String sid) readChat,
  required void Function(ProviderOrFamily provider) drop,
}) {
  final idle = ChatViewers.idleResidents(); // LRU order, viewers==0
  var surplus = idle.length - chatIdleCap;
  if (surplus <= 0) return;
  for (final sid in idle) {
    if (surplus == 0) break;
    final c = readChat(sid); // registered sid ⇒ no rebuild, just the alive one
    if (c.busy || c.sendBlocked || c.loading) continue; // running turn: pinned
    // Leave the ledger BEFORE dropping: the (possibly deferred) notifier
    // dispose must never resurrect a tombstone, and later passes must not
    // re-read (and thereby rebuild) what this pass already retired.
    ChatViewers.unregister(sid, c);
    drop(chatProvider(sid));
    drop(attachmentsProvider(sid));
    surplus--;
  }
}

final attachmentsProvider =
    ChangeNotifierProvider.family<AttachmentController, String>((ref, sid) {
      return AttachmentController(
        ref.watch(repositoryProvider),
        ref.watch(localStoreProvider),
        sid,
      );
    });
