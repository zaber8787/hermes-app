import 'package:app_links/app_links.dart';

/// Native: the address bar does not exist; no live changes.
Stream<String> locationChanges() => const Stream<String>.empty();

/// NOTIF2 B2: the Android/iOS intent stream — cold launch AND warm links.
/// The initial event rides this stream (subscribe FIRST, never call the
/// initial getter as well: one delivery per link, from one place).
Stream<String> incomingLinks() =>
    AppLinks().uriLinkStream.map((uri) => uri.toString());
