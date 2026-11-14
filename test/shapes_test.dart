/// Shape vocabulary tests. The real acceptance test lives in the analyzer:
/// code that shouldn't bind must fail to compile. These runtime tests cover
/// the parts the analyzer can't: the two shapes whose runtime behavior is
/// part of their contract, not just their fields.
///
/// Plain construction tests (a shape echoes back the fields it was given)
/// were trimmed per "tests prove once" (Nick, 2026-11-14, narrow reading):
/// they didn't prove a specific bug stays fixed, and they weren't guarding
/// a decision or invariant either — every other test that constructs these
/// shapes (gate_parser_test.dart, slack_mirror_test.dart,
/// slack_receiver_test.dart) already exercises the same constructors.
///
/// The analyzer-level tests (that `Withdrawal<SlackReaction>` can't be assigned
/// to `Withdrawal<Approval>`, that `Correction<SlackVerdict>` can't bind where
/// `Correction<OtherVerdict>` is expected) are already verified in
/// is_annotation_shapes' own spike using `TypeSystem.isAssignableTo` (repo
/// renamed from `is_review_shapes` on 2026-11-06:
/// https://github.com/intersyntactic/annotation_shapes).
/// Nothing here would add signal to that.
library;

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

void main() {
  group('SlackReaction', () {
    test('SlackReaction implements Withdrawable', () {
      // The compile-time guarantee this proves at runtime: Withdrawal<T> is
      // bounded by Withdrawable, so Withdrawal<SlackReaction> only type-checks
      // because SlackReaction declares it. Other Slack shapes deliberately
      // do not — Withdrawal<SlackMessage> is refused by the analyzer. A
      // future edit that drops `implements Withdrawable` from SlackReaction
      // would otherwise only be caught wherever a Withdrawal<SlackReaction>
      // happens to get constructed, which might be nowhere for a while.
      final by = SlackActorId.forWorkspace(workspaceId: 'T01ABC', userId: 'U01ABC234XY');
      final r = SlackReaction(
        target: TurnId.parse('4' * 64)!,
        emoji: 'eyes',
        by: by,
        ts: '1730000300.000100',
      );
      expect(r, isA<Withdrawable>());
    });
  });

  group('SlackEventRaw', () {
    test('carries discriminator and raw payload', () {
      // SlackEventRaw's slackEventType is the discriminator composition.md
      // §2's "a node of a shape nothing bound is refused" rule needs: it's
      // what lets Slack events of a subtype not yet typed land here instead
      // of going missing. This checks the discriminator and payload survive
      // construction, not just that the constructor runs.
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
