import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copy affordances shared by every rendered message: whole text, individual
/// blocks (paragraph split), and any links found inside.
List<String> extractLinks(String text) => RegExp(
      r'''https?://[^\s)（）"'<>]+''',
    ).allMatches(text).map((m) => m.group(0)!).toList();

/// Paragraph blocks for 分段複製; blank-line separated like the markdown source.
List<String> copyBlocks(String text) => text
    .split(RegExp(r'\n\s*\n'))
    .map((b) => b.trim())
    .where((b) => b.isNotEmpty)
    .toList();

Future<void> _copy(BuildContext context, String value, String label) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已複製$label'), duration: const Duration(seconds: 1)),
    );
  }
}

Future<void> showCopySheet(BuildContext context, String text) async {
  final links = extractLinks(text);
  final blocks = copyBlocks(text);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all),
              title: const Text('整段複製'),
              onTap: () {
                Navigator.pop(sheetContext);
                _copy(context, text, '整段訊息');
              },
            ),
            if (blocks.length > 1) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('分段複製', style: TextStyle(fontSize: 12)),
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
                    _copy(context, blocks[i], '第 ${i + 1} 段');
                  },
                ),
            ],
            if (links.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('複製連結', style: TextStyle(fontSize: 12)),
              ),
              for (final link in links)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 18),
                  title: Text(link,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _copy(context, link, '連結');
                  },
                ),
            ] else
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('此訊息沒有連結', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Small trailing icon that opens the copy sheet for [text].
class CopyMenuButton extends StatelessWidget {
  const CopyMenuButton({super.key, required this.text, this.size = 16});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '複製',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        icon: Icon(Icons.copy_all_outlined, size: size),
        onPressed: text.trim().isEmpty
            ? null
            : () => showCopySheet(context, text),
      );
}
