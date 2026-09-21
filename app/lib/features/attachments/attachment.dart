import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../models/message.dart';

final artifactIdPattern = RegExp(r'^[0-9a-f]{32}$');
const attachmentMaxBytes = 500 * 1024 * 1024; // Client attachment limit aligned with the compatibility plugin (500 MiB).
String safeFilename(String name) => name
    .split(RegExp(r'[/\\]'))
    .last
    .replaceAll(RegExp(r'[\r\n\[\]\x00-\x1f]'), '_');

/// Platform-neutral handle on staged attachment bytes: a file on dart:io
/// devices, an in-memory blob in the browser. Re-readable by design —
/// upload and hash verification each open their own pass.
abstract class AttachmentSource {
  Stream<List<int>> open();
  Future<int> get size;
}

/// Source built from a re-openable stream factory; size may be known upfront.
class StreamAttachmentSource implements AttachmentSource {
  StreamAttachmentSource(this.factory, [this.knownSize]);
  final Stream<List<int>> Function() factory;
  final int? knownSize;
  @override
  Stream<List<int>> open() => factory();
  @override
  Future<int> get size async =>
      knownSize ?? await factory().fold<int>(0, (a, c) => a + c.length);
}
String attachmentMime(String name) =>
    const {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'pdf': 'application/pdf',
      'json': 'application/json',
      'txt': 'text/plain',
      'md': 'text/plain',
      'zip': 'application/zip',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    }[name.split('.').last.toLowerCase()] ??
    'application/octet-stream';

class AttachmentDraft {
  const AttachmentDraft({
    required this.localPath,
    required this.filename,
    this.artifactId,
    this.expiresAt,
  });
  final String localPath, filename;
  final String? artifactId;
  final double? expiresAt;
  bool get uploaded => artifactId != null;
  bool get expired =>
      expiresAt != null &&
      expiresAt! <= DateTime.now().millisecondsSinceEpoch / 1000;
  Json toJson() => {
    'path': localPath,
    'filename': filename,
    'artifact_id': artifactId,
    'expires_at': expiresAt,
  };
  factory AttachmentDraft.fromJson(Json json) => AttachmentDraft(
    localPath: json['path'] as String,
    filename: json['filename'] as String,
    artifactId: json['artifact_id'] as String?,
    expiresAt: (json['expires_at'] as num?)?.toDouble(),
  );
  AttachmentDraft withReceipt(Json receipt) {
    final id = receipt['artifact_id'];
    if (id is! String || !artifactIdPattern.hasMatch(id)) {
      throw const AppFormatException(
        UiMessage.local(MessageKey.attachmentM001),
      );
    }
    return AttachmentDraft(
      localPath: localPath,
      filename: filename,
      artifactId: id,
      expiresAt: (receipt['expires_at'] as num?)?.toDouble(),
    );
  }
}

String composeAttachmentInput(String text, List<AttachmentDraft> attachments) {
  if (attachments.any(
    (a) => a.artifactId == null || !artifactIdPattern.hasMatch(a.artifactId!),
  )) {
    throw const AppFormatException(
      UiMessage.local(MessageKey.attachmentM002),
    );
  }
  return [
    if (text.trim().isNotEmpty) text.trim(),
    ...attachments.map(
      // i18n-exempt: protocol literal (identical in both locales) — see I18N-PLAN §5.
      (a) => '[附件: ${a.artifactId} ${safeFilename(a.filename)}]',
    ),
  ].join('\n');
}
