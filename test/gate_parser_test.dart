import 'dart:convert';
import 'dart:typed_data';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

const team = 'T123';
const channel = 'C999';
const user = 'U999';

relay.SlackMessage messageEvent({
  String text = 'hello',
  String eventTs = '1700000000.000100',
  String? rawThreadTs,
  bool mention = false,
}) =>
    relay.SlackMessage(
      workspace: team,
      channel: channel,
      threadTs: rawThreadTs ?? eventTs,
      mention: mention,
      user: user,
      text: text,
      eventTs: eventTs,
      rawThreadTs: rawThreadTs,
      rawEvent: {
        'type': mention ? 'app_mention' : 'message',
        'channel': channel,
        'user': user,
        'ts': eventTs,
        'thread_ts': ?rawThreadTs,
        'text': text,
      },
    );

relay.SlackMessage editEvent({
  String editTs = '1700000005.000200',
  String newText = 'hello (edited)',
  String previousTs = '1700000000.000100',
  String anchor = '1700000000.000100',
}) =>
    relay.SlackMessage(
      workspace: team,
      channel: channel,
      threadTs: anchor,
      eventTs: editTs,
      subtype: 'message_changed',
      rawEvent: {
        'type': 'message',
        'subtype': 'message_changed',
        'channel': channel,
        'ts': editTs,
        'message': {
          'type': 'message',
          'user': user,
          'text': newText,
          'ts': previousTs,
        },
        'previous_message': {
          'type': 'message',
          'user': user,
          'text': 'hello',
          'ts': previousTs,
        },
      },
    );

relay.SlackMessage deleteEvent({
  String deleteTs = '1700000006.000300',
  String deletedTs = '1700000000.000100',
  String anchor = '1700000000.000100',
}) =>
    relay.SlackMessage(
      workspace: team,
      channel: channel,
      threadTs: anchor,
      user: user,
      eventTs: deleteTs,
      subtype: 'message_deleted',
      rawEvent: {
        'type': 'message',
        'subtype': 'message_deleted',
        'channel': channel,
        'event_ts': deleteTs,
        'deleted_ts': deletedTs,
        'previous_message': {
          'type': 'message',
          'user': user,
          'text': 'hello',
          'ts': deletedTs,
        },
      },
    );

