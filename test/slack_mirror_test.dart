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
  group('InMemorySlackMirror', () {
    test('headFor is null before any write', () {
      final m = InMemorySlackMirror();
      expect(m.headFor(_path()), isNull);
      expect(m.epochFor(_path()), 1);
    });

    test('write returns a TurnId and sets the head', () {
      final m = InMemorySlackMirror();
      final id = m.write(_path(), _msg(ts: '1730000000.000100'));
      expect(m.headFor(_path()), equals(id));
    });

    test('two writes to the same path chain parent → child', () {
      final m = InMemorySlackMirror();
      final a = m.write(_path(), _msg(ts: '1730000000.000100'));
      final b = m.write(_path(), _msg(ts: '1730000000.000200', text: 'again'));
      expect(a, isNot(equals(b)));
      expect(m.headFor(_path()), equals(b));
      expect(m.walk(b).toList(), hasLength(2));
    });

    test('walk yields newest-first', () {
      final m = InMemorySlackMirror();
      m.write(_path(), _msg(ts: '1', text: 'first'));
      final second = m.write(_path(), _msg(ts: '2', text: 'second'));
      final nodes = m.walk(second).toList();
      expect((nodes[0] as SlackMessage).text, 'second');
      expect((nodes[1] as SlackMessage).text, 'first');
    });

    test('two paths have independent heads', () {
      final m = InMemorySlackMirror();
      final p1 = _path(channel: 'C01');
      final p2 = _path(channel: 'C02');
      final a = m.write(p1, _msg(ts: '1', channel: 'C01'));
      final b = m.write(p2, _msg(ts: '1', channel: 'C02'));
      expect(m.headFor(p1), equals(a));
      expect(m.headFor(p2), equals(b));
      expect(a, isNot(equals(b)));
    });

    test('id is reproducible given the same parent and node', () {
      final m1 = InMemorySlackMirror();
      final m2 = InMemorySlackMirror();
      final node = _msg(ts: '1730000000.000100');
      final id1 = m1.write(_path(), node);
      final id2 = m2.write(_path(), node);
      expect(id1, equals(id2));
    });

    test('id changes with parent (same node bytes, different chain)', () {
      final m = InMemorySlackMirror();
      final rootA = m.write(_path(), _msg(ts: 'root-a'));
      m.write(_path(), _msg(ts: 'root-a-child'));
      final rootB = m.write(_path(channel: 'C02'), _msg(ts: 'root-a', channel: 'C02'));
      // Same node bytes as rootA (ts collision), but different chain → different id.
      expect(rootA, isNot(equals(rootB)));
    });

    test('nodeAt returns the written node', () {
      final m = InMemorySlackMirror();
      final node = _msg(ts: 'x', text: 'hello');
      final id = m.write(_path(), node);
      expect(m.nodeAt(id), same(node));
    });

    test('walk from an unknown id throws', () {
      final m = InMemorySlackMirror();
      final fakeId = TurnId.parse('0' * 64)!;
      expect(() => m.walk(fakeId).toList(), throwsStateError);
    });

    test('locate finds a message by (channel, ts)', () {
      final m = InMemorySlackMirror();
      final id = m.write(_path(), _msg(ts: 'x-ts', channel: 'C01'));
      final hit = m.locate('C01', 'x-ts');
      expect(hit, isNotNull);
      expect(hit!.id, equals(id));
      expect(hit.path, equals(_path()));
    });

    test('locate misses when nothing was written at that (channel, ts)', () {
      final m = InMemorySlackMirror();
      m.write(_path(), _msg(ts: 'x-ts'));
      expect(m.locate('C01', 'other-ts'), isNull);
      expect(m.locate('C-other', 'x-ts'), isNull);
    });

    test('locate does not index SlackReaction (reactions have no channel)', () {
      final m = InMemorySlackMirror();
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

    test('pathOf returns the journey a TurnId sits on', () {
      final m = InMemorySlackMirror();
      final p1 = _path(channel: 'C01');
      final p2 = _path(channel: 'C02');
      final a = m.write(p1, _msg(ts: '1', channel: 'C01'));
      final b = m.write(p2, _msg(ts: '2', channel: 'C02'));
      expect(m.pathOf(a), equals(p1));
      expect(m.pathOf(b), equals(p2));
    });

    test('findReaction matches on (target, emoji, by)', () {
      final m = InMemorySlackMirror();
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
      final m = InMemorySlackMirror();
      final fakeId = TurnId.parse('0' * 64)!;
      expect(
        m.findReaction(target: fakeId, emoji: 'x', by: _actor()),
        isNull,
      );
    });

    test('findReaction returns null when no matching reaction exists', () {
      final m = InMemorySlackMirror();
      final msgId = m.write(_path(), _msg(ts: 'msg'));
      expect(
        m.findReaction(target: msgId, emoji: 'nope', by: _actor()),
        isNull,
      );
    });

    test('writeWithdraw + withdrawnBy round-trips', () {
      final m = InMemorySlackMirror();
      final msgId = m.write(_path(), _msg(ts: 'msg'));
      final reactionId = m.write(
        _path(),
        SlackReaction(target: msgId, emoji: 'thumbsup', by: _actor(), ts: 'r'),
      );
      expect(m.withdrawnBy(reactionId), isNull);
      final w = Withdraw<SlackReaction>(target: reactionId, by: _actor());
      m.writeWithdraw(w);
      expect(m.withdrawnBy(reactionId), same(w));
    });

    test('each node shape writes successfully', () {
      final m = InMemorySlackMirror();
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
      expect(m.walk(m.headFor(_path())!).toList(), hasLength(5));
    });
  });
}
