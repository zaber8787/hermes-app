import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/hermes_repository.dart';
import '../../l10n/app_locale.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../providers.dart';
import 'local_store.dart';
import 'server_url.dart';
import '../../diagnostics/diagnostics.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialError});
  final UiMessage? initialError;
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController url, key;
  bool obscure = true, busy = false, savingLanguage = false;
  // A descriptor, never a translated string: it re-renders when the UI
  // language changes while this page stays open (I18N-PLAN §4.5).
  UiMessage? feedback;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    url = TextEditingController(text: s.url);
    key = TextEditingController(text: s.key);
    feedback = widget.initialError;
  }

  @override
  void dispose() {
    url.dispose();
    key.dispose();
    super.dispose();
  }

  AppSettings validated() {
    // One shared validator with the app-wide `configured` gate (§4.1.2):
    // nothing that passes here can produce a relative/network-less request.
    final normalized = normalizeServerUrl(url.text.trim());
    if (normalized.isEmpty) {
      throw const AppFormatException(
        UiMessage.local(MessageKey.settingsM001),
      );
    }
    if (key.text.trim().isEmpty) {
      throw const AppFormatException(UiMessage.local(MessageKey.settingsM002));
    }
    return AppSettings(url: normalized, key: key.text.trim());
  }

  Future<void> _selectLanguage(AppLocale next) async {
    if (savingLanguage) return;
    setState(() => savingLanguage = true);
    try {
      final notifier = ref.read(localeProvider.notifier);
      final ok = await notifier.select(next);
      if (!ok && mounted) {
        final pending = ref.read(localeProvider).saveError;
        notifier.clearSaveError();
        // Resolved lazily via LocalizedText, in the language still shown.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: LocalizedText(
                pending ?? const UiMessage.local(MessageKey.settingsLanguageSaveFailed),
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => savingLanguage = false);
    }
  }

  Future<void> test() async {
    setState(() {
      busy = true;
      feedback = null;
    });
    HermesRepository? repo;
    try {
      final s = validated();
      repo = HermesRepository(s.url, s.key);
      await repo.checkCapabilities();
      final alive = await repo.health();
      if (mounted) {
        setState(
          () => feedback = alive
              ? const UiMessage.local(MessageKey.settingsM003)
              : const UiMessage.local(MessageKey.settingsM004),
        );
      }
    } on AppFormatException catch (e) {
      if (mounted) setState(() => feedback = e.uiMessage);
    } on FormatException catch (e) {
      if (mounted) setState(() => feedback = UiRaw(e.message));
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = const UiMessage.local(MessageKey.settingsM005),
        );
      }
    } finally {
      repo?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await ref.read(settingsProvider.notifier).save(validated());
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } on AppFormatException catch (e) {
      if (mounted) setState(() => feedback = e.uiMessage);
    } on FormatException catch (e) {
      if (mounted) setState(() => feedback = UiRaw(e.message));
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = const UiMessage.local(MessageKey.settingsM006),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final current = ref.watch(localeProvider).locale;
    // Deferred warnings (e.g. notification mirror failure) surface here,
    // resolved in the language currently on screen (I18N-PLAN §6 keys).
    ref.listen(localeProvider, (previous, next) {
      final error = next.saveError;
      if (error != null) {
        ref.read(localeProvider.notifier).clearSaveError();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LocalizedText(error)),
        );
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.resolve(MessageKey.settingsM007)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.hub_outlined,
                size: 44,
                color: Theme.of(context).colorScheme.primary,
              ),
              ListTile(
                title: Text(
                  strings.resolve(
                    MessageKey.settingsM009,
                    args: {
                      'version':
                          Diagnostics.current?.version ??
                          strings.resolve(MessageKey.settingsM008),
                    },
                  ),
                ),
                subtitle: Text(strings.resolve(MessageKey.settingsM010)),
              ),
              OutlinedButton.icon(
                onPressed: Diagnostics.current == null
                    ? null
                    : () async {
                        try {
                          final saved = await Diagnostics.current!.export();
                          if (mounted) {
                            setState(
                              () => feedback = saved
                                  ? const UiMessage.local(
                                      MessageKey.settingsM011,
                                    )
                                  : const UiMessage.local(
                                      MessageKey.downloadCancelled,
                                    ),
                            );
                          }
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => feedback = const UiMessage.local(
                                MessageKey.settingsM012,
                              ),
                            );
                          }
                        }
                      },
                icon: const Icon(Icons.save_alt),
                label: Text(strings.resolve(MessageKey.settingsM013)),
              ),
              const SizedBox(height: 24),
              // Language FIRST (I18N-PLAN §1): usable with an empty/invalid
              // server config; changing it never touches the network graph.
              Semantics(
                key: const ValueKey('settings.language'),
                label: strings.resolve(MessageKey.settingsLanguage),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.resolve(MessageKey.settingsLanguage),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<AppLocale>(
                      segments: [
                        ButtonSegment(
                          value: AppLocale.en,
                          label: KeyedSubtree(
                            key: const ValueKey('language.en'),
                            child: Text(
                              strings.resolve(MessageKey.languageEnglish),
                            ),
                          ),
                        ),
                        ButtonSegment(
                          value: AppLocale.zhHant,
                          label: KeyedSubtree(
                            key: const ValueKey('language.zhHant'),
                            child: Text(
                              strings.resolve(
                                MessageKey.languageTraditionalChinese,
                              ),
                            ),
                          ),
                        ),
                      ],
                      selected: {current},
                      showSelectedIcon: false,
                      onSelectionChanged: savingLanguage
                          ? null
                          : (s) => _selectLanguage(s.first),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                strings.resolve(MessageKey.settingsM014),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(strings.resolve(MessageKey.settingsM015)),
              const SizedBox(height: 32),
              TextField(
                controller: url,
                enabled: !busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: strings.resolve(MessageKey.settingsServerUrl),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: key,
                enabled: !busy,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: strings.resolve(MessageKey.settingsApiKey),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: strings.resolve(
                      obscure ? MessageKey.settingsM016 : MessageKey.settingsM017,
                    ),
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                strings.resolve(MessageKey.settingsM018),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 24),
              if (feedback != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: LocalizedText(feedback!),
                ),
              OutlinedButton.icon(
                onPressed: busy ? null : test,
                icon: const Icon(Icons.network_check),
                label: Text(strings.resolve(MessageKey.settingsM019)),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: busy ? null : save,
                child: Text(strings.resolve(MessageKey.settingsM020)),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
