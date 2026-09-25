import 'dart:async';

import 'package:file_picker/file_picker.dart';

import 'picker_session.dart';
import 'picker_session_state.dart';

/// Native (dart:io) session: the untouched FilePicker 12.3.0 flow, wrapped
/// into the closed outcome set. An empty result list is, by the native API
/// contract, a cancel — the existing silence semantics are preserved
/// (IOS-PICKER-PLAN B1). Nothing here touches permissions or plugin setup.
PickerSession createPickerSession() => _IoPickerSession();

class _IoPickerSession implements PickerSession {
  _IoPickerSession() {
    _core = PickerSessionCore(emit: _out.complete, releaseDriver: () {});
    unawaited(
      FilePicker.pickFiles().then<void>((files) {
        if (files.isEmpty) {
          _core.cancel();
          return;
        }
        _core.files([for (final f in files) _toPicked(f)]);
      }, onError: (Object error) => _core.fault(error)),
    );
  }

  late final PickerSessionCore _core;
  final Completer<PickerOutcome> _out = Completer<PickerOutcome>();

  @override
  Future<PickerOutcome> get outcome => _out.future;

  @override
  void abort() => _core.abandon();

  @override
  set onFocusHint(void Function()? hint) => _core.focusHint = hint;
}

PickedAttachment _toPicked(PlatformFile file) {
  var opened = false;
  return PickedAttachment(
    name: file.name,
    openStream: () {
      if (opened) {
        return Stream<List<int>>.error(
          StateError('picker stream already consumed'),
        );
      }
      opened = true;
      return file.readAsByteStream();
    },
  );
}
