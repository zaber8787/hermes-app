import 'dart:async';

import '../../l10n/app_locale.dart';
import '../../platform/stream_keepalive.dart';

/// Mirrors the committed app language to the Android foreground-service
/// notification (channel name + active title) through the SAME serialized
/// command queue as start/stop (I18N-PLAN §6.2/§6.5). Non-Android platforms
/// and web are explicit no-ops; a failed sync never touches stream tokens,
/// prompts, or chat traffic — the caller surfaces the localized warning.
Future<bool> syncNotificationLocale(AppLocale locale) =>
    StreamKeepalive.syncLocale(locale.tag);
