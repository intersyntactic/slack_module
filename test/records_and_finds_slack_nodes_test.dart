import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

SlackThread _path({String channel = 'C01', String ts = '1730000000.000100'}) =>
    SlackThread(workspace: 'T01ABC', channel: channel, threadTs: ts);

ActorId _actor([String user = 'U01']) =>
    SlackActorId.forWorkspace(workspaceId: 'T01ABC', userId: user);

SlackMessage _msg({
  required String ts,
  String text = 'hi',
  ActorId? by,
  String? threadTs,
  String channel = 'C01',
}) =>
    SlackMessage(
      channel: channel,
      ts: ts,
      by: by ?? _actor(),
      text: text,
      threadTs: threadTs,
    );

void main() {
  group('InMemoryRecordsAndFindsSlackNodes', () {
    test('nothing recorded before any write', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      expect(m.locate(_path().channel, '1730000000.000100'), isNull);
      expect(m.epochFor(_path()), 1);
    });

    test('write returns a TurnId and records it under the path', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final id = m.write(_path(), _msg(ts: '1730000000.000100'));
      expect(m.pathOf(id), equals(_path()));
      expect(m.nodeAt(id), isNotNull);
    });

    test('two writes to the same path mint distinct ids', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final a = m.write(_path(), _msg(ts: '1730000000.000100'));
      final b = m.write(_path(), _msg(ts: '1730000000.000200', text: 'again'));
      expect(a, isNot(equals(b)));
      expect(m.pathOf(a), equals(_path()));
      expect(m.pathOf(b), equals(_path()));
    });

    test('two paths are independently tracked', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final p1 = _path(channel: 'C01');
      final p2 = _path(channel: 'C02');
      final a = m.write(p1, _msg(ts: '1', channel: 'C01'));
      final b = m.write(p2, _msg(ts: '1', channel: 'C02'));
      expect(m.pathOf(a), equals(p1));
      expect(m.pathOf(b), equals(p2));
      expect(a, isNot(equals(b)));
    });

    test('id is reproducible given the same node', () {
      final m1 = InMemoryRecordsAndFindsSlackNodes();
      final m2 = InMemoryRecordsAndFindsSlackNodes();
      final node = _msg(ts: '1730000000.000100');
      final id1 = m1.write(_path(), node);
      final id2 = m2.write(_path(), node);
      expect(id1, equals(id2));
    });

    test('id changes with the node\'s own fields, not its path', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final rootA = m.write(_path(), _msg(ts: 'root-a'));
      final rootB = m.write(_path(channel: 'C02'), _msg(ts: 'root-a', channel: 'C02'));
      // Same ts, but a different channel field → different content → different id.
      expect(rootA, isNot(equals(rootB)));
    });

    test('nodeAt returns the written node', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final node = _msg(ts: 'x', text: 'hello');
      final id = m.write(_path(), node);
      expect(m.nodeAt(id), same(node));
    });

    test('nodeAt on an unknown id returns null', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final fakeId = TurnId.parse('0' * 64)!;
      expect(m.nodeAt(fakeId), isNull);
    });

    test('locate finds a message by (channel, ts)', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final id = m.write(_path(), _msg(ts: 'x-ts', channel: 'C01'));
      final hit = m.locate('C01', 'x-ts');
      expect(hit, isNotNull);
      expect(hit!.id, equals(id));
      expect(hit.path, equals(_path()));
    });

    test('locate misses when nothing was written at that (channel, ts)', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      m.write(_path(), _msg(ts: 'x-ts'));
      expect(m.locate('C01', 'other-ts'), isNull);
      expect(m.locate('C-other', 'x-ts'), isNull);
    });

    test('locate does not index SlackReaction (reactions have no channel)', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final msgId = m.write(_path(), _msg(ts: 'msg-ts', channel: 'C01'));
      m.write(
        _path(),
        SlackReaction(
          target: msgId,
          emoji: 'thumbsup',
          by: _actor(),
          ts: 'reaction-ts',
        ),
      );
      // The reaction node's own ts is not reachable via locate.
      expect(m.locate('C01', 'reaction-ts'), isNull);
    });

    test('pathOf returns the mission a TurnId sits on', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final p1 = _path(channel: 'C01');
      final p2 = _path(channel: 'C02');
      final a = m.write(p1, _msg(ts: '1', channel: 'C01'));
      final b = m.write(p2, _msg(ts: '2', channel: 'C02'));
      expect(m.pathOf(a), equals(p1));
      expect(m.pathOf(b), equals(p2));
    });

    test('findReaction matches on (target, emoji, by)', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final msgId = m.write(_path(), _msg(ts: 'msg'));
      final alice = _actor('U-alice');
      final bob = _actor('U-bob');
      final aliceThumb = m.write(
        _path(),
        SlackReaction(target: msgId, emoji: 'thumbsup', by: alice, ts: 'r1'),
      );
      m.write(
        _path(),
        SlackReaction(target: msgId, emoji: 'thumbsup', by: bob, ts: 'r2'),
      );
      expect(
        m.findReaction(target: msgId, emoji: 'thumbsup', by: alice),
        equals(aliceThumb),
      );
    });

    test('findReaction returns null when target is unknown', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final fakeId = TurnId.parse('0' * 64)!;
      expect(
        m.findReaction(target: fakeId, emoji: 'x', by: _actor()),
        isNull,
      );
    });

    test('findReaction returns null when no matching reaction exists', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final msgId = m.write(_path(), _msg(ts: 'msg'));
      expect(
        m.findReaction(target: msgId, emoji: 'nope', by: _actor()),
        isNull,
      );
    });

    test('writeWithdraw + withdrawnBy round-trips', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final msgId = m.write(_path(), _msg(ts: 'msg'));
      final reactionId = m.write(
        _path(),
        SlackReaction(target: msgId, emoji: 'thumbsup', by: _actor(), ts: 'r'),
      );
      expect(m.withdrawnBy(reactionId), isNull);
      final w = Withdrawal<SlackReaction>(target: reactionId, by: _actor());
      m.writeWithdraw(w);
      expect(m.withdrawnBy(reactionId), same(w));
    });

    test('each node shape writes successfully', () {
      final m = InMemoryRecordsAndFindsSlackNodes();
      final msgId = m.write(_path(), _msg(ts: '1'));
      final editId = m.write(
        _path(),
        SlackEdit(
          replaces: msgId,
          channel: 'C01',
          editTs: '2',
          by: _actor(),
          newText: 'edited',
        ),
      );
      final reactId = m.write(
        _path(),
        SlackReaction(target: msgId, emoji: 'thumbsup', by: _actor(), ts: '3'),
      );
      final tombId = m.write(
        _path(),
        SlackTombstone(target: msgId, by: _actor(), ts: '4'),
      );
      final rawId = m.write(
        _path(),
        SlackEventRaw(
          slackEventType: 'pin_added',
          channel: 'C01',
          ts: '5',
          rawPayload: '{}',
        ),
      );
      expect({msgId, editId, reactId, tombId, rawId}.length, 5);
      for (final id in [msgId, editId, reactId, tombId, rawId]) {
        expect(m.nodeAt(id), isNotNull);
        expect(m.pathOf(id), equals(_path()));
      }
    });
  });
}
