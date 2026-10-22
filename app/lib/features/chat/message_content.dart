import 'dart:collection';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'image_viewer.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'linkify.dart';
import 'copy_actions.dart';
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

final RegExp _serverImagePath = RegExp(
  r'\.(png|jpe?g|gif|webp|bmp)$',
  caseSensitive: false,
);

/// OPENPERF P3: inline view of a history MEDIA reference — pixels ride
/// GET /v1/media/download, fetched once when the row enters the viewport.
/// IMGPERF A1: the download Future lives on the State, keyed by
/// (repository instance, path) identity — a rebuild never re-fetches, only a
/// new path or a new repository (profile/account switch) starts a new
/// download; swapping the Future also fences late results of a retired
/// identity out of the newer image. A failure keeps the actionable
/// AttachmentTile so an explicit retry can refetch.
class ServerPathImage extends ConsumerStatefulWidget {
  const ServerPathImage(this.path, {super.key, this.filename});
  final String path;
  final String? filename;

  @override
  ConsumerState<ServerPathImage> createState() => _ServerPathImageState();
}

class _ServerPathImageState extends ConsumerState<ServerPathImage> {
  HermesRepository? _repo;
  String? _path;
  Future<Uint8List>? _future;

  void _track(HermesRepository repo) {
    if (_future != null && identical(_repo, repo) && _path == widget.path) {
      return;
    }
    _repo = repo;
    _path = widget.path;
    // IMGVIEW-DEDUP: artifact ids already dedupe through cachedArtifact;
    // plain server paths went straight to the wire, so a state rebuild
    // (list virtualization) re-fired the download on every pass — a wedged
    // path (file gone) turned each rebuild wave into a request storm. Same
    // in-flight memory: concurrent identities share one GET, late rebuilds
    // never stampede.
    _future = artifactIdPattern.hasMatch(widget.path)
        ? cachedArtifact(repo, widget.path)
        : cachedServerFile(repo, widget.path);
  }

  @override
  void initState() {
    super.initState();
    _track(ref.read(repositoryProvider));
  }

  @override
  void didUpdateWidget(ServerPathImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _track(ref.read(repositoryProvider));
  }

  @override
  Widget build(BuildContext context) {
    _track(ref.read(repositoryProvider));
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final repo = _repo!;
          final path = widget.path;
          return AttachmentTile(
            path,
            filename: widget.filename,
            onDownloaded: (bytes) {
              if (!mounted || !identical(_repo, repo) || _path != path) return;
              _serverFileCooldown[repo]?.remove(path);
              setState(() {
                _future = Future.value(bytes);
              });
            },
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return MessageImageMemory(
          snapshot.data!,
          source: widget.path,
          filename: widget.filename,
        );
      },
    );
  }
}

/// Reuse downloaded pixels when opening the full-screen viewer.
class MessageImageMemory extends StatelessWidget {
  const MessageImageMemory(
    this.bytes, {
    super.key,
    this.source = '',
    this.filename,
  });
  final Uint8List bytes;
  final String source;
  final String? filename;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: GestureDetector(
      onTap: () => openImageViewer(
        context,
        source,
        ViewerImage(
          safeFilename(filename ?? source.split('/').last),
          () async => bytes,
        ),
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (c, e, s) =>
            LocalizedText(UiMessage.local(MessageKey.contentM005)),
      ),
    ),
  );
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
  if (!supported) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: LocalizedText(UiMessage.local(MessageKey.contentM001)),
        ),
      );
    }
    return;
  }
  // LINK-EXIT (2026-10-22): on Android this app's own verified App Links
  // domain resolves ACTION_VIEW back to THIS activity — url_launcher's
  // externalApplication mode cannot dodge that resolution, so ask the
  // native channel to pin an external browser package. Non-Android (web)
  // and any native failure fall through to url_launcher unchanged.
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final opened = await const MethodChannel('hermes/browser').invokeMethod<bool>(
        'openExternally',
        {'url': value},
      );
      if (opened == true) return;
    } catch (_) {
      // pre-channel builds / non-Flutter-host contexts: url_launcher below.
    }
  }
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
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

