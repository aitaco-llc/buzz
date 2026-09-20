import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import 'agent_turn_receipt.dart';

/// Gap between the message body and its receipt line.
const double _footerTopGap = Grid.quarter;

/// Icon size for the leading model glyph, sized to the 13.1sp meta ramp.
const double _footerIconSize = 13.0;

/// The one-line NIP-AR footer under an agent turn's final message: the model
/// the turn ran on, and the tokens it consumed.
///
/// ## One widget, two surfaces
///
/// The channel timeline (`channel_detail_page/message_bubble.dart`) and the
/// thread view (`thread_detail_page/thread_message.dart`) render the same
/// message in two places, and a footer duplicated across both would drift the
/// first time either was adjusted. So this widget owns its own indent — the
/// `messageAvatarSize + messageAvatarContentGap` gutter that lines it up under
/// the message body, the same indent the reaction row uses — and both call
/// sites are the identical two lines:
///
/// ```dart
/// if (message.turnReceipt != null)
///   AgentTurnReceiptFooter(receipt: message.turnReceipt!),
/// ```
///
/// There is deliberately no per-site layout to keep in sync.
///
/// ## Absent counts
///
/// A counter the harness did not report renders as `—`, never as `0`: `0` is a
/// claim the provider made, and an unreported counter is the absence of one.
/// [ReceiptCount] keeps the two apart so this widget cannot merge them.
class AgentTurnReceiptFooter extends StatelessWidget {
  final AgentTurnReceipt receipt;

  const AgentTurnReceiptFooter({super.key, required this.receipt});

  @override
  Widget build(BuildContext context) {
    final metaColor = context.colors.onSurfaceVariant;
    final style = messageTimestampTextStyle.copyWith(color: metaColor);
    final counts = receiptCounts(receipt);

    return Padding(
      padding: const EdgeInsets.only(
        left: messageAvatarSize + messageAvatarContentGap,
        top: _footerTopGap,
      ),
      // The visible row is glyph-dense (`·`, `—`) and reads as noise aloud, so
      // it is spoken as one sentence instead of nine fragments.
      child: Semantics(
        label: receiptSpokenSummary(receipt),
        excludeSemantics: true,
        child: Wrap(
          spacing: Grid.half,
          runSpacing: Grid.quarter,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.cpu, size: _footerIconSize, color: metaColor),
                const SizedBox(width: Grid.half),
                Text(receipt.model, style: style),
              ],
            ),
            for (var index = 0; index < counts.length; index += 1)
              Text(
                '· ${receiptCountLabels[index]} ${counts[index].display}',
                style: style,
              ),
          ],
        ),
      ),
    );
  }
}
