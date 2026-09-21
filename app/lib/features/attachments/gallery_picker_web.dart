import 'package:flutter/widgets.dart';

import 'draft_store.dart';

/// The browser has no photo library: go straight to the file picker, which
/// covers images and documents alike (and keeps the sheet's io-only photo
/// grid code out of the web build).
Future<PickedMedia?> pickFromGallery(
  BuildContext context, {
  void Function()? onPickOther,
}) async {
  onPickOther?.call();
  return null;
}
