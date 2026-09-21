import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/features/channels/agent_turn_receipt.dart';
import 'package:buzz/features/channels/agent_turn_receipt_footer.dart';
import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';

import '../../helpers/widget_helpers.dart';

const _channelId = 'ch1';
const _agent = 'a11ce';
const _stranger = 'deadbeef';

NostrEvent _message({
  required String id,
  String pubkey = _agent,
  String content = 'done',
  int createdAt = 1000,
}) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: EventKind.streamMessage,
  tags: const [
    ['h', _channelId],
  ],
  content: content,
  sig: '',
);

/// A well-formed NIP-AR receipt. [bodyModel] defaults to [model] so the tag and
/// the body agree; passing it explicitly is how a disagreement is staged.
NostrEvent _receipt({
  String id = 'receipt',
  required List<String> messageIds,
  String pubkey = _agent,
  int createdAt = 1100,
  String model = 'claude-opus-4-5',
  String? bodyModel,
  String harness = 'claude-agent-acp',
  Map<String, Object?> turn = const {
    'inputTokens': 191261,
    'outputTokens': 683,
    'cacheReadTokens': 122407,
    'cacheWriteTokens': 4096,
  },
  List<List<String>>? eTags,
}) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: EventKind.agentTurnReceipt,
  tags: [
    const ['h', _channelId],
    ...(eTags ??
        [
          for (final messageId in messageIds) ['e', messageId],
        ]),
    ['model', model],
  ],
  content: jsonEncode({
    'model': bodyModel ?? model,
    'harness': harness,
    'turn': turn,
  }),
  sig: '',
);

AgentTurnReceipt _parse(NostrEvent event) => AgentTurnReceipt.fromEvent(event)!;

