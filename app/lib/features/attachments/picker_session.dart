import '../../l10n/ui_message.dart';
import 'picker_session_io.dart'
    if (dart.library.js_interop) 'picker_session_web.dart'
    as impl;

/// One selected file: display name, optional known byte size and a
/// SINGLE-SUBSCRIPTION byte stream (the web FileList handle cannot be
/// re-read; consumers must open it exactly once).
class PickedAttachment {
  const PickedAttachment({
    required this.name,
    this.knownSize,
    required this.openStream,
  });

  final String name;
  final int? knownSize;
  final Stream<List<int>> Function() openStream;
}

/// Closed outcome set of one file-selection session (IOS-PICKER-PLAN B1):
/// never null, never an empty list that conflates cancel with failure.
sealed class PickerOutcome {
  const PickerOutcome();
}

/// Files selected; order preserved. Zero-byte files are valid picks.
final class PickerPicked extends PickerOutcome {
  const PickerPicked(this.items);
  final List<PickedAttachment> items;
}

/// The user (or the browser's standards-level cancel event) said no.
final class PickerCancelled extends PickerOutcome {
  const PickerCancelled();
}

/// A `change` with no usable FileList — selection vanished. NOT a cancel
/// (PLAN B2): consumers must show a retryable error.
final class PickerEmptyUnexpected extends PickerOutcome {
  const PickerEmptyUnexpected();
}

/// DOM / native / conversion fault with a typed, locale-free descriptor.
final class PickerFailed extends PickerOutcome {
  const PickerFailed(this.message);
  final UiMessage message;
}

/// One started file-selection session. [outcome] completes exactly once,
/// or never when [abort] ran first. [abort] and terminal completion share
/// one idempotent cleanup (PLAN B2). [onFocusHint] receives window-focus
/// wake-ups for deadline checks only — focus can never decide the outcome.
abstract class PickerSession {
  Future<PickerOutcome> get outcome;
  void abort();
  set onFocusHint(void Function()? hint);
}

/// Start a fresh session (fresh DOM input on web, fresh native dialog on
/// io). Must be called from the user-tap synchronous call stack on web.
typedef PickerFactory = PickerSession Function();

PickerSession createPickerSession() => impl.createPickerSession();
