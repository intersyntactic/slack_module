import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

final _path = JourneyId(
  workspace: 'T01ABC',
  channel: 'C01',
  threadTs: '1730000000.000100',
);
final _self = ActorId.parse('agent:abc123')!;
final _human = SlackActorId.forWorkspace(
  workspaceId: 'T01ABC',
  userId: 'U01HUMAN',
);

void main() {
  group('SlackReceiver', () {
    late InMemorySlackMirror mirror;
    late SlackReceiver receiver;

    setUp(() {
      mirror = InMemorySlackMirror();
      receiver = SlackReceiver(mirror: mirror, selfActor: _self);
    });

    test('inbound message mirrors and asks for a turn', () {
      final out = receiver.receive(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      expect(out.wantsTurn, isTrue);
      expect(out.path, equals(_path));
      expect(out.epoch, 1);
      expect(mirror.headFor(_path), equals(out.mirroredAs));
    });

    test('self-authored message does not ask for a turn (no loop)', () {
      final out = receiver.receive(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _self, text: 'reply'),
      );
      expect(out.wantsTurn, isFalse);
      expect(mirror.headFor(_path), equals(out.mirroredAs));
    });

    test('inbound reaction (per #1094 broad-turn) asks for a turn', () {
      final targetId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      final out = receiver.receive(
        _path,
        SlackReaction(target: targetId, emoji: 'thumbsup', by: _human, ts: '2'),
      );
      expect(out.wantsTurn, isTrue,
          reason: 'A human reaction is a human turn per PR 1112.');
    });

    test('self-authored reaction does not ask for a turn', () {
      final targetId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      final out = receiver.receive(
        _path,
        SlackReaction(target: targetId, emoji: 'arrows_counterclockwise', by: _self, ts: '2'),
      );
      expect(out.wantsTurn, isFalse,
          reason: 'The agent prompts with a reaction; it should not re-wake itself.');
    });

    test('inbound edit by human asks for a turn', () {
      final targetId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      final out = receiver.receive(
        _path,
        SlackEdit(
          replaces: targetId,
          channel: 'C01',
          editTs: '2',
          by: _human,
          newText: 'actually hey',
        ),
      );
      expect(out.wantsTurn, isTrue);
    });

    test('tombstone does not ask for a turn', () {
      final targetId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      final out = receiver.receive(
        _path,
        SlackTombstone(target: targetId, by: _human, ts: '2'),
      );
      expect(out.wantsTurn, isFalse);
    });

    test('raw event does not ask for a turn', () {
      final out = receiver.receive(
        _path,
        SlackEventRaw(
          slackEventType: 'pin_added',
          channel: 'C01',
          ts: '2',
          rawPayload: '{}',
        ),
      );
      expect(out.wantsTurn, isFalse);
    });

    test('withdraw records the Withdraw and asks for a turn when foreign',
        () {
      final msgId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'edit this'),
      );
      final reactionId = mirror.write(
        _path,
        SlackReaction(target: msgId, emoji: 'thumbsup', by: _human, ts: '2'),
      );
      final w = Withdraw<SlackReaction>(target: reactionId, by: _human);
      final out = receiver.withdraw(_path, w);

      expect(out.withdrew, reactionId);
      expect(out.path, equals(_path));
      expect(out.epoch, 1);
      expect(out.wantsTurn, isTrue);
      expect(mirror.withdrawnBy(reactionId), same(w));
    });

    test('self-authored withdraw does not ask for a turn', () {
      final msgId = mirror.write(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'hi'),
      );
      final reactionId = mirror.write(
        _path,
        SlackReaction(
          target: msgId,
          emoji: 'arrows_counterclockwise',
          by: _self,
          ts: '2',
        ),
      );
      final out = receiver.withdraw(
        _path,
        Withdraw<SlackReaction>(target: reactionId, by: _self),
      );
      expect(out.wantsTurn, isFalse);
    });

    test('kickoff record chains in mirror order', () {
      final a = receiver.receive(
        _path,
        SlackMessage(channel: 'C01', ts: '1', by: _human, text: 'first'),
      );
      final b = receiver.receive(
        _path,
        SlackMessage(channel: 'C01', ts: '2', by: _human, text: 'second'),
      );
      expect(mirror.walk(b.mirroredAs).toList(), hasLength(2));
      expect(a.mirroredAs, isNot(equals(b.mirroredAs)));
    });
  });
}
