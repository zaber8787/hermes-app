/// Effective keyboard semantics for the chat composer.
///
/// Mobile BROWSERS report Android/iOS through defaultTargetPlatform, which
/// would wrongly flip web builds to mobile key semantics. Conditional import
/// keeps that impossible: web builds always resolve to the desktop policy.
/// The fixed web value influences ONLY key/IME decisions — never Theme or the
/// global platform.
library;

export 'chat_input_platform_native.dart'
    if (dart.library.js_interop) 'chat_input_platform_web.dart';