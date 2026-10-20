import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';

/// Empty API observations cannot establish that background workers are idle.
/// Refresh only reads activity; it never chooses or starts a run.
class RemoteActivityNotice extends StatefulWidget {
  const RemoteActivityNotice({
    super.key,
    required this.strings,
    required this.onRefresh,
  });

  final AppStrings strings;
  final Future<void> Function() onRefresh;

  @override
  State<RemoteActivityNotice> createState() => _RemoteActivityNoticeState();
}

class _RemoteActivityNoticeState extends State<RemoteActivityNotice> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ExpansionTile(
      key: const ValueKey('chat.remoteActivityHelp'),
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.chat_bubble_outline, size: 18),
      title: Text(
        widget.strings.resolve(MessageKey.steerActivityHelp),
        style: Theme.of(context).textTheme.labelMedium,
      ),
      children: [
        Text(widget.strings.resolve(MessageKey.steerActivityCoverage)),
        TextButton.icon(
          key: const ValueKey('chat.remoteActivityRefresh'),
          onPressed: _refreshing ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(widget.strings.resolve(MessageKey.steerActivityRefresh)),
        ),
      ],
    ),
  );
}
