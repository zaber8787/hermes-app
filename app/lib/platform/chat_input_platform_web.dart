import 'package:flutter/foundation.dart';

/// Test-only hook (widget tests exercise both key semantics in one binary).
/// Must not ship set in production.
TargetPlatform? debugChatInputPlatform;

/// Web — including mobile browsers, whose defaultTargetPlatform reports
/// Android/iOS — always keeps DESKTOP composer semantics: Enter sends,
/// Shift+Enter breaks a line. This fixed value is used for input decisions
/// only and never touches Theme or the global platform identity.
TargetPlatform get chatInputPlatform =>
    debugChatInputPlatform ?? TargetPlatform.macOS;
