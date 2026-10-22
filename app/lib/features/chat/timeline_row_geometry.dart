import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Observes descendant layout, including changes that never rebuild the row.
/// A moving reader keeps the last published extent until scrolling ends.
class TimelineRowGeometry extends SingleChildRenderObjectWidget {
  const TimelineRowGeometry({
    super.key,
    required this.scrolling,
    required this.onExtent,
    required super.child,
  });

  final ValueListenable<bool>? scrolling;
  final ValueChanged<double> onExtent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RowGeometry(scrolling, onExtent);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RowGeometry)
      ..scrolling = scrolling
      ..onExtent = onExtent;
  }
}

class _RowGeometry extends RenderProxyBox {
  _RowGeometry(this._scrolling, this.onExtent);

  ValueListenable<bool>? _scrolling;
  ValueChanged<double> onExtent;
  double? _published;
  bool _pending = false;

  set scrolling(ValueListenable<bool>? value) {
    if (identical(value, _scrolling)) return;
    if (attached) _scrolling?.removeListener(_scrollChanged);
    _scrolling = value;
    if (attached) _scrolling?.addListener(_scrollChanged);
    markNeedsLayout();
  }

  void _scrollChanged() {
    if (_scrolling?.value != true) markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scrolling?.addListener(_scrollChanged);
  }

  @override
  void detach() {
    _scrolling?.removeListener(_scrollChanged);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_scrolling?.value == true && _published != null) {
      size = constraints.constrain(Size(size.width, _published!));
    }
    if (_published == size.height) return;
    _published = size.height;
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (attached) onExtent(size.height);
    });
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Deferred content may grow past the stable row while a drag is active.
    context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => super.paint(context, offset),
    );
  }
}
