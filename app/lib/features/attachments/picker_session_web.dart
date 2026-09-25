import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../api/hermes_repository.dart' show ApiException;
import '../../l10n/message_key.dart';
import 'attachment.dart' show attachmentMaxBytes;
import 'picker_session.dart';
import 'picker_session_state.dart';

/// Browser file-selection session (IOS-PICKER-PLAN B2). Terminal decisions
/// live in PickerSessionCore; this driver only owns the DOM: a FRESH
/// `<input type=file>` per pick, created, wired and clicked from the
/// user-tap synchronous call stack (no await before click → the activation
/// survives iOS Safari), kept attached until terminal/abort, and removed
/// exactly once with the SAME listener objects it added.
///
/// Window focus is forwarded as a wake-up hint only — it can never cancel
/// or complete the session (the focus+500ms race of file_picker_web 3.1.0
/// is what this replaces). No UA sniffing: one rule for every browser.
PickerSession createPickerSession() => _WebPickerSession();

const _chunkBytes = 1 << 20; // Blob.slice reads, max 1 MiB per chunk.

class _WebPickerSession implements PickerSession {
  _WebPickerSession() {
    _core = PickerSessionCore(emit: _out.complete, releaseDriver: _release);
    try {
      final host = web.document.createElement('div') as web.HTMLDivElement;
      // Screen-reader invisible, zero layout, never over the CanvasKit
      // surface; the input itself is display:none (same click-safe trick
      // the plugin used, but never detached after click).
      host.style.cssText =
          'position:fixed;left:0;top:0;width:0;height:0;'
          'overflow:hidden;';
      host.setAttribute('aria-hidden', 'true');
      final input = web.HTMLInputElement()
        ..type = 'file'
        ..multiple = true
        ..accept =
            '' // FileType.any equivalent
        ..style.display = 'none';
      _changeL = ((web.Event _) {
        try {
          _onChanged();
        } catch (e) {
          _core.fault(e);
        }
      }).toJS;
      _cancelL = ((web.Event _) {
        try {
          _core.cancel();
        } catch (e) {
          _core.fault(e);
        }
      }).toJS;
      _focusL = ((web.Event _) => _core.focus()).toJS;
      input.addEventListener('change', _changeL);
      input.addEventListener('cancel', _cancelL);
      web.window.addEventListener('focus', _focusL);
      _input = input;
      _host = host;
      host.append(input);
      web.document.body!.append(host);
      input.click(); // last DOM step of the synchronous start stack
    } catch (e) {
      _core.fault(e); // DOM/click throw: settle failed, cleanup runs once.
    }
  }

  final Completer<PickerOutcome> _out = Completer<PickerOutcome>();
  late final PickerSessionCore _core;
  web.HTMLInputElement? _input;
  web.HTMLDivElement? _host;
  web.EventListener? _changeL;
  web.EventListener? _cancelL;
  web.EventListener? _focusL;
  bool _released = false;

  @override
  Future<PickerOutcome> get outcome => _out.future;

  @override
  void abort() => _core.abandon();

  @override
  set onFocusHint(void Function()? hint) => _core.focusHint = hint;

  /// `change`: copy every File handle synchronously BEFORE cleanup — a
  /// copied File survives its input's removal. Null/empty FileList is an
  /// anomalous empty, not a cancel (PLAN B2).
  void _onChanged() {
    final input = _input;
    if (input == null) return; // terminal already; listeners are gone anyway.
    final files = input.files;
    if (files == null || files.length == 0) {
      _core.emptyChange();
      return;
    }
    final items = <PickedAttachment>[];
    for (var i = 0; i < files.length; i++) {
      final f = files.item(i);
      if (f != null) items.add(_toPicked(f));
    }
    if (items.isEmpty) {
      _core.emptyChange();
      return;
    }
    _core.files(items);
  }

  /// Idempotent cleanup: removes EXACTLY the listener objects added above,
  /// then this session's own container — never another session's nodes.
  void _release() {
    if (_released) return;
    _released = true;
    final input = _input;
    final host = _host;
    final changeL = _changeL;
    final cancelL = _cancelL;
    final focusL = _focusL;
    _input = null;
    _host = null;
    _changeL = null;
    _cancelL = null;
    _focusL = null;
    try {
      if (input != null) {
        if (changeL != null) input.removeEventListener('change', changeL);
        if (cancelL != null) input.removeEventListener('cancel', cancelL);
      }
      if (focusL != null) web.window.removeEventListener('focus', focusL);
      host?.remove();
    } catch (_) {
      // Page already torn down; references are dropped regardless.
    }
  }
}

PickedAttachment _toPicked(web.File file) {
  final total = file.size.round();
  var consumed = false;
  return PickedAttachment(
    name: file.name,
    knownSize: total,
    openStream: () {
      if (consumed) {
        return Stream<List<int>>.error(
          StateError('picker stream already consumed'),
        );
      }
      consumed = true;
      if (total > attachmentMaxBytes) {
        // Known-size gate BEFORE reading (PLAN B2); the controller's
        // stream-count cap still guards the read path.
        return Stream<List<int>>.error(
          const ApiException.local(MessageKey.attachmentTooLarge),
        );
      }
      late StreamController<List<int>> ctrl;
      var cancelled = false;
      Future<void> pump(int offset) async {
        if (cancelled || ctrl.isClosed) return;
        try {
          if (offset >= total) {
            await ctrl.close();
            return;
          }
          final end = math.min(offset + _chunkBytes, total);
          final buf =
              (await file.slice(offset, end).arrayBuffer().toDart).toDart;
          if (cancelled || ctrl.isClosed) return;
          final bytes = Uint8List.view(buf);
          if (bytes.isEmpty) {
            await ctrl.close(); // never spin on a stalled slice
            return;
          }
          ctrl.add(bytes);
          await pump(offset + bytes.length);
        } catch (e, st) {
          if (!cancelled && !ctrl.isClosed) {
            ctrl.addError(e, st);
            await ctrl.close();
          }
        }
      }

      ctrl = StreamController<List<int>>(onCancel: () => cancelled = true);
      unawaited(pump(0)); // zero-byte files close immediately: valid pick
      return ctrl.stream;
    },
  );
}