class MessageContent extends ConsumerStatefulWidget {
  const MessageContent(this.text, {super.key});
  final String text;
  @override
  ConsumerState<MessageContent> createState() => _MessageContentState();
}

class _MessageContentState extends ConsumerState<MessageContent> {
  String? _text;
  HermesRepository? _repository;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final text = widget.text;
    if (_cached != null && _text == text && identical(_repository, repo)) {
      return _cached!;
    }
    _text = text;
    _repository = repo;
    return _cached = _buildContent(context, repo, text);
  }

  Widget _buildContent(
    BuildContext context,
    HermesRepository repo,
    String text,
  ) {
    final parts = splitMessageContent(text);
    final sources = <String>[];
    final filenames = <String, String>{};
    for (final part in parts) {
      if (part.media &&
          (isImageReference(part.value) ||
              _serverImagePath.hasMatch(part.value) ||
              (artifactIdPattern.hasMatch(part.value) &&
                  _serverImagePath.hasMatch(part.filename ?? '')))) {
        sources.add(part.value);
        if (part.filename != null) {
          filenames[part.value] = safeFilename(part.filename!);
        }
      } else if (!part.media) {
        if (part.value.trim().startsWith('data:image/')) {
          sources.add(part.value.trim());
        }
        for (final match in RegExp(
          r'!\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)',
        ).allMatches(part.value)) {
          sources.add(match.group(1)!);
        }
      }
    }
    return MessageGallery(
      images: {
        for (final source in sources)
          source: ViewerImage(
            filenames[source] ?? _imageName(source),
            () => _loadImage(repo, source),
          ),
      },
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: parts.map((part) {
            if (part.media) {
              if (isImageReference(part.value)) return MessageImage(part.value);
              // OPENPERF P3 (定案2): history ships MEDIA REFERENCES. An image
              // reference renders inline through the download endpoint (one
              // file per view — never 13 MB of JSON on the list GET); a miss
              // (old gateway 404, deleted file) degrades to the download tile.
              if ((looksLikeServerPath(part.value) &&
                      _serverImagePath.hasMatch(part.value)) ||
                  (artifactIdPattern.hasMatch(part.value) &&
                      _serverImagePath.hasMatch(part.filename ?? ''))) {
                return ServerPathImage(part.value, filename: part.filename);
              }
              return AttachmentTile(part.value, filename: part.filename);
            }
            final value = part.value.trim();
            if (value.isEmpty) return const SizedBox.shrink();
            if (value.startsWith('data:image/') &&
                !value.contains(RegExp(r'\s'))) {
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
                          onPressed: () => copyWithFeedback(
                            context,
                            code,
                            const UiMessage.local(MessageKey.contentM002),
                          ),
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
      ),
    );
  }
}

String _imageName(String source) {
  try {
    if (source.startsWith('data:')) {
      final type = UriData.parse(
        source,
      ).mimeType.split('/').last.split('+').first;
      return safeFilename('hermes-image.$type');
    }
    return safeFilename(
      Uri.tryParse(source)?.pathSegments.lastOrNull ?? 'hermes-image.png',
    );
  } catch (_) {
    return 'hermes-image.png';
  }
}

Future<Uint8List> _loadImage(HermesRepository repo, String source) async {
  if (source.startsWith('data:image/')) {
    if (source.length > 32 * 1024 * 1024) throw const FormatException();
    final decoded = _decodeDataUrl(source);
    if (decoded == null) throw const FormatException();
    return decoded.bytes;
  }
  if (artifactIdPattern.hasMatch(source)) return cachedArtifact(repo, source);
  final uri = Uri.parse(source);
  final base = Uri.parse(repo.baseUrl);
  final own = !uri.hasScheme || uri.origin == base.origin;
  final artifact = RegExp(
    r'^/v1/artifacts/download/([0-9a-f]{32})$',
  ).firstMatch(uri.path);
  if (own && artifact != null) {
    return repo.downloadAttachment(artifact.group(1)!);
  }
  if (own &&
      uri.path == '/v1/media/download' &&
      uri.queryParameters['path'] != null) {
    return repo.downloadServerFile(uri.queryParameters['path']!);
  }
  if (!uri.hasScheme && looksLikeServerPath(source)) {
    return repo.downloadServerFile(source);
  }
  if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
    throw const FormatException();
  }
  final client = http.Client();
  try {
    final request = http.Request('GET', uri)..followRedirects = false;
    if (own) request.headers['Authorization'] = 'Bearer ${repo.key}';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw const FormatException();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > attachmentMaxBytes) {
        throw const FormatException();
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close();
  }
}

