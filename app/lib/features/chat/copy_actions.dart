import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/localized_text.dart';
import '../../l10n/message_key.dart';
import '../../l10n/ui_message.dart';

/// Copy affordances shared by every rendered message: whole text, individual
/// blocks (paragraph split), and any links found inside.
List<String> extractLinks(String text) => RegExp(
      r'''https?://[^\s)（）"'<>]+''',
    ).allMatches(text).map((m) => m.group(0)!).toList();

/// Paragraph blocks for the per-block copy list; blank-line separated like
/// the markdown source.
List<String> copyBlocks(String text) => text
    .split(RegExp(r'\n\s*\n'))
    .map((b) => b.trim())
    .where((b) => b.isNotEmpty)
    .toList();

Future<void> _copy(
  BuildContext context,
  String value,
  UiMessage label,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // The 'Copied …' feedback localizes; the clipboard bytes never do.
        content: LocalizedText(
          UiMessage.local(MessageKey.copyM001, args: {'label': label}),
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}

Future<void> showCopySheet(BuildContext context, String text) async {
  final links = extractLinks(text);
  final blocks = copyBlocks(text);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Everything resolves inside the sheet builder: an open sheet follows a
    // language switch (§4.5).
    builder: (sheetContext) {
      final strings = AppStrings.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.copy_all),
                title: Text(strings.resolve(MessageKey.copyM002)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _copy(
                    context,
                    text,
                    const UiMessage.local(MessageKey.copyM003),
                  );
                },
              ),
              if (blocks.length > 1) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    strings.resolve(MessageKey.copyM004),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                for (var i = 0; i < blocks.length; i++)
                  ListTile(
                    dense: true,
                    leading: Text('${i + 1}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    title: Text(
                      blocks[i].replaceAll('\n', ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _copy(
                        context,
                        blocks[i],
                        UiMessage.local(
                          MessageKey.copyM005,
                          args: {'n': i + 1},
                        ),
                      );
                    },
                  ),
              ],
              if (links.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    strings.resolve(MessageKey.copyM006),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                for (final link in links)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.link, size: 18),
                    title: Text(link,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _copy(
                        context,
                        link,
                        const UiMessage.local(MessageKey.copyM007),
                      );
                    },
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    strings.resolve(MessageKey.copyM008),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Small trailing icon that opens the copy sheet for [text].
class CopyMenuButton extends StatelessWidget {
  const CopyMenuButton({super.key, required this.text, this.size = 16});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppStrings.of(context).resolve(MessageKey.copyM009),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        icon: Icon(Icons.copy_all_outlined, size: size),
        onPressed: text.trim().isEmpty
            ? null
            : () => showCopySheet(context, text),
      );
}
