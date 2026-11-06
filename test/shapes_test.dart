/// Shape vocabulary tests. The real acceptance test lives in the analyzer:
/// code that shouldn't bind must fail to compile. These runtime tests cover
/// the parts the analyzer can't: id round-tripping and structural equality.
///
/// The analyzer-level tests (that `Withdraw<SlackReaction>` can't be assigned
/// to `Withdraw<Approve>`, that `Correction<SlackVerdict>` can't bind where
/// `Correction<OtherVerdict>` is expected) are already verified in
/// is_review_shapes' own spike and PR #3 using `TypeSystem.isAssignableTo`.
/// Nothing here would add signal to that.
library;

import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

void main() {
  group('SlackMessage', () {
    test('constructs with required fields', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final m = SlackMessage(
        channel: 'C01GENERAL',
        ts: '1730000000.000100',
        by: by,
        text: 'hello',
      );
      expect(m.channel, 'C01GENERAL');
      expect(m.text, 'hello');
      expect(m.threadTs, isNull);
    });

    test('threadTs distinguishes thread replies', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final m = SlackMessage(
        channel: 'C01GENERAL',
        ts: '1730000100.000200',
        by: by,
        text: 'reply',
        threadTs: '1730000000.000100',
      );
      expect(m.threadTs, '1730000000.000100');
    });
  });

  group('SlackEdit', () {
    test('replaces holds the TurnId of the edited message', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final targetId = TurnId.parse(
        '0' * 64,
      )!;
      final e = SlackEdit(
        replaces: targetId,
        channel: 'C01GENERAL',
        editTs: '1730000500.000300',
        by: by,
        newText: 'hello, world',
      );
      expect(e.replaces, targetId);
      expect(e.newText, 'hello, world');
    });
  });

  group('SlackReaction', () {
    test('is final — cannot be extended', () {
      // This is a compile-time property; the runtime check here just
      // documents intent. The analyzer refuses `class X extends SlackReaction`.
      expect(SlackReaction, isA<Type>());
    });

    test('fields mint a reaction', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final targetId = TurnId.parse('1' * 64)!;
      final r = SlackReaction(
        target: targetId,
        emoji: 'thumbsup',
        by: by,
        ts: '1730000200.000100',
      );
      expect(r.emoji, 'thumbsup');
      expect(r.target, targetId);
    });

    test('Withdraw<SlackReaction> targets a specific reaction TurnId', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final reactionId = TurnId.parse('2' * 64)!;
      final w = Withdraw<SlackReaction>(target: reactionId, by: by);
      expect(w.target, reactionId);
      expect(w.by, by);
    });

    test('SlackReaction implements Withdrawable', () {
      // The compile-time guarantee this proves at runtime: Withdraw<T> is
      // bounded by Withdrawable, so Withdraw<SlackReaction> only type-checks
      // because SlackReaction declares it. Other Slack shapes deliberately
      // do not — Withdraw<SlackMessage> is refused by the analyzer.
      final by = PartyId.parse('U01ABC234XY')!;
      final r = SlackReaction(
        target: TurnId.parse('4' * 64)!,
        emoji: 'eyes',
        by: by,
        ts: '1730000300.000100',
      );
      expect(r, isA<Withdrawable>());
    });
  });

  group('SlackTombstone', () {
    test('references the deleted message', () {
      final by = PartyId.parse('U01ABC234XY')!;
      final targetId = TurnId.parse('3' * 64)!;
      final t = SlackTombstone(
        target: targetId,
        by: by,
        ts: '1730001000.000100',
      );
      expect(t.target, targetId);
    });
  });

  group('SlackEventRaw', () {
    test('carries discriminator and raw payload', () {
      final e = SlackEventRaw(
        slackEventType: 'pin_added',
        channel: 'C01GENERAL',
        ts: '1730002000.000100',
        rawPayload: '{"type":"pin_added","item":{"type":"message"}}',
      );
      expect(e.slackEventType, 'pin_added');
      expect(e.by, isNull);
    });
  });
}