// IMGPERF A2: an inline data URL's base64→bytes conversion is pure CPU on the
// build isolate (debug ~14ms/1MiB). Memoize it by source string so one source
// decodes once no matter how many rebuilds touch it. The cache is bounded both
// by entry count and by decoded bytes, LRU on touch; failures are not cached
// (a source that throws is deterministic, but not caching keeps the map of
// huge malformed strings from pinning memory).
@visibleForTesting
int get dataUrlDecodeCount => _dataUrlDecodes;

@visibleForTesting
void resetDataUrlCache() {
  _dataUrlCache.clear();
  _dataUrlCacheBytes = 0;
  _dataUrlDecodes = 0;
}

@visibleForTesting
int debugDataUrlCacheSize() => _dataUrlCache.length;

const int _dataUrlCacheMaxEntries = 32;
const int _dataUrlCacheMaxBytes = 32 << 20;
final LinkedHashMap<String, ({Uint8List bytes, String mimeType})>
_dataUrlCache = LinkedHashMap();
int _dataUrlCacheBytes = 0;
int _dataUrlDecodes = 0;

({Uint8List bytes, String mimeType})? _decodeDataUrl(String source) {
  final hit = _dataUrlCache.remove(source);
  if (hit != null) {
    _dataUrlCache[source] = hit;
    return hit;
  }
  try {
    final data = UriData.parse(source);
    final bytes = data.contentAsBytes();
    _dataUrlDecodes++;
    final entry = (bytes: bytes, mimeType: data.mimeType);
    _dataUrlCache[source] = entry;
    _dataUrlCacheBytes += bytes.length;
    while (_dataUrlCache.length > _dataUrlCacheMaxEntries ||
        _dataUrlCacheBytes > _dataUrlCacheMaxBytes) {
      _dataUrlCacheBytes -= _dataUrlCache
          .remove(_dataUrlCache.keys.first)!
          .bytes
          .length;
    }
    return entry;
  } catch (_) {
    return null;
  }
}

