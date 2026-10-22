import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// One replaceable anchor correction, awakened by scroll end rather than a
/// polling frame chain. A prolonged gesture never forces a jump underneath it.
class ScrollIdleGate {
  ValueListenable<bool>? _scrolling;
  VoidCallback? _listener;
  int _generation = 0;

  void cancel() {
    _generation++;
    if (_listener != null) _scrolling?.removeListener(_listener!);
    _scrolling = null;
    _listener = null;
  }

  void run(ValueListenable<bool> scrolling, VoidCallback action) {
    cancel();
    final generation = _generation;
    void resume() {
      if (scrolling.value) return;
      if (_listener != null) scrolling.removeListener(_listener!);
      _listener = null;
      _scrolling = null;
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        if (generation == _generation) action();
      });
    }

    _scrolling = scrolling;
    _listener = resume;
    scrolling.addListener(resume);
    resume();
  }
}
