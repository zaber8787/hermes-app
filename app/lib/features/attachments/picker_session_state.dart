import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import 'picker_session.dart';

/// The single terminal-decision machine shared by the web DOM driver and
/// the native wrapper — PRODUCTION code; the fake drivers in tests replay
/// events straight through it (IOS-PICKER-PLAN C1: never a test-only
/// reducer).
///
/// Only files / empty-change / cancel / fault may decide the outcome.
/// Focus never settles anything; it forwards a wake-up for the owner's
/// deadline check (file_picker_web 3.1.0's focus+500ms cancel race is
/// exactly what must NOT happen here).
class PickerSessionCore {
  PickerSessionCore({
    required void Function(PickerOutcome outcome) emit,
    required void Function() releaseDriver,
  }) : _emit = emit,
       _releaseDriver = releaseDriver;

  final void Function(PickerOutcome) _emit;
  final void Function() _releaseDriver;

  /// Window-focus wake-up; the owner may re-check its absolute deadline.
  /// Never a terminal source.
  void Function()? focusHint;

  bool _finished = false;
  bool _released = false;

  bool get isSettled => _finished;

  /// `change`: the driver has already copied the File handles synchronously.
  /// An empty list means no usable FileList entry — an anomalous empty,
  /// NOT a cancel. Zero-byte files are valid picks (they arrive as items).
  void files(List<PickedAttachment> items) {
    if (_finished) return;
    if (items.isEmpty) {
      _settle(const PickerEmptyUnexpected());
    } else {
      _settle(PickerPicked(items));
    }
  }

  /// `change` with a null/zero FileList — selection vanished.
  void emptyChange() {
    if (_finished) return;
    _settle(const PickerEmptyUnexpected());
  }

  /// The input's explicit standards-level `cancel` event (Esc / Cancel).
  void cancel() {
    if (_finished) return;
    _settle(const PickerCancelled());
  }

  /// DOM / JS / conversion fault. Typed descriptors keep their catalog key
  /// (I18N-PLAN §4.3); anything else gets the fixed retry message.
  void fault(Object error) {
    if (_finished) return;
    _settle(
      PickerFailed(
        error is UiCarriesMessage
            ? messageForError(error)
            : const UiMessage.local(MessageKey.attachmentPickerFailed),
      ),
    );
  }

  /// focus/blur/visibility never decide the outcome (PLAN B2); after
  /// terminal they do not even wake.
  void focus() {
    if (_finished) return;
    focusHint?.call();
  }

  /// Owner-side invalidation (timeout / dispose): every later event is
  /// dropped and the outcome future NEVER completes.
  void abandon() {
    _finished = true;
    _release();
  }

  void _settle(PickerOutcome outcome) {
    _finished = true;
    _release();
    _emit(outcome);
  }

  void _release() {
    if (_released) return;
    _released = true;
    _releaseDriver();
  }
}
