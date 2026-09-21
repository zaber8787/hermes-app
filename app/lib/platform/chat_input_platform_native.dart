import 'package:flutter/foundation.dart';

/// Test-only hook (widget tests exercise both key semantics in one binary).
/// Must not ship set in production.
TargetPlatform? debugChatInputPlatform;

/// Native devices: the physical/soft keyboard follows the real platform.
TargetPlatform get chatInputPlatform =>
    debugChatInputPlatform ?? defaultTargetPlatform;
