/// NIP-AR (`kind:44201`) turn receipts: what one agent turn ran on, and what it
/// consumed.
///
/// See `docs/nips/NIP-AR.md`. A receipt is plaintext, channel-scoped, carries
/// exactly one `h` tag and one `model` tag, and one `e` tag per message the
/// turn published, in publication order.
///
/// Two rules from the NIP are implemented here rather than merely honoured by
/// convention, because getting either wrong is a correctness defect the reader
/// cannot detect:
///
/// 1. **Trust.** Anyone may sign a receipt `e`-tagging anyone's message. A
///    receipt is a claim by its author *about its author*, so a receipt whose
///    `pubkey` differs from the author of the message it would annotate is
///    discarded (see `attachTurnReceipts` in `timeline_message.dart`).
/// 2. **Render once per turn.** The counts belong to the turn, not to any one
///    message. A turn that published three messages emits one receipt naming
///    all three; rendering it under each would show one turn's spend three
///    times and read as triple the cost.
///
/// ## Absent counts are not zero
///
/// Every token field in the payload is nullable, and the cache fields may be
/// omitted entirely. `null` means *the harness reported nothing* — substituting
/// `0` would state a number the provider never gave. This file keeps that
/// distinction in the type ([ReceiptCount]) so no widget can collapse it with a
/// `?? 0`, mirroring the vocabulary desktop settled on in
/// `desktop/src/features/local-archive/agentUsageFormat.ts`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../shared/relay/relay.dart';

/// Glyph for a counter the harness never reported. Deliberately not `0`.
const String receiptNotReportedGlyph = '—';

/// Text for a counter that was present but could not be read as a
/// non-negative integer.
const String receiptUnreadableLabel = 'Unknown';

final NumberFormat _tokenFormat = NumberFormat.decimalPattern();

/// How one counter from a receipt's `turn` object should read.
///
/// The three states mean three different things, and only [reported] carries a
/// number. A reported `0` is a real zero — the provider said zero — and renders
/// as `0`; the other two never do.
enum ReceiptCountState {
  /// The harness reported a usable non-negative integer, possibly `0`.
  reported,

  /// The field was absent or explicitly `null`. Not zero: unreported.
  notReported,

  /// The field was present but was not a non-negative integer, so nothing
  /// about it can be stated honestly.
  unreadable,
}

/// One token counter from a receipt, with its provenance kept attached.
@immutable
class ReceiptCount {
  final ReceiptCountState state;

  /// The reported value. Non-null exactly when [state] is
  /// [ReceiptCountState.reported].
  final int? value;

  const ReceiptCount._(this.state, this.value);

  static const ReceiptCount notReported = ReceiptCount._(
    ReceiptCountState.notReported,
    null,
  );

  static const ReceiptCount unreadable = ReceiptCount._(
    ReceiptCountState.unreadable,
    null,
  );

  /// Read one counter out of a decoded `turn` object.
  ///
  /// A missing key and an explicit JSON `null` are the same thing to a reader —
  /// the NIP allows the cache fields to be omitted and the rest to be `null` —
  /// so both become [notReported]. Anything else that is not a non-negative
  /// integer becomes [unreadable] rather than being silently coerced.
  factory ReceiptCount.parse(Object? raw) {
    if (raw == null) return notReported;
    if (raw is! num) return unreadable;
    if (raw is double && raw != raw.roundToDouble()) return unreadable;
    final value = raw.toInt();
    if (value < 0) return unreadable;
    return ReceiptCount._(ReceiptCountState.reported, value);
  }

  /// Whether this counter says anything at all, which is what decides if it
  /// earns a slot in the footer.
  bool get hasValue => state == ReceiptCountState.reported;

  /// Visible text. `0` appears only for a genuinely reported zero.
  String get display => switch (state) {
    ReceiptCountState.reported => _tokenFormat.format(value),
    ReceiptCountState.notReported => receiptNotReportedGlyph,
    ReceiptCountState.unreadable => receiptUnreadableLabel,
  };

  /// Spoken text. The `—` glyph does not read aloud usefully, and "zero" is the
  /// one thing an unreported counter must never say.
  String get spoken => switch (state) {
    ReceiptCountState.reported => _tokenFormat.format(value),
    ReceiptCountState.notReported => 'not reported',
    ReceiptCountState.unreadable => 'unknown',
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReceiptCount && other.state == state && other.value == value;

  @override
  int get hashCode => Object.hash(state, value);

  @override
  String toString() => 'ReceiptCount(${state.name}, $value)';
}

/// A validated NIP-AR turn receipt.
@immutable
class AgentTurnReceipt {
  /// The receipt event's own id, used to break ties between two receipts that
  /// resolve to the same message.
  final String eventId;

