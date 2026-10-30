/// The call screen (PLAN-VOICEUI §4.3). Every element maps to one row of
/// the §4.7 table through [CallController.state] — the page itself owns no
/// call logic, only rendering and the two injectable seams (1s tick for
/// the brain seconds/pulse, pop cleanup for the single-call registry).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../models/session.dart';
import 'call_controller.dart';
import 'call_providers.dart';
import 'call_settings.dart';
import 'call_state.dart';

class CallPage extends ConsumerStatefulWidget {
  const CallPage({super.key});

  @override
  ConsumerState<CallPage> createState() => _CallPageState();
}

class _CallPageState extends ConsumerState<CallPage> {
  Timer? _ticker;
  bool _flip = false;
  Timer? _fillerTimer;
  String? _fillerShown;
  bool _fillerExpired = false;

  static const _voiceChannel = MethodChannel('hermes/voice-call');

  @override
  void initState() {
    super.initState();
    // 1Hz: brain seconds (§4.3 item 2) and the speaking pulse (§4.3 item 4).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final s = ref.read(activeCallProvider)?.state;
      if (s == null) return;
      if (s.brain == BrainIndicator.pending || s.assistantSpeaking) {
        setState(() => _flip = !_flip);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _fillerTimer?.cancel();
    super.dispose();
  }

  /// §4.2 last row: ended/error + pop disposes the controller; popping a
  /// LIVE call leaves it running (foreground service, §4.4) — the entry
  /// reopens it.
  void _clearIfFinished(CallController controller) {
    final phase = controller.state.phase;
    if (phase == CallPhase.ended || phase == CallPhase.error) {
      ref.read(activeCallProvider.notifier).clearIf(controller);
    }
  }

  void _close(CallController controller) {
    _clearIfFinished(controller);
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _openSystemSettings() async {
    try {
      await _voiceChannel.invokeMethod<void>('openAppSettings');
    } on MissingPluginException {
      // desktop/test host: nothing to open, the caption already said why
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(activeCallProvider);
    if (controller == null) {
      // Registry raced to null (ended elsewhere): an honest closed page.
      return Scaffold(
        appBar: AppBar(title: const Text('HERMES')),
        body: Center(
          child: FilledButton.tonal(
            key: const ValueKey('call.close'),
            onPressed: () => Navigator.canPop(context)
                ? Navigator.pop(context)
                : null,
            child: Text(AppStrings.of(context).resolve(MessageKey.callClose)),
          ),
        ),
      );
    }
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _clearIfFinished(controller);
      },
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _scaffold(context, ref, controller),
      ),
    );
  }