class MessageImage extends ConsumerStatefulWidget {
  const MessageImage(this.source, {super.key});
  final String source;
  @override
  ConsumerState<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends ConsumerState<MessageImage> {
  Future<Uint8List>? _remote;
  String? _remoteSource;
  HermesRepository? _remoteRepo;
  bool _saving = false;
  UiMessage? _notice;

  bool get _isDataUrl => widget.source.startsWith('data:image/');

  ({Uint8List bytes, String name})? _decode() {
    final decoded = _decodeDataUrl(widget.source);
    if (decoded == null) return null;
    final slash = decoded.mimeType.indexOf('/');
    final subtype = (slash >= 0 ? decoded.mimeType.substring(slash + 1) : 'png')
        .split(RegExp(r'[+.]'))
        .first;
    return (bytes: decoded.bytes, name: 'hermes-image.$subtype');
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
        setState(
          () => _notice = switch (saved) {
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
          },
        );
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
    Widget local(MessageKey key) => LocalizedText(UiMessage.local(key));
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
          (!['http', 'https'].contains(uri.scheme) && uri.scheme.isNotEmpty) ||
          uri.userInfo.isNotEmpty) {
        return local(MessageKey.contentM008);
      }
      final repo = ref.read(repositoryProvider);
      if (_remote == null ||
          _remoteSource != widget.source ||
          !identical(_remoteRepo, repo)) {
        _remoteSource = widget.source;
        _remoteRepo = repo;
        _remote = _loadImage(repo, widget.source);
      }
      return FutureBuilder<Uint8List>(
        future: _remote,
        builder: (context, snapshot) {
          if (snapshot.hasError) return local(MessageKey.contentM005);
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            errorBuilder: failure,
          );
        },
      );
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
            onTap: () => openImageViewer(
              context,
              widget.source,
              ViewerImage(
                _imageName(widget.source),
                () =>
                    _remote ??
                    _loadImage(ref.read(repositoryProvider), widget.source),
              ),
            ),
            child: SizedBox(
              width: (MediaQuery.sizeOf(context).width - 80).clamp(
                100.0,
                480.0,
              ),
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
                icon: Icon(
                  Icons.download_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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

/// IMGVIEW-DEDUP: in-flight + short failure-cooldown dedupe for
/// /v1/media/download fetches. In-flight state hangs on the repository
/// INSTANCE (Expando), so an identity swap always re-fetches (IMGPERF A1
/// contract) while rebuilds of one identity share a single GET. A path that
/// just failed cools down for 30s per repository identity instead of re-firing on every
/// list rebuild — vanished files were a request storm.
final Expando<Map<String, Future<Uint8List>>> _serverInflight = Expando(
  'serverFileInflight',
);
final Expando<Map<String, DateTime>> _serverFileCooldown = Expando(
  'serverFileCooldown',
);

Future<Uint8List> cachedServerFile(HermesRepository repo, String path) {
  final cooldown = _serverFileCooldown[repo] ??= <String, DateTime>{};
  final failedAt = cooldown[path];
  if (failedAt != null &&
      DateTime.now().difference(failedAt) < const Duration(seconds: 30)) {
    return Future.error(StateError('recent download failure: $path'));
  }
  var slot = _serverInflight[repo];
  if (slot == null) {
    slot = <String, Future<Uint8List>>{};
    _serverInflight[repo] = slot;
  }
  final inflight = slot;
  final existing = inflight[path];
  if (existing != null) return existing;
  final future = () async {
    try {
      final bytes = await repo.downloadServerFile(path);
      cooldown.remove(path);
      return bytes;
    } catch (_) {
      cooldown[path] = DateTime.now();
      rethrow;
    } finally {
      inflight.remove(path);
    }
  }();
  inflight[path] = future;
  return future;
}

class AttachmentTile extends ConsumerStatefulWidget {
  const AttachmentTile(
    this.reference, {
    super.key,
    this.filename,
    this.onDownloaded,
  });
  final String reference;
  final String? filename;
  final ValueChanged<Uint8List>? onDownloaded;
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
      subtitle: notice != null
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
              tooltip: id != null || serverFile
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
                    var copied = false;
                    try {
                      await Clipboard.setData(ClipboardData(text: reference));
                      copied = true;
                    } on Object {
                      // Keep the attachment tile available for another try.
                    }
                    if (mounted) {
                      setState(
                        () => notice = UiMessage.local(
                          copied
                              ? MessageKey.contentM019
                              : MessageKey.copyFailed,
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
                    widget.onDownloaded?.call(bytes);
                    final saved = await saveBytesAs(name, bytes);
                    if (mounted) {
                      setState(
                        () => notice = !saved.succeeded
                            ? const UiMessage.local(MessageKey.contentM020)
                            : const UiMessage.local(MessageKey.contentM021),
                      );
                    }
                  } on ApiException catch (e) {
                    if (!mounted) return;
                    if (e.status == 404) {
                      var copied = false;
                      try {
                        await Clipboard.setData(ClipboardData(text: reference));
                        copied = true;
                      } on Object {
                        // The fallback path must not report a false copy.
                      }
                      if (!mounted) return;
                      setState(
                        () => notice = UiMessage.local(
                          copied
                              ? MessageKey.contentM022
                              : MessageKey.copyFailed,
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
                      () => notice = !saved.succeeded
                          ? const UiMessage.local(MessageKey.contentM024)
                          : const UiMessage.local(MessageKey.contentM021),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    setState(
                      () => notice = e is UiCarriesMessage
                          ? e.uiMessage
                          : const UiMessage.local(MessageKey.contentM025),
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