void main() {
  group('plain messages and mentions', () {
    test('a top-level app_mention parses to a SlackMessage', () {
      final (path, node) = parseMessageToSlackNode(
        messageEvent(mention: true),
      );

      expect(path.workspace, team);
      expect(path.channel, channel);
      expect(path.threadTs, '1700000000.000100');

      expect(node, isA<SlackMessage>());
      final m = node as SlackMessage;
      expect(m.channel, channel);
      expect(m.ts, '1700000000.000100');
      expect(m.text, 'hello');
      expect(m.by.toString(), 'slack:$team/$user');
      // Top-level mention: rawThreadTs is null, so SlackMessage.threadTs is
      // null. The journey-path anchor equals the message's own ts.
      expect(m.threadTs, isNull);
    });

    test(
        'a reply inside an existing thread carries rawThreadTs through to '
        'SlackMessage.threadTs', () {
      final (path, node) = parseMessageToSlackNode(
        messageEvent(
          eventTs: '1700000050.000400',
          rawThreadTs: '1700000000.000100',
        ),
      );

      expect(path.threadTs, '1700000000.000100'); // anchor is the thread head
      final m = node as SlackMessage;
      expect(m.ts, '1700000050.000400');
      expect(m.threadTs, '1700000000.000100');
    });

    test('an event missing text falls back to SlackEventRaw', () {
      final event = messageEvent();
      final withoutText = relay.SlackMessage(
        workspace: event.workspace,
        channel: event.channel,
        threadTs: event.threadTs,
        user: event.user,
        eventTs: event.eventTs,
        rawEvent: event.rawEvent,
      );
      final (_, node) = parseMessageToSlackNode(withoutText);
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('edits', () {
    test('a message_changed resolved by lookup becomes a SlackEdit', () {
      final priorId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final (path, node) = parseMessageToSlackNode(
        editEvent(),
        lookup: (SlackThread p, String ts) =>
            p.threadTs == '1700000000.000100' && ts == '1700000000.000100'
                ? priorId
                : null,
      );

      expect(node, isA<SlackEdit>());
      final e = node as SlackEdit;
      expect(e.replaces, priorId);
      expect(e.channel, channel);
      expect(e.editTs, '1700000000.000100');
      expect(e.newText, 'hello (edited)');
      expect(e.by.toString(), 'slack:$team/$user');
      expect(path.threadTs, '1700000000.000100');
    });

    test('a message_changed with no lookup falls back to SlackEventRaw', () {
      final (_, node) = parseMessageToSlackNode(editEvent());
      expect(node, isA<SlackEventRaw>());
      final r = node as SlackEventRaw;
      expect(r.slackEventType, 'message');
      // Faithful mirror: the raw payload is the whole inner event.
      final decoded = jsonDecode(r.rawPayload) as Map;
      expect(decoded['subtype'], 'message_changed');
    });

    test('a message_changed with a lookup that returns null falls back to raw',
        () {
      final (_, node) = parseMessageToSlackNode(
        editEvent(),
        lookup: (_, _) => null,
      );
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('tombstones', () {
    test('a message_deleted resolved by lookup becomes a SlackTombstone', () {
      final targetId = TurnId.of(Uint8List.fromList([4, 5, 6]));
      final (_, node) = parseMessageToSlackNode(
        deleteEvent(),
        lookup: (SlackThread p, String ts) =>
            p.threadTs == '1700000000.000100' && ts == '1700000000.000100'
                ? targetId
                : null,
      );
      expect(node, isA<SlackTombstone>());
      final t = node as SlackTombstone;
      expect(t.target, targetId);
      expect(t.by.toString(), 'slack:$team/$user');
      expect(t.ts, '1700000006.000300');
    });

    test('a message_deleted with no lookup falls back to SlackEventRaw', () {
      final (_, node) = parseMessageToSlackNode(deleteEvent());
      expect(node, isA<SlackEventRaw>());
      final r = node as SlackEventRaw;
      expect(r.slackEventType, 'message');
    });

    test(
        'a message_deleted missing both deleted_ts and previous_message falls '
        'back to SlackEventRaw', () {
      final d = deleteEvent();
      final raw = Map<String, dynamic>.from(d.rawEvent);
      raw.remove('deleted_ts');
      raw.remove('previous_message');
      final stripped = relay.SlackMessage(
        workspace: d.workspace,
        channel: d.channel,
        threadTs: d.threadTs,
        user: d.user,
        eventTs: d.eventTs,
        subtype: d.subtype,
        rawEvent: raw,
      );
      final (_, node) = parseMessageToSlackNode(
        stripped,
        lookup: (_, _) => TurnId.of(Uint8List.fromList([9, 9])),
      );
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('unknown subtypes', () {
    test('an unrecognised subtype falls back to SlackEventRaw', () {
      final event = messageEvent();
      final broadcast = relay.SlackMessage(
        workspace: event.workspace,
        channel: event.channel,
        threadTs: event.threadTs,
        user: event.user,
        text: event.text,
        eventTs: event.eventTs,
        subtype: 'thread_broadcast', // real but unhandled
        rawEvent: event.rawEvent,
      );
      final (_, node) = parseMessageToSlackNode(broadcast);
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('reactions', () {
    relay.SlackReactionAdded reactionAddedEvent({
      String targetTs = '1700000000.000100',
      String reaction = 'thumbsup',
      String eventTs = '1700000100.000500',
    }) =>
        relay.SlackReactionAdded(
          workspace: team,
          channel: channel,
          user: user,
          reaction: reaction,
          targetTs: targetTs,
          eventTs: eventTs,
          rawEvent: {
            'type': 'reaction_added',
            'user': user,
            'reaction': reaction,
            'item': {'type': 'message', 'channel': channel, 'ts': targetTs},
            'event_ts': eventTs,
          },
        );

    relay.SlackReactionRemoved reactionRemovedEvent({
      String targetTs = '1700000000.000100',
      String reaction = 'thumbsup',
      String eventTs = '1700000100.000500',
    }) =>
        relay.SlackReactionRemoved(
          workspace: team,
          channel: channel,
          user: user,
          reaction: reaction,
          targetTs: targetTs,
          eventTs: eventTs,
          rawEvent: {
            'type': 'reaction_removed',
            'user': user,
            'reaction': reaction,
            'item': {'type': 'message', 'channel': channel, 'ts': targetTs},
            'event_ts': eventTs,
          },
        );

    test('reaction_added with a locate-hit becomes a SlackReaction', () {
      final targetId = TurnId.of(Uint8List.fromList([7, 7, 7]));
      final targetPath = SlackThread(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final (path, node) = parseReactionAddedToSlackNode(
        reactionAddedEvent(),
        locate: (String c, String ts) =>
            c == channel && ts == '1700000000.000100'
                ? (id: targetId, path: targetPath)
                : null,
      );

      expect(path, equals(targetPath));
      expect(node, isA<SlackReaction>());
      final r = node as SlackReaction;
      expect(r.target, targetId);
      expect(r.emoji, 'thumbsup');
      expect(r.ts, '1700000100.000500');
      expect(r.by.toString(), 'slack:$team/$user');
    });

    test('reaction_added with no locate falls back to SlackEventRaw', () {
      final (path, node) = parseReactionAddedToSlackNode(reactionAddedEvent());
      // Best-effort SlackThread: targetTs is used as the thread anchor.
      expect(path.threadTs, '1700000000.000100');
      expect(node, isA<SlackEventRaw>());
    });

    test('reaction_added with a locate-miss falls back to SlackEventRaw', () {
      final (_, node) = parseReactionAddedToSlackNode(
        reactionAddedEvent(),
        locate: (_, _) => null,
      );
      expect(node, isA<SlackEventRaw>());
    });

    test(
        'parseReactionRemovedToWithdraw with a locate+findReaction hit '
        'returns the Withdraw', () {
      final messageId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final reactionId = TurnId.of(Uint8List.fromList([4, 5, 6]));
      final path = SlackThread(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final out = parseReactionRemovedToWithdraw(
        reactionRemovedEvent(),
        locate: (String c, String ts) =>
            c == channel ? (id: messageId, path: path) : null,
        findReaction: ({
          required TurnId target,
          required String emoji,
          required ActorId by,
        }) =>
            target == messageId && emoji == 'thumbsup' ? reactionId : null,
      );
      expect(out, isNotNull);
      final (resolvedPath, withdraw) = out!;
      expect(resolvedPath, equals(path));
      expect(withdraw.target, reactionId);
      expect(withdraw.by.toString(), 'slack:$team/$user');
    });

    test('parseReactionRemovedToWithdraw returns null on a locate-miss', () {
      final out = parseReactionRemovedToWithdraw(
        reactionRemovedEvent(),
        locate: (_, _) => null,
        findReaction: ({
          required TurnId target,
          required String emoji,
          required ActorId by,
        }) =>
            TurnId.of(Uint8List.fromList([9])),
      );
      expect(out, isNull);
    });

    test('parseReactionRemovedToWithdraw returns null when findReaction misses',
        () {
      final messageId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final path = SlackThread(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final out = parseReactionRemovedToWithdraw(
        reactionRemovedEvent(),
        locate: (_, _) => (id: messageId, path: path),
        findReaction: ({
          required TurnId target,
          required String emoji,
          required ActorId by,
        }) =>
            null,
      );
      expect(out, isNull);
    });
  });

  group('round-trip through the receiver', () {
    test('a parsed SlackMessage writes to the mirror and emits wantsTurn',
        () {
      final mirror = InMemorySlackMirror();
      final selfActor =
          SlackActorId.forWorkspace(workspaceId: team, userId: 'UBOT');
      final receiver = SlackReceiver(mirror: mirror, selfActor: selfActor);

      final (path, node) = parseMessageToSlackNode(
        messageEvent(mention: true),
      );
      final record = receiver.receive(path, node);

      expect(record.wantsTurn, isTrue);
      expect(record.epoch, 1);
      expect(mirror.nodeAt(record.mirroredAs), isNotNull);
    });
  });
}
