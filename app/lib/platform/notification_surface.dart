/// STEERWEB R7 + 01412FIX F4 (M5): the OS-notification surface for the
/// BROWSER delivery channel. The server ledger answers who may alert (ONE
/// claim per event); this surface only asks the browser for permission and
/// renders a claim the controller already won. Everywhere without the Web
/// Notification API is an honest no-op: permission false, nothing shown —
/// the in-app panel stays the single source of truth there.
library;

export 'notification_surface_native.dart'
    if (dart.library.js_interop) 'notification_surface_web.dart';

abstract class NotificationSurface {
  /// One prompt per session; false means NEVER show (panel-only fallback).
  Future<bool> ensurePermission();

  /// True only when the alert was actually handed to the OS; the caller
  /// reports shown/failed from this answer — never from a guess.
  bool show({required String title, required String body});
}
