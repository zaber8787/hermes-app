import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../l10n/message_key.dart';
import '../../l10n/localized_text.dart';
import 'approval_inbox.dart';
import 'message_timeline.dart';

/// APPROVALPUSH R6: session-level pending-approval cards, keyed by exact
/// request and rendered OUTSIDE the turn stream — a remote pending request
/// never invents a fake local turn or user row.
class PendingApprovalsPanel extends StatefulWidget {
  const PendingApprovalsPanel({
    super.key,
    required this.requests,
    required this.unconfirmedRuns,
    required this.onResolve,
    required this.onReconfirm,
    this.focusRequestId,
  });

  final List<ApprovalRequest> requests;
  final Set<String> unconfirmedRuns;
  final Future<void> Function(ApprovalRequest request, String choice)
  onResolve;
  final Future<void> Function(ApprovalRequest request) onReconfirm;

  /// 01412FIX F5: the deep link named this exact request — its card is the
  /// ONE highlighted card; an id that matches nothing highlights nothing.
  final String? focusRequestId;

  @override
  State<PendingApprovalsPanel> createState() => _PendingApprovalsPanelState();
}

class _PendingApprovalsPanelState extends State<PendingApprovalsPanel> {
  Timer? _retire;

  @override
  void initState() {
    super.initState();
    // Retirement of "handled elsewhere" receipts is time-based — the panel
    // keeps its own 1s pulse so the removal happens even with no other
    // listener alive.
    _retire = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _retire?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final requests = [
      for (final e in widget.requests)
        if (ApprovalInbox.isVisible(e, now)) e,
    ];
    if (requests.isEmpty) return const SizedBox.shrink();
    final strings = AppStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            strings.resolve(
              MessageKey.approvalPendingCount,
              args: {'count': '${requests.length}'},
            ),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final r in requests)
          PendingApprovalCard(
            key: ValueKey('approval-inbox-${r.requestId}'),
            request: r,
            unconfirmed: widget.unconfirmedRuns.contains(r.runId),
            onResolve: widget.onResolve,
            onReconfirm: widget.onReconfirm,
            focused: r.requestId == widget.focusRequestId,
          ),
      ],
    );
  }
}

/// One exact-request card: live countdown (an ESTIMATE, marked 約), the
/// server's actual choices, one shared busy flag per request, and an
/// expiry state that asks the server instead of auto-denying (R9 red line).
class PendingApprovalCard extends StatefulWidget {
  const PendingApprovalCard({
    super.key,
    required this.request,
    required this.unconfirmed,
    required this.onResolve,
    required this.onReconfirm,
    this.focused = false,
  });

  final ApprovalRequest request;
  final bool unconfirmed;
  final Future<void> Function(ApprovalRequest request, String choice)
  onResolve;
  final Future<void> Function(ApprovalRequest request) onReconfirm;

  /// Deep-link focus ring (F5): marks the EXACT named request, nothing else.
  final bool focused;

  @override
  State<PendingApprovalCard> createState() => _PendingApprovalCardState();
}

class _PendingApprovalCardState extends State<PendingApprovalCard> {
  Timer? _ticker;
  bool _reconfirmAsked = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    if (!widget.focused) return card;
    // F5: the ONE card a deep link named wears the focus ring.
    return DecoratedBox(
      key: const ValueKey('approval-focus-ring'),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(18),
      ),
      child: card,
    );
  }

  Widget _card(BuildContext context) {
    final strings = AppStrings.of(context);
    final colors = Theme.of(context).colorScheme;
    final r = widget.request;
    final now = _now();

    if (r.phase == ApprovalPhase.resolved) {
      return Card(
        key: const ValueKey('approval-inbox-resolved'),
        color: colors.surfaceContainerHighest,
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            strings.resolve(MessageKey.approvalResolvedElsewhere),
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      );
    }

    final expired = r.expiredAt(now);
    final remaining = r.remainingSeconds(now);
    final stalled = widget.unconfirmed || expired;
    if (expired && !_reconfirmAsked) {
      _reconfirmAsked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(widget.onReconfirm(r));
      });
    }
    final actionable = !r.busy && !stalled;
    return Card(
      color: colors.errorContainer,
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.resolve(MessageKey.approvalRequestTitle),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              r.description?.isNotEmpty == true
                  ? r.description!
                  : strings.resolve(MessageKey.approvalRequestTitle),
              style: TextStyle(color: colors.onErrorContainer),
            ),
            if (r.command?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  r.command!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              remaining == null
                  ? strings.resolve(MessageKey.approvalChecking)
                  : strings.resolve(
                      MessageKey.approvalRemaining,
                      args: {'seconds': '$remaining'},
                    ),
              style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
            ),
            Text(
              strings.resolve(MessageKey.approvalTimeoutPolicy),
              style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
            ),
            if (r.busy)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.resolve(MessageKey.approvalSubmitting),
                  style: TextStyle(fontSize: 12, color: colors.onErrorContainer),
                ),
              ),
            if (widget.unconfirmed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  strings.resolve(MessageKey.approvalUnavailable),
                  style: TextStyle(fontSize: 12, color: colors.error),
                ),
              )
            else if (r.error case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LocalizedText(
                  e,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Only the server's actual choices; unknown tokens get no
                // submittable button (R6).
                for (final c in r.choices)
                  if (approvalChoiceKeys.containsKey(c))
                    FilledButton.tonal(
                      onPressed: actionable ? () => widget.onResolve(r, c) : null,
                      style: c == 'deny'
                          ? FilledButton.styleFrom(
                              backgroundColor: colors.errorContainer,
                              foregroundColor: colors.onErrorContainer,
                              side: BorderSide(color: colors.error),
                            )
                          : null,
                      child: Text(strings.resolve(approvalChoiceKeys[c]!)),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