  Widget _scaffold(BuildContext context, WidgetRef ref, CallController controller) {
    final strings = AppStrings.of(context);
    final s = controller.state;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title(strings, s),
              key: const ValueKey('call.title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _status(strings, s),
              key: const ValueKey('call.status'),
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const ValueKey('call.settings'),
            tooltip: strings.resolve(MessageKey.callSettingsTitle),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showCallSettingsDialog(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          if (s.brain != BrainIndicator.none) _brainBar(strings, s),
          if (s.fillerHint != null) _filler(strings, s),
          Expanded(
            child: Stack(
              children: [
                _captions(context, strings, s),
                Align(alignment: Alignment.center, child: _orb(s)),
              ],
            ),
          ),
          _controls(context, ref, controller, strings, s),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  String _title(AppStrings strings, CallState s) {
    final target = s.target;
    if (target is SessionCallTarget) {
      return displaySessionTitle(strings, target.session.title);
    }
    return strings.resolve(MessageKey.callStandalone);
  }

  String _status(AppStrings strings, CallState s) => switch (s.phase) {
    CallPhase.idle => strings.resolve(MessageKey.callStatusConnecting),
    CallPhase.connecting when s.attempt == 0 =>
      strings.resolve(MessageKey.callStatusConnecting),
    CallPhase.connecting => strings.resolve(
      MessageKey.callStatusReconnecting,
      args: {'n': s.attempt},
    ),
    CallPhase.connected => strings.resolve(MessageKey.callStatusConnected),
    CallPhase.muted => strings.resolve(MessageKey.callStatusMuted),
    CallPhase.ended => strings.resolve(MessageKey.callStatusEnded),
    CallPhase.error => strings.resolve(_errorKey(s.errorKind)),
  };

  static MessageKey _errorKey(CallErrorKind? kind) =>
      switch (kind ?? CallErrorKind.network) {
        CallErrorKind.micDenied => MessageKey.callMicDenied,
        CallErrorKind.micPermanentlyDenied => MessageKey.callMicPermanentlyDenied,
        CallErrorKind.unsupported => MessageKey.callUnsupported,
        CallErrorKind.gatewayDown => MessageKey.callGatewayDown,
        CallErrorKind.auth => MessageKey.callAuth,
        CallErrorKind.busy => MessageKey.callBusy,
        CallErrorKind.network => MessageKey.callNetwork,
        CallErrorKind.protocol => MessageKey.callProtocol,
      };

  Widget _brainBar(AppStrings strings, CallState s) {
    final queued = s.brain == BrainIndicator.queued;
    return Padding(
      key: const ValueKey('call.brainBar'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          if (queued)
            const Icon(Icons.hourglass_empty, size: 14, color: Colors.orange)
          else
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              queued
                  ? strings.resolve(
                      s.queuedReason == 'voice_turn_ahead'
                          ? MessageKey.callBrainQueuedVoice
                          : MessageKey.callBrainQueued,
                    )
                  : strings.resolve(
                      MessageKey.callBrainPending,
                      args: {
                        'secs': s.brainSince == null
                            ? 0
                            : DateTime.now().difference(s.brainSince!).inSeconds,
                      },
                    ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filler(AppStrings strings, CallState s) {
    final text = s.fillerHint!;
    if (_fillerShown != text) {
      _fillerShown = text;
      _fillerExpired = false;
      _fillerTimer?.cancel();
      _fillerTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _fillerExpired = true);
      });
    }
    return AnimatedOpacity(
      opacity: _fillerExpired ? 0.0 : 1.0,
      duration: const Duration(milliseconds: 400),
      child: Padding(
        key: const ValueKey('call.fillerHint'),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          text,
          style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _captions(BuildContext context, AppStrings strings, CallState s) {
    return ListView(
      key: const ValueKey('call.captions'),
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      children: [
        for (final line in s.captions.reversed)
          switch (line.role) {
            CaptionRole.user => Align(
              alignment: Alignment.centerRight,
              child: Opacity(
                opacity: line.finalized ? 1 : 0.6,
                child: Text(
                  line.text,
                  style: TextStyle(
                    fontStyle: line.finalized ? FontStyle.normal : FontStyle.italic,
                  ),
                  textAlign: TextAlign.end,
                ),
              ),
            ),
            CaptionRole.assistant => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (line.source == 'brain')
                  const Padding(
                    padding: EdgeInsets.only(right: 4, top: 2),
                    child: Icon(Icons.memory_outlined, size: 14),
                  ),
                Expanded(child: Text(line.text)),
              ],
            ),
            CaptionRole.system => Center(
              child: Text(
                line.system == null ? line.text : strings.render(line.system!),
                style: const TextStyle(fontSize: 11, color: Colors.white54),
                textAlign: TextAlign.center,
              ),
            ),
          },
      ],
    );
  }

  Widget _orb(CallState s) {
    final flash =
        s.bargeAt != null &&
        DateTime.now().difference(s.bargeAt!) < const Duration(milliseconds: 600);
    return GestureDetector(
      // §5.3: debug-only diagnostics peek; release users see the orb.
      onLongPress: kDebugMode ? () => _showDiagnostics(s) : null,
      child: AnimatedContainer(
        key: const ValueKey('call.orb'),
        duration: const Duration(milliseconds: 250),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xff19232b),
          border: Border.all(
            color: s.userSpeaking || flash
                ? Theme.of(context).colorScheme.primary
                : Colors.white24,
            width: s.userSpeaking ? 4 : (flash ? 6 : 2),
          ),
        ),
        child: AnimatedScale(
          scale: s.assistantSpeaking ? (_flip ? 1.08 : 0.94) : 1.0,
          duration: const Duration(milliseconds: 500),
          child: const Icon(Icons.graphic_eq, size: 40, color: Colors.white38),
        ),
      ),
    );
  }

  void _showDiagnostics(CallState s) {
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(AppStrings.of(dialog).resolve(MessageKey.callSettingsTitle)),
        content: Text(
          'phase=${s.phase.name} attempt=${s.attempt} '
          'rtt_ms=${s.rttMs ?? '-'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(AppStrings.of(dialog).resolve(MessageKey.commonClose)),
          ),
        ],
      ),
    );
  }

  Widget _controls(
    BuildContext context,
    WidgetRef ref,
    CallController controller,
    AppStrings strings,
    CallState s,
  ) {
    if (s.phase == CallPhase.error) {
      final openSettings =
          s.errorKind == CallErrorKind.micPermanentlyDenied;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (openSettings)
              FilledButton.icon(
                key: const ValueKey('call.openSettings'),
                onPressed: _openSystemSettings,
                icon: const Icon(Icons.settings),
                label: Text(strings.resolve(MessageKey.callOpenSystemSettings)),
              )
            else
              FilledButton.icon(
                key: const ValueKey('call.retry'),
                onPressed: () => controller.retry(),
                icon: const Icon(Icons.refresh),
                label: Text(strings.resolve(MessageKey.callRetry)),
              ),
            FilledButton.tonal(
              key: const ValueKey('call.close'),
              onPressed: () => _close(controller),
              child: Text(strings.resolve(MessageKey.callClose)),
            ),
          ],
        ),
      );
    }
    if (s.phase == CallPhase.ended) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.tonal(
              key: const ValueKey('call.close'),
              onPressed: () => _close(controller),
              child: Text(strings.resolve(MessageKey.callClose)),
            ),
          ],
        ),
      );
    }
    final muted = s.phase == CallPhase.muted;
    final showSpeaker =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android; // D9
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            key: const ValueKey('call.mute'),
            tooltip: strings.resolve(
              muted ? MessageKey.callUnmute : MessageKey.callMute,
            ),
            icon: Icon(muted ? Icons.mic_off : Icons.mic),
            onPressed: controller.toggleMute,
          ),
          IconButton(
            key: const ValueKey('call.hangup'),
            tooltip: strings.resolve(MessageKey.callHangUp),
            icon: const Icon(Icons.call_end, size: 44, color: Color(0xffe0605a)),
            onPressed: () => controller.hangUp(),
          ),
          if (showSpeaker)
            IconButton(
              key: const ValueKey('call.speaker'),
              tooltip: strings.resolve(
                s.speakerOn ? MessageKey.callSpeakerOn : MessageKey.callSpeakerOff,
              ),
              icon: Icon(s.speakerOn ? Icons.volume_up : Icons.hearing),
              onPressed: () => controller.setSpeaker(!s.speakerOn),
            ),
        ],
      ),
    );
  }
}