  /// The receipt's author. Only equal to the annotated message's author does
  /// the receipt get rendered — see [AgentTurnReceipt] docs, rule 1.
  final String pubkey;

  final int createdAt;

  /// The model the turn actually ran on, as the harness observed it.
  final String model;

  /// Harness identifier (`claude-agent-acp`, `goose`, …).
  final String harness;

  /// Message ids this turn published, in publication order.
  final List<String> messageIds;

  final ReceiptCount inputTokens;
  final ReceiptCount outputTokens;
  final ReceiptCount cacheReadTokens;
  final ReceiptCount cacheWriteTokens;

  const AgentTurnReceipt({
    required this.eventId,
    required this.pubkey,
    required this.createdAt,
    required this.model,
    required this.harness,
    required this.messageIds,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
  });

  /// Parse a `kind:44201` event, or return null when it is not a receipt this
  /// client is willing to show.
  ///
  /// The Buzz relay validates this envelope on ingest, but a client must not
  /// depend on that: a receipt can arrive from any relay, and a malformed one
  /// rendered anyway would attribute nonsense to a real agent. The checks are
  /// the NIP's own §Event requirements — exactly one non-empty `model` tag,
  /// at least one `e` tag, a body that parses with a non-empty `model` and
  /// `harness`, and a body `model` equal to the tag. A tag/body disagreement is
  /// specifically fatal: the tag is what a `#model` filter matches on, so
  /// showing the body's value would make that filter lie.
  static AgentTurnReceipt? fromEvent(NostrEvent event) {
    if (event.kind != EventKind.agentTurnReceipt) return null;

    final messageIds = <String>[];
    String? modelTag;
    var modelTagCount = 0;
    for (final tag in event.tags) {
      if (tag.length < 2) continue;
      switch (tag[0]) {
        case 'e':
          // A receipt annotates; it does not reply. A NIP-10 marker would make
          // it a thread link, so a marked tag is not a receipt target.
          if (tag.length >= 4 && tag[3].isNotEmpty) continue;
          if (tag[1].isEmpty) continue;
          messageIds.add(tag[1].toLowerCase());
        case 'model':
          modelTagCount += 1;
          modelTag = tag[1];
      }
    }
    if (messageIds.isEmpty) return null;
    if (modelTagCount != 1 || modelTag == null || modelTag.trim().isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(event.content);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final model = decoded['model'];
    final harness = decoded['harness'];
    if (model is! String || model.trim().isEmpty) return null;
    if (harness is! String || harness.trim().isEmpty) return null;
    if (model != modelTag) return null;

    final turn = decoded['turn'];
    final counts = turn is Map ? turn : const {};

    return AgentTurnReceipt(
      eventId: event.id,
      pubkey: event.pubkey,
      createdAt: event.createdAt,
      model: model.trim(),
      harness: harness.trim(),
      messageIds: List.unmodifiable(messageIds),
      inputTokens: ReceiptCount.parse(counts['inputTokens']),
      outputTokens: ReceiptCount.parse(counts['outputTokens']),
      cacheReadTokens: ReceiptCount.parse(counts['cacheReadTokens']),
      cacheWriteTokens: ReceiptCount.parse(counts['cacheWriteTokens']),
    );
  }

  /// Whether any token counter carries a number. A receipt whose harness
  /// reported nothing still names its model, which is worth showing on its own.
  bool get reportsAnyTokens =>
      inputTokens.hasValue ||
      outputTokens.hasValue ||
      cacheReadTokens.hasValue ||
      cacheWriteTokens.hasValue;
}

/// Labelled counters in the order the footer lays them out.
const List<String> receiptCountLabels = [
  'in',
  'out',
  'cache read',
  'cache write',
];

/// The four counters of [receipt], paired with [receiptCountLabels].
List<ReceiptCount> receiptCounts(AgentTurnReceipt receipt) => [
  receipt.inputTokens,
  receipt.outputTokens,
  receipt.cacheReadTokens,
  receipt.cacheWriteTokens,
];

/// One sentence describing the whole receipt, for assistive technology.
///
/// The visible row is glyph-dense (`—`, `·`) and reads as noise aloud, so the
/// footer speaks this instead of its own children.
String receiptSpokenSummary(AgentTurnReceipt receipt) {
  final counters = <String>[];
  final counts = receiptCounts(receipt);
  for (var index = 0; index < counts.length; index += 1) {
    final label = switch (receiptCountLabels[index]) {
      'in' => 'input',
      'out' => 'output',
      final other => other,
    };
    counters.add('$label ${counts[index].spoken}');
  }
  return 'Agent turn ran on ${receipt.model}. '
      'Tokens: ${counters.join(', ')}.';
}
