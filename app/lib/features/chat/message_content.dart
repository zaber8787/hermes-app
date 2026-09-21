import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'linkify.dart';
import '../../api/hermes_repository.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';
import '../../platform/save_file.dart';
import '../../providers.dart';
import '../attachments/attachment.dart';

String formatMessageTimestamp(double seconds, {DateTime? now}) {
  if (!seconds.isFinite || seconds <= 0 || seconds > 8640000000000) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
  ).toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final time =
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  return date.year == today.year &&
          date.month == today.month &&
          date.day == today.day
      ? time
      : '${date.month}/${date.day} $time';
}

class MessageTime extends StatelessWidget {
  const MessageTime(this.seconds, {super.key});
  final double seconds;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      formatMessageTimestamp(seconds),
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Absolute server paths from MEDIA: tags — downloadable via /v1/media/download
/// once the gateway serves that route (older gateways 404 and we fall back).
bool looksLikeServerPath(String value) =>
    value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

bool isImageReference(String source) {
  if (source.startsWith('data:image/')) return true;
  final uri = Uri.tryParse(source);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      RegExp(
        r'\.(png|jpe?g|gif|webp|bmp)$',
        caseSensitive: false,
      ).hasMatch(uri.path);
}

class ContentPart {
  const ContentPart(this.value, {this.media = false, this.filename});
  final String value;
  final bool media;
  final String? filename;
}

List<ContentPart> splitMessageContent(String text) {
  final pattern = RegExp(
    r'''MEDIA:(?:"([^"]+)"|'([^']+)'|([^\s<>]+))|\[附件:\s*([0-9a-f]{32})\s+([^\]\n]+)\]''', // i18n-exempt: inbound attachment/media syntax — I18N-PLAN §5
  );
  final parts = <ContentPart>[];
  var offset = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > offset) {
      parts.add(ContentPart(text.substring(offset, match.start)));
    }
    parts.add(
      ContentPart(
        match.group(4) ?? match.group(1) ?? match.group(2) ?? match.group(3)!,
        media: true,
        filename: match.group(5),
      ),
    );
    offset = match.end;
  }
  if (offset < text.length) parts.add(ContentPart(text.substring(offset)));
  return parts;
}

Future<void> openMessageLink(BuildContext context, String value) async {
  final uri = Uri.tryParse(value);
  final supported =
      uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.userInfo.isEmpty;
  try {
    if (!supported ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText(UiMessage.local(MessageKey.contentM001)),
          ),
        );
      }
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: LocalizedText(UiMessage.local(MessageKey.contentM001)),
        ),
      );
    }
  }
}

class MessageContent extends StatelessWidget {
  const MessageContent(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => SelectionArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: splitMessageContent(text).map((part) {
      if (part.media) {
        if (isImageReference(part.value)) return MessageImage(part.value);
        return AttachmentTile(part.value, filename: part.filename);
      }
      final value = part.value.trim();
      if (value.isEmpty) return const SizedBox.shrink();
      if (value.startsWith('data:image/') && !value.contains(RegExp(r'\s'))) {
        return MessageImage(value);
      }
      return GptMarkdown(
        linkifyBareUrls(value),
        onLinkTap: (url, _) => openMessageLink(context, url),
        imageBuilder: (context, url, width, height) => MessageImage(url),
        codeBuilder: (context, language, code, closed) => Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(language)),
                  IconButton(
                    tooltip: AppStrings.of(
                      context,
                    ).resolve(MessageKey.contentM002),
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: code)),
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  code,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList(),
    ),
  );
}

