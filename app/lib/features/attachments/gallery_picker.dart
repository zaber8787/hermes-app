import 'package:flutter/widgets.dart';

import 'draft_store.dart';
import 'gallery_picker_io.dart'
    if (dart.library.js_interop) 'gallery_picker_web.dart' as impl;

/// The browser has no photo library to browse, so `onPickOther` is how the
/// web build (and the sheet's "其他檔案" button) escapes to the file picker.
Future<PickedMedia?> pickFromGallery(
  BuildContext context, {
  void Function()? onPickOther,
}) => impl.pickFromGallery(context, onPickOther: onPickOther);
