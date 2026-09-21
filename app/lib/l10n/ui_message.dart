import 'message_key.dart';

/// Everything an error surface may carry WITHOUT a locale (I18N-PLAN §4.3):
/// an immutable descriptor — local key + typed arguments, or explicit raw
/// server/user text. Never a pretranslated fragment, never a BuildContext.
sealed class UiMessage {
  const UiMessage();

  /// Server/user text shown byte-for-byte (never re-translated).
  const factory UiMessage.raw(String text) = UiRaw;

  /// App-created message resolved through the catalog at render time.
  const factory UiMessage.local(
    MessageKey key, {
    Map<String, Object?> args,
    int? count,
  }) = UiLocal;

  /// Count/status convenience: same local form with an explicit plural
  /// count (en branches; zh stays invariant).
  factory UiMessage.count(MessageKey key, int count,
          {Map<String, Object?> args = const {}}) =>
      UiLocal(key, args: args, count: count);
}

class UiRaw extends UiMessage {
  const UiRaw(this.text);
  final String text;
  @override
  String toString() => 'UiMessage.raw(${text.length} chars)';
}

class UiLocal extends UiMessage {
  const UiLocal(this.key, {this.args = const {}, this.count});
  final MessageKey key;
  final Map<String, Object?> args;
  final int? count;
  @override
  String toString() => 'UiMessage.local($key${count != null ? ': $count' : ''})';
}

/// Implementors carry a locale-independent descriptor; `UiMessage.forError`
/// checks this BEFORE any raw text so no key is ever recovered by matching
/// message wording (I18N-PLAN §4.3).
abstract interface class UiCarriesMessage {
  UiMessage get uiMessage;
}

/// Shared catch-site resolver (I18N-PLAN §4.3): typed exception
/// descriptors first, then explicit raw messages, then the technical text.
/// NEVER recovers a key by matching message wording.
UiMessage messageForError(Object e) => switch (e) {
  final UiCarriesMessage c => c.uiMessage,
  final FormatException f when f.message.isNotEmpty => UiRaw(f.message),
  _ => UiRaw('$e'),
};

/// App-created validation/parse failure that still satisfies existing
/// `is FormatException` catch sites while carrying a descriptor (§4.3).
/// Lives in the pure l10n layer so model files can throw it without
/// importing the api layer; hermes_repository re-exports it.
class AppFormatException extends FormatException implements UiCarriesMessage {
  const AppFormatException(this.uiMessage, [Object? source, int? offset])
    : super('local', source, offset); // 'local' is technical-only; UI renders
                                       // uiMessage.
  @override
  final UiMessage uiMessage;
  @override
  String toString() => 'AppFormatException($uiMessage)';
}

extension UiMessageTools on UiMessage {
  bool get isLocal => this is UiLocal;
}
