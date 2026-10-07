import 'notification_surface.dart';

/// Native (mobile/desktop-VM) builds have no browser Notification API here:
/// permission is honestly false and show is a no-op. The notification panel
/// already covers these platforms.
class NoopNotificationSurface implements NotificationSurface {
  const NoopNotificationSurface();

  @override
  Future<bool> ensurePermission() async => false;

  @override
  bool show({required String title, required String body}) => false;
}

NotificationSurface createNotificationSurface() =>
    const NoopNotificationSurface();
