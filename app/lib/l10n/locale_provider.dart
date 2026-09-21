import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'app_locale.dart';
import 'message_key.dart';
import 'ui_message.dart';

/// Startup locale loaded BEFORE runApp from the already-created LocalStore,
/// independently of the credential try/catch (I18N-PLAN §4.2). Overridden
/// in main.dart; the fallback here is the fixed English default.
final initialLocaleProvider = Provider<AppLocale>((ref) => AppLocale.en);

/// Committed UI language + last preference-save failure (as a descriptor,
/// never a translated string). Independent of settingsProvider/repository
/// on purpose: choosing a language must never rebuild network objects.
final localeProvider = NotifierProvider<LocaleNotifier, LocaleState>(
  LocaleNotifier.new,
);

class LocaleState {
  const LocaleState(this.locale, [this.saveError]);
  final AppLocale locale;
  final UiMessage? saveError;
}

class LocaleNotifier extends Notifier<LocaleState> {
  /// Serialized write chain: the LATEST user choice always wins; a failed
  /// write keeps the previous committed locale (plan §4.2).
  Future<void> _writes = Future.value();

  @override
  LocaleState build() => LocaleState(ref.read(initialLocaleProvider));

  /// Records a notification mirror failure (dispatched by the app-level
  /// locale listener, I18N-PLAN §6.2). Warns in the CURRENT language when
  /// the UI locale has not moved again meanwhile; never reverts a commit.
  void reportMirrorFailure(AppLocale failed) {
    if (state.locale != failed) return;
    state = LocaleState(
      failed,
      const UiMessage.local(
        MessageKey.settingsNotificationLanguageSyncFailed,
      ),
    );
  }

  /// Returns whether the preference persisted. On failure the OLD locale
  /// stays committed and saveError carries settings.languageSaveFailed;
  /// the caller renders it in the still-current language. Same-value
  /// selection is a no-op (no write, no new state).
  Future<bool> select(AppLocale next) {
    // Each queued write resolves against ITS OWN requested target, so a
    // rapid switch chain ends at the last committed choice.
    final target = next;
    final completer = _writes.then((_) async {
      if (state.locale == target) return true; // committed / no-op
      try {
        final ok = await ref.read(localStoreProvider).saveLocale(target);
        if (!ok) {
          state = LocaleState(
            state.locale,
            const UiMessage.local(MessageKey.settingsLanguageSaveFailed),
          );
          return false;
        }
        state = LocaleState(target); // one changed value per successful write
        return true;
      } catch (_) {
        state = LocaleState(
          state.locale,
          const UiMessage.local(MessageKey.settingsLanguageSaveFailed),
        );
        return false;
      }
    });
    _writes = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  /// Called by the UI after surfacing saveError.
  void clearSaveError() {
    if (state.saveError != null) state = LocaleState(state.locale);
  }
}
