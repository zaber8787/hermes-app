import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'save_file.dart';

Future<String?> saveBytesAs(String name, Uint8List bytes) async {
  final saved = await FilePicker.saveFile(fileName: name, bytes: bytes);
  return saved?.toString();
}

class IoByteCache implements ByteCache {
  @override
  Future<Uint8List> getOrCreate(
    String key,
    Future<Uint8List> Function() load, {
    Object? root,
  }) async {
    final base = root as Directory? ?? await getApplicationSupportDirectory();
    final file = File('${base.path}/artifact-downloads/$key');
    if (await file.exists()) return await file.readAsBytes();
    final bytes = await load();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    return bytes;
  }
}

ByteCache newCache() => IoByteCache();
