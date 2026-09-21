import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../api/hermes_repository.dart';
import '../../l10n/message_key.dart';
import 'attachment.dart';
import 'draft_store.dart';
import 'media_picker_sheet.dart';

Future<PickedMedia?> pickFromGallery(
  BuildContext context, {
  void Function()? onPickOther,
}) async {
  final asset = await MediaPickerSheet.show(context, onPickOther: onPickOther);
  if (asset == null) return null;
  return pickedMediaFromAsset(asset);
}

/// Gallery selection as a platform-neutral picked item (io only).
Future<PickedMedia> pickedMediaFromAsset(AssetEntity asset) async {
  final file = await asset.file;
  if (file == null) {
    throw const ApiException.local(MessageKey.galleryM001);
  }
  final name = await asset.titleAsync;
  return PickedMedia(
    name.isEmpty ? file.uri.pathSegments.last : name,
    StreamAttachmentSource(() => file.openRead(), await file.length()),
  );
}
