/// The call's dependency seams (§4.8): the two factory providers exist so
/// widget tests can inject a fake socket/audio without touching any real
/// channel, and [activeCallProvider] is the whole-app single-call registry
/// (§4.4: one CallController at a time, every entry reopens THIS one).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_audio.dart';
import 'call_controller.dart';
import 'gateway_socket.dart';

final gatewayConnectorProvider = Provider<GatewayConnector>(
  (ref) => defaultGatewayConnector,
);

final callAudioFactoryProvider = Provider<CallAudio Function()>(
  (ref) => newCallAudio,
);

class ActiveCallNotifier extends Notifier<CallController?> {
  @override
  CallController? build() => null;

  /// Installs the live call; anything it replaces is disposed (an old
  /// finished controller must never keep its timers alive).
  void set(CallController? controller) {
    final previous = state;
    if (previous != null && !identical(previous, controller)) {
      previous.dispose();
    }
    state = controller;
  }

  /// Detaches (and disposes) exactly this controller — a page popping an
  /// ended call must not clear a newer call that raced ahead of it.
  void clearIf(CallController? controller) {
    if (identical(state, controller)) {
      state = null;
      controller?.dispose();
    }
  }
}

final activeCallProvider =
    NotifierProvider<ActiveCallNotifier, CallController?>(
      ActiveCallNotifier.new,
    );
