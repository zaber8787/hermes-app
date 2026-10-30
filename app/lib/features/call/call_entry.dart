/// Call entry points (PLAN-VOICEUI §4.4/§4.8): one funnel ([openCall]) for
/// every "call" affordance, so the single-call rule lives in exactly one
/// place; a target picker; and the toolbar button. The route is registered
/// the way every other page in this app registers one — an imperative
/// Navigator push with a named RouteSettings ('/call', §4.8).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../models/session.dart';
import '../../providers.dart';
import 'call_audio.dart';
import 'call_controller.dart';
import 'call_page.dart';
import 'call_providers.dart';
import 'call_settings.dart';
import 'call_state.dart';

/// The /call route name (§6.2 call_entry_test pins it).
const callRouteName = '/call';

bool _opening = false;

Future<void> openCall(
  BuildContext context,
  WidgetRef ref,
  CallTarget target,
) async {
  if (_opening) return; // double-tap while the endpoint resolves
  final existing = ref.read(activeCallProvider);
  if (existing != null) {
    final phase = existing.state.phase;
    if (phase != CallPhase.ended && phase != CallPhase.error) {
      // §4.4 single call: reopen the running page, never a second socket.
      _pushCallPage(context);
      return;
    }
    ref.read(activeCallProvider.notifier).clearIf(existing);
  }
  _opening = true;
  try {
    final endpoint = await resolveCallEndpoint(
      ref.read(localStoreProvider),
      ref.read(settingsProvider),
    );
    if (!context.mounted) return;
    final controller = CallController(
      target: target,
      url: endpoint.url,
      token: endpoint.token,
      connect: ref.read(gatewayConnectorProvider),
      audio: ref.read(callAudioFactoryProvider)(),
    );
    ref.read(activeCallProvider.notifier).set(controller);
    _pushCallPage(context);
    unawaited(controller.start());
  } finally {
    _opening = false;
  }
}

void _pushCallPage(BuildContext context) {
  unawaited(
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: callRouteName),
        builder: (_) => const CallPage(),
      ),
    ),
  );
}

/// Bottom sheet: standalone first, then the loaded session list (≤30,
/// list-page order, §4.8), gear opens the endpoint dialog (§4.5).
Future<void> showCallTargetPicker(BuildContext context, WidgetRef ref) {
  final sessions =
      ref.read(sessionsProvider).asData?.value ?? const <Session>[];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AppStrings.of(sheet).resolve(MessageKey.callPickTarget),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey('call.settings.picker'),
                  tooltip: AppStrings.of(sheet)
                      .resolve(MessageKey.callSettingsTitle),
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => showCallSettingsDialog(sheet, ref),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  key: const ValueKey('call.pick.standalone'),
                  leading: const Icon(Icons.graphic_eq),
                  title: Text(
                    AppStrings.of(sheet).resolve(MessageKey.callStandalone),
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(
                      openCall(context, ref, const StandaloneCallTarget()),
                    );
                  },
                ),
                for (final s in sessions.take(30))
                  ListTile(
                    key: ValueKey('call.pick.session.${s.id}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(
                      displaySessionTitle(AppStrings.of(sheet), s.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      unawaited(openCall(context, ref, SessionCallTarget(s)));
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Toolbar button: renders NOTHING where a call cannot work (§4.8: never
/// an inert icon), and reads no throwing provider during build — all
/// reading happens in the tap handler.
class CallButton extends ConsumerWidget {
  const CallButton({super.key, required this.target});
  final CallTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!callSupported) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('call.button'),
      tooltip: AppStrings.of(context).resolve(MessageKey.callStart),
      icon: const Icon(Icons.call_outlined),
      onPressed: () => unawaited(openCall(context, ref, target)),
    );
  }
}