void main() {
  group('turn receipts attach to the timeline', () {
    test('a receipt authored by someone other than the message author is '
        'ignored', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(messageIds: const ['m1'], pubkey: _stranger),
      ]);

      expect(messages.single.turnReceipt, isNull);
    });

    test('a receipt authored by the message author is attached', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(messageIds: const ['m1']),
      ]);

      expect(messages.single.turnReceipt?.model, 'claude-opus-4-5');
    });

    test('a turn that published three messages attaches its receipt once, to '
        'the last of them', () {
      final messages = formatTimeline([
        _message(id: 'm1', createdAt: 1000),
        _message(id: 'm2', createdAt: 1001),
        _message(id: 'm3', createdAt: 1002),
        _receipt(messageIds: const ['m1', 'm2', 'm3']),
      ]);

      expect(
        messages.map((message) => message.turnReceipt != null),
        [false, false, true],
        reason: 'one turn is one footer, under the turn\'s final message',
      );
    });

    test('a receipt anchors to the last named message this client actually '
        'holds', () {
      // The turn published three messages; this client never loaded the third.
      final messages = formatTimeline([
        _message(id: 'm1', createdAt: 1000),
        _message(id: 'm2', createdAt: 1001),
        _receipt(messageIds: const ['m1', 'm2', 'm3']),
      ]);

      expect(messages.map((message) => message.turnReceipt != null), [
        false,
        true,
      ]);
    });

    test('a receipt naming no message this client holds is never rendered', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(messageIds: const ['somewhere-else']),
      ]);

      expect(messages.single.turnReceipt, isNull);
    });

    test('a forged receipt is dropped rather than walked back to an earlier '
        'message it names', () {
      // The attacker names their own message first and the victim's last, so a
      // consumer that fell back on a failed trust check would still render
      // attacker-supplied numbers — under the attacker's own message, but
      // sourced from a receipt that lies about the victim's.
      final messages = formatTimeline([
        _message(id: 'mine', pubkey: _stranger, createdAt: 1000),
        _message(id: 'theirs', pubkey: _agent, createdAt: 1001),
        _receipt(messageIds: const ['mine', 'theirs'], pubkey: _stranger),
      ]);

      expect(messages.map((message) => message.turnReceipt), [isNull, isNull]);
    });

    test('a receipt whose model tag disagrees with its content is ignored', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(
          messageIds: const ['m1'],
          model: 'claude-opus-4-5',
          bodyModel: 'something-cheaper',
        ),
      ]);

      expect(messages.single.turnReceipt, isNull);
    });

    test('a receipt whose only e tag carries a NIP-10 marker is ignored', () {
      // A marked `e` tag is a thread link, not an annotation target. A receipt
      // is an overlay on the messages it names, never a reply to them.
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(
          messageIds: const ['m1'],
          eTags: const [
            ['e', 'm1', '', 'reply'],
          ],
        ),
      ]);

      expect(messages.single.turnReceipt, isNull);
    });

    test('the newer receipt wins when two of them anchor to the same '
        'message', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(
          id: 'older',
          messageIds: const ['m1'],
          createdAt: 1100,
          model: 'first-model',
        ),
        _receipt(
          id: 'newer',
          messageIds: const ['m1'],
          createdAt: 1200,
          model: 'second-model',
        ),
      ]);

      expect(messages.single.turnReceipt?.model, 'second-model');
    });

    test('a deleted receipt is ignored', () {
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(id: 'receipt', messageIds: const ['m1']),
        NostrEvent(
          id: 'del',
          pubkey: _agent,
          createdAt: 1200,
          kind: EventKind.deletion,
          tags: const [
            ['e', 'receipt'],
          ],
          content: '',
          sig: '',
        ),
      ]);

      expect(messages.single.turnReceipt, isNull);
    });

    test('kind 44201 is an overlay kind, not a timeline row or a message', () {
      // A receipt has no row of its own: counting it as channel content would
      // create a phantom unread for an event no reader can see.
      expect(
        EventKind.channelEventKinds,
        contains(EventKind.agentTurnReceipt),
        reason: 'the channel subscription must not discard receipts',
      );
      expect(
        EventKind.channelAuxEventKinds,
        contains(EventKind.agentTurnReceipt),
      );
      expect(
        EventKind.channelMessageEventKinds,
        isNot(contains(EventKind.agentTurnReceipt)),
      );
      expect(
        EventKind.channelTimelineContentKinds,
        isNot(contains(EventKind.agentTurnReceipt)),
      );

      // And it renders no row of its own.
      final messages = formatTimeline([
        _message(id: 'm1'),
        _receipt(messageIds: const ['m1']),
      ]);
      expect(messages, hasLength(1));
    });
  });

  group('unreported counts are never rendered as zero', () {
    test('a null token count parses as not reported, not as zero', () {
      final receipt = _parse(
        _receipt(
          messageIds: const ['m1'],
          turn: const {
            'inputTokens': null,
            'outputTokens': 683,
            'cacheReadTokens': null,
          },
        ),
      );

      expect(receipt.inputTokens.state, ReceiptCountState.notReported);
      expect(receipt.inputTokens.value, isNull);
      // The cache fields may be omitted entirely; absence reads the same.
      expect(receipt.cacheWriteTokens.state, ReceiptCountState.notReported);
      expect(receipt.outputTokens.value, 683);
    });

    test('a reported zero parses as a real zero', () {
      final receipt = _parse(
        _receipt(messageIds: const ['m1'], turn: const {'outputTokens': 0}),
      );

      expect(receipt.outputTokens.state, ReceiptCountState.reported);
      expect(receipt.outputTokens.display, '0');
    });

    test('a token count that is not a non-negative integer reads as unknown, '
        'not as zero', () {
      final receipt = _parse(
        _receipt(
          messageIds: const ['m1'],
          turn: const {'inputTokens': -5, 'outputTokens': 'lots'},
        ),
      );

      expect(receipt.inputTokens.state, ReceiptCountState.unreadable);
      expect(receipt.outputTokens.state, ReceiptCountState.unreadable);
      expect(receipt.inputTokens.display, isNot('0'));
      expect(receipt.outputTokens.display, isNot('0'));
    });
  });

  group('AgentTurnReceiptFooter', () {
    Future<void> pumpFooter(WidgetTester tester, AgentTurnReceipt receipt) {
      return tester.pumpWidget(
        WidgetHelpers.testable(child: AgentTurnReceiptFooter(receipt: receipt)),
      );
    }

    testWidgets('names the model the turn ran on', (tester) async {
      await pumpFooter(tester, _parse(_receipt(messageIds: const ['m1'])));

      expect(find.text('claude-opus-4-5'), findsOneWidget);
    });

    testWidgets('renders every reported token count', (tester) async {
      await pumpFooter(tester, _parse(_receipt(messageIds: const ['m1'])));

      expect(find.text('· in 191,261'), findsOneWidget);
      expect(find.text('· out 683'), findsOneWidget);
      expect(find.text('· cache read 122,407'), findsOneWidget);
      expect(find.text('· cache write 4,096'), findsOneWidget);
    });

    testWidgets('renders a count the harness did not report as a dash, never '
        'as zero', (tester) async {
      await pumpFooter(
        tester,
        _parse(
          _receipt(
            messageIds: const ['m1'],
            turn: const {'inputTokens': 12, 'outputTokens': null},
          ),
        ),
      );

      expect(find.text('· out —'), findsOneWidget);
      expect(find.text('· out 0'), findsNothing);
      expect(find.text('· cache read —'), findsOneWidget);
      expect(find.text('· cache write —'), findsOneWidget);
      // Falsifiability: the dash is not simply what every slot renders.
      expect(find.text('· in 12'), findsOneWidget);
    });

    testWidgets('renders a reported zero as zero', (tester) async {
      await pumpFooter(
        tester,
        _parse(
          _receipt(messageIds: const ['m1'], turn: const {'outputTokens': 0}),
        ),
      );

      expect(find.text('· out 0'), findsOneWidget);
      expect(find.text('· out —'), findsNothing);
    });

    testWidgets('speaks one sentence instead of its glyphs', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFooter(
        tester,
        _parse(
          _receipt(
            messageIds: const ['m1'],
            turn: const {'inputTokens': 10, 'outputTokens': null},
          ),
        ),
      );

      expect(
        find.bySemanticsLabel(
          'Agent turn ran on claude-opus-4-5. Tokens: input 10, '
          'output not reported, cache read not reported, cache write not '
          'reported.',
        ),
        findsOneWidget,
      );
      // The dash glyph must not be what a screen reader announces.
      expect(find.bySemanticsLabel('· out —'), findsNothing);
      handle.dispose();
    });

    testWidgets('lines up under the message body, like the reaction row', (
      tester,
    ) async {
      await pumpFooter(tester, _parse(_receipt(messageIds: const ['m1'])));

      // The indent lives in the widget, not at its two call sites, which is
      // what keeps the channel and thread views from drifting apart.
      final padding = tester.widget<Padding>(
        find
            .ancestor(of: find.byType(Wrap), matching: find.byType(Padding))
            .first,
      );
      expect(
        (padding.padding as EdgeInsets).left,
        messageAvatarSize + messageAvatarContentGap,
      );
    });
  });
}
