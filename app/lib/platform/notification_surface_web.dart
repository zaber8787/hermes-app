import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_surface.dart';

/// Browser builds ride the standard Notification API. A non-secure origin or
/// a denied prompt keeps every call a silent no-op (permission false) — the
/// panel already renders the same ledger, so nothing here is load-bearing.
class WebNotificationSurface implements NotificationSurface {
  const WebNotificationSurface();

  bool get _allowed {
    try {
      return web.Notification.permission == 'granted';
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> ensurePermission() async {
    if (_allowed) return true;
    try {
      if (web.Notification.permission == 'denied') return false;
      final answer = await web.Notification.requestPermission().toDart;
      return answer.toDart == 'granted';
    } on Object {
      return false; // insecure context / API missing: panel-only
    }
  }

  @override
  bool show({required String title, required String body}) {
    if (!_allowed) return false;
    try {
      web.Notification(
        title,
        web.NotificationOptions(body: body),
      );
      return true;
    } on Object {
      // a failed show must never touch the claim/read ledger flow
      return false;
    }
  }
}

NotificationSurface createNotificationSurface() =>
    const WebNotificationSurface();