class MessageImage extends ConsumerStatefulWidget {
  const MessageImage(this.source, {super.key});
  final String source;
  @override
  ConsumerState<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends ConsumerState<MessageImage> {
  bool _saving = false;
  UiMessage? _notice;

  bool get _isDataUrl => widget.source.startsWith('data:image/');

  ({Uint8List bytes, String name})? _decode() {
    try {
      final data = UriData.parse(widget.source);
      final slash = data.mimeType.indexOf('/');
      final subtype = (slash >= 0
              ? data.mimeType.substring(slash + 1)
              : 'png')
          .split(RegExp(r'[+.]'))
          .first;
      return (bytes: data.contentAsBytes(), name: 'hermes-image.$subtype');
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final decoded = _isDataUrl ? _decode() : null;
    Uint8List? bytes = decoded?.bytes;
    final name = decoded?.name ?? 'hermes-image.png';
    if (bytes == null && widget.source.startsWith('http')) return;
    if (bytes == null) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final saved = await saveBytesAs(name, bytes);
      if (mounted) {
        setState(() => _notice = switch (saved) {
          // Typed outcome (§4.4): the web path no longer renders a
          // pseudo-path string.
          SaveCancelled() => const UiMessage.local(
            MessageKey.downloadCancelled,
          ),
          SavedPath(:final path) => UiMessage.local(
            MessageKey.contentM003,
            args: {'saved': UiMessage.raw(path)},
          ),
          BrowserStarted() => const UiMessage.local(
            MessageKey.downloadBrowserStarted,
          ),
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _notice = const UiMessage.local(MessageKey.contentM004));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _image() {
    Widget local(MessageKey key) =>
        LocalizedText(UiMessage.local(key));
    Widget failure(BuildContext c, Object e, StackTrace? s) => Padding(
      padding: const EdgeInsets.all(16),
      child: local(MessageKey.contentM005),
    );
    try {
      if (_isDataUrl) {
        if (widget.source.length > 32 * 1024 * 1024) {
          return local(MessageKey.contentM006);
        }
        final decoded = _decode();
        if (decoded == null) return local(MessageKey.contentM007);
        return Image.memory(
          decoded.bytes,
          fit: BoxFit.contain,
          errorBuilder: failure,
        );
      }
      final uri = Uri.tryParse(widget.source);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.userInfo.isNotEmpty) {
        return local(MessageKey.contentM008);
      }
      return Image.network(widget.source,
          fit: BoxFit.contain, errorBuilder: failure);
    } catch (_) {
      return local(MessageKey.contentM007);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: strings.resolve(MessageKey.contentM009),
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  appBar: AppBar(
                    title: Text(
                      AppStrings.of(context).resolve(MessageKey.contentM010),
                    ),
                    actions: [
                      if (_isDataUrl)
                        IconButton(
                          tooltip: AppStrings.of(
                            context,
                          ).resolve(MessageKey.contentM011),
                          onPressed: _saving ? null : _save,
                          icon: Icon(_saving
                              ? Icons.hourglass_top
                              : Icons.download_outlined),
                        ),
                    ],
                  ),
                  body: Center(
                    child: InteractiveViewer(
                        maxScale: 5, child: _image()),
                  ),
                ),
              ),
            ),
            child: SizedBox(
              width:
                  (MediaQuery.sizeOf(context).width - 80).clamp(100.0, 480.0),
              height: 250,
              child: _image(),
            ),
          ),
        ),
        Row(
          children: [
            if (_isDataUrl)
              IconButton(
                tooltip: strings.resolve(MessageKey.contentM011),
                visualDensity: VisualDensity.compact,
                onPressed: _saving ? null : _save,
                icon: Icon(Icons.download_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            if (_notice != null)
              Expanded(
                child: LocalizedText(
                  _notice!,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

final _downloads = <String, Future<Uint8List>>{};
final _artifactCache = newByteCache();
Future<Uint8List> cachedArtifact(
  HermesRepository repo,
  String id, {
  Object? directory,
}) {
  final key = '${sha256.convert(utf8.encode(repo.baseUrl)).toString()}/$id';
  return _downloads.putIfAbsent(key, () async {
    try {
      return await _artifactCache.getOrCreate(
        key,
        () => repo.downloadAttachment(id),
        root: directory,
      );
    } finally {
      _downloads.remove(key);
    }
  });
}

class AttachmentTile extends ConsumerStatefulWidget {
  const AttachmentTile(this.reference, {super.key, this.filename});
  final String reference;
  final String? filename;
  @override
  ConsumerState<AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends ConsumerState<AttachmentTile> {
  bool busy = false;
  UiMessage? notice;
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final reference = widget.reference;
    final uri = Uri.tryParse(reference);
    final base = Uri.tryParse(ref.watch(settingsProvider).url);
    final directId = artifactIdPattern.hasMatch(reference) ? reference : null;
    final match = RegExp(
      r'^/v1/artifacts/download/([0-9a-f]{32})$',
    ).firstMatch(uri?.path ?? '');
    final id =
        directId ??
        (match != null &&
                (uri!.scheme.isEmpty ||
                    (['http', 'https'].contains(uri.scheme) &&
                        uri.origin == base?.origin))
            ? match.group(1)
            : null);
    final remote = uri != null && ['http', 'https'].contains(uri.scheme);
    final serverFile = id == null && !remote && looksLikeServerPath(reference);
    final name = safeFilename(
      widget.filename ??
          (uri?.pathSegments.isNotEmpty == true
              ? uri!.pathSegments.last
              : reference),
    );
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        id == null && !remote
            ? Icons.insert_drive_file_outlined
            : Icons.attach_file,
      ),
      title: Text(
        name.isEmpty ? strings.resolve(MessageKey.contentM012) : name,
      ),
      subtitle:
          notice != null
              ? LocalizedText(notice!)
              : Text(
                id != null
                    ? strings.resolve(MessageKey.contentM013)
                    : remote
                    ? strings.resolve(MessageKey.contentM014)
                    : serverFile
                    ? strings.resolve(MessageKey.contentM015)
                    : strings.resolve(MessageKey.contentM016),
              ),
      trailing: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(),
            )
          : IconButton(
              tooltip:
                  id != null || serverFile
                      ? strings.resolve(MessageKey.contentM013)
                      : remote
                      ? strings.resolve(MessageKey.contentM017)
                      : strings.resolve(MessageKey.contentM018),
              icon: Icon(
                id != null || serverFile
                    ? Icons.download
                    : remote
                    ? Icons.open_in_new
                    : Icons.copy,
              ),
              onPressed: () async {
                if (id == null) {
                  if (remote) {
                    await openMessageLink(context, reference);
                    return;
                  }
                  if (!serverFile) {
                    await Clipboard.setData(ClipboardData(text: reference));
                    if (mounted) {
                      setState(
                        () => notice = const UiMessage.local(
                          MessageKey.contentM019,
                        ),
                      );
                    }
                    return;
                  }
                  setState(() => busy = true);
                  try {
                    final bytes = await ref
                        .read(repositoryProvider)
                        .downloadServerFile(reference);
                    final saved = await saveBytesAs(name, bytes);
                    if (mounted) {
                      setState(
                        () => notice =
                            !saved.succeeded
                                ? const UiMessage.local(
                                  MessageKey.contentM020,
                                )
                                : const UiMessage.local(
                                  MessageKey.contentM021,
                                ),
                      );
                    }
                  } on ApiException catch (e) {
                    if (!mounted) return;
                    if (e.status == 404) {
                      await Clipboard.setData(ClipboardData(text: reference));
                      setState(
                        () => notice = const UiMessage.local(
                          MessageKey.contentM022,
                        ),
                      );
                    } else {
                      // Server-origin text stays RAW inside the descriptor.
                      setState(() => notice = e.uiMessage);
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(
                        () => notice = const UiMessage.local(
                          MessageKey.contentM023,
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                  return;
                }
                setState(() => busy = true);
                try {
                  final bytes = await cachedArtifact(
                    ref.read(repositoryProvider),
                    id,
                  );
                  final saved = await saveBytesAs(name, bytes);
                  if (mounted) {
                    setState(
                      () => notice =
                          !saved.succeeded
                              ? const UiMessage.local(
                                MessageKey.contentM024,
                              )
                              : const UiMessage.local(
                                MessageKey.contentM021,
                              ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    setState(
                      () => notice =
                          e is UiCarriesMessage
                              ? e.uiMessage
                              : const UiMessage.local(
                                MessageKey.contentM025,
                              ),
                    );
                  }
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
            ),
    );
  }
}
