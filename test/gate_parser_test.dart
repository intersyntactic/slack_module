import 'dart:convert';
import 'dart:typed_data';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

const team = 'T123';
const channel = 'C999';
const user = 'U999';

Map<String, dynamic> messageDoorbell({
  String text = 'hello',
  String eventTs = '1700000000.000100',
  String? rawThreadTs,
  String eventName = 'slack_message',
}) =>
    {
      'event': eventName,
      'team': team,
      'channel': channel,
      'thread_ts': rawThreadTs ?? eventTs,
      'user': user,
      'text': text,
      'event_ts': eventTs,
      'subtype': null,
      'raw_thread_ts': rawThreadTs,
      'raw_event': {
        'type': eventName == 'slack_mention' ? 'app_mention' : 'message',
        'channel': channel,
        'user': user,
        'ts': eventTs,
        'thread_ts': ?rawThreadTs,
        'text': text,
      },
    };

Map<String, dynamic> editDoorbell({
  String editTs = '1700000005.000200',
  String newText = 'hello (edited)',
  String previousTs = '1700000000.000100',
  String anchor = '1700000000.000100',
}) =>
    {
      'event': 'slack_message',
      'team': team,
      'channel': channel,
      'thread_ts': anchor,
      'user': null,
      'text': null,
      'event_ts': editTs,
      'subtype': 'message_changed',
      'raw_thread_ts': null,
      'raw_event': {
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
    };

Map<String, dynamic> deleteDoorbell({
  String deleteTs = '1700000006.000300',
  String deletedTs = '1700000000.000100',
  String anchor = '1700000000.000100',
}) =>
    {
      'event': 'slack_message',
      'team': team,
      'channel': channel,
      'thread_ts': anchor,
      'user': user,
      'text': null,
      'event_ts': deleteTs,
      'subtype': 'message_deleted',
      'raw_thread_ts': null,
      'raw_event': {
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
    };

void main() {
  group('plain messages and mentions', () {
    test('a top-level app_mention parses to a SlackMessage', () {
      final (path, node) = parseDoorbellToSlackNode(
        messageDoorbell(eventName: 'slack_mention'),
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
      // Top-level mention: raw_thread_ts is null, so SlackMessage.threadTs is
      // null. The journey-path anchor equals the message's own ts.
      expect(m.threadTs, isNull);
    });

    test(
        'a reply inside an existing thread carries raw_thread_ts through to '
        'SlackMessage.threadTs', () {
      final (path, node) = parseDoorbellToSlackNode(
        messageDoorbell(
          eventTs: '1700000050.000400',
          rawThreadTs: '1700000000.000100',
        ),
      );

      expect(path.threadTs, '1700000000.000100'); // anchor is the thread head
      final m = node as SlackMessage;
      expect(m.ts, '1700000050.000400');
      expect(m.threadTs, '1700000000.000100');
    });

    test('a slash command doorbell is refused (not this parser\'s concern)',
        () {
      expect(
        () => parseDoorbellToSlackNode({
          'event': 'slack_command',
          'team': team,
          'channel': channel,
          'thread_ts': 'x',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a message doorbell missing text falls back to SlackEventRaw', () {
      final doorbell = messageDoorbell()..['text'] = null;
      final (_, node) = parseDoorbellToSlackNode(doorbell);
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('edits', () {
    test('a message_changed resolved by lookup becomes a SlackEdit', () {
      final priorId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final (path, node) = parseDoorbellToSlackNode(
        editDoorbell(),
        lookup: (p, ts) =>
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
      final (_, node) = parseDoorbellToSlackNode(editDoorbell());
      expect(node, isA<SlackEventRaw>());
      final r = node as SlackEventRaw;
      expect(r.slackEventType, 'message');
      // Faithful mirror: the raw payload is the whole inner event.
      final decoded = jsonDecode(r.rawPayload) as Map;
      expect(decoded['subtype'], 'message_changed');
    });

    test('a message_changed with a lookup that returns null falls back to raw',
        () {
      final (_, node) = parseDoorbellToSlackNode(
        editDoorbell(),
        lookup: (_, _) => null,
      );
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('tombstones', () {
    test('a message_deleted resolved by lookup becomes a SlackTombstone', () {
      final targetId = TurnId.of(Uint8List.fromList([4, 5, 6]));
      final (_, node) = parseDoorbellToSlackNode(
        deleteDoorbell(),
        lookup: (p, ts) =>
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
      final (_, node) = parseDoorbellToSlackNode(deleteDoorbell());
      expect(node, isA<SlackEventRaw>());
      final r = node as SlackEventRaw;
      expect(r.slackEventType, 'message');
    });

    test(
        'a message_deleted missing both deleted_ts and previous_message falls '
        'back to SlackEventRaw', () {
      final d = deleteDoorbell();
      final raw = Map<String, dynamic>.from(d['raw_event'] as Map);
      raw.remove('deleted_ts');
      raw.remove('previous_message');
      d['raw_event'] = raw;
      final (_, node) = parseDoorbellToSlackNode(
        d,
        lookup: (_, _) => TurnId.of(Uint8List.fromList([9, 9])),
      );
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('unknown subtypes', () {
    test('an unrecognised subtype falls back to SlackEventRaw', () {
      final d = messageDoorbell();
      d['subtype'] = 'thread_broadcast'; // real but unhandled
      final (_, node) = parseDoorbellToSlackNode(d);
      expect(node, isA<SlackEventRaw>());
    });
  });

  group('reactions', () {
    Map<String, dynamic> reactionDoorbell({
      String eventName = 'slack_reaction_added',
      String targetTs = '1700000000.000100',
      String reaction = 'thumbsup',
      String eventTs = '1700000100.000500',
    }) =>
        {
          'event': eventName,
          'team': team,
          'channel': channel,
          'thread_ts': null,
          'user': user,
          'reaction': reaction,
          'target_ts': targetTs,
          'event_ts': eventTs,
          'raw_event': {
            'type': eventName == 'slack_reaction_added'
                ? 'reaction_added'
                : 'reaction_removed',
            'user': user,
            'reaction': reaction,
            'item': {
              'type': 'message',
              'channel': channel,
              'ts': targetTs,
            },
            'event_ts': eventTs,
          },
        };

    test('slack_reaction_added with a locate-hit becomes a SlackReaction', () {
      final targetId = TurnId.of(Uint8List.fromList([7, 7, 7]));
      final targetPath = JourneyId(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final (path, node) = parseDoorbellToSlackNode(
        reactionDoorbell(),
        locate: (c, ts) =>
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

    test('slack_reaction_added with no locate falls back to SlackEventRaw', () {
      final (path, node) = parseDoorbellToSlackNode(reactionDoorbell());
      // Best-effort JourneyId: target_ts is used as the thread anchor.
      expect(path.threadTs, '1700000000.000100');
      expect(node, isA<SlackEventRaw>());
    });

    test('slack_reaction_added with a locate-miss falls back to SlackEventRaw',
        () {
      final (_, node) = parseDoorbellToSlackNode(
        reactionDoorbell(),
        locate: (_, _) => null,
      );
      expect(node, isA<SlackEventRaw>());
    });

    test('slack_reaction_removed is refused by the SlackNode parser', () {
      expect(
        () => parseDoorbellToSlackNode(
          reactionDoorbell(eventName: 'slack_reaction_removed'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
        'parseDoorbellToWithdraw with a locate+findReaction hit returns the '
        'Withdraw', () {
      final messageId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final reactionId = TurnId.of(Uint8List.fromList([4, 5, 6]));
      final path = JourneyId(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final out = parseDoorbellToWithdraw(
        reactionDoorbell(eventName: 'slack_reaction_removed'),
        locate: (c, ts) =>
            c == channel ? (id: messageId, path: path) : null,
        findReaction: ({required target, required emoji, required by}) =>
            target == messageId && emoji == 'thumbsup' ? reactionId : null,
      );
      expect(out, isNotNull);
      final (resolvedPath, withdraw) = out!;
      expect(resolvedPath, equals(path));
      expect(withdraw.target, reactionId);
      expect(withdraw.by.toString(), 'slack:$team/$user');
    });

    test('parseDoorbellToWithdraw returns null on a locate-miss', () {
      final out = parseDoorbellToWithdraw(
        reactionDoorbell(eventName: 'slack_reaction_removed'),
        locate: (_, _) => null,
        findReaction: ({required target, required emoji, required by}) =>
            TurnId.of(Uint8List.fromList([9])),
      );
      expect(out, isNull);
    });

    test('parseDoorbellToWithdraw returns null when findReaction misses', () {
      final messageId = TurnId.of(Uint8List.fromList([1, 2, 3]));
      final path = JourneyId(
        workspace: team,
        channel: channel,
        threadTs: '1700000000.000100',
      );
      final out = parseDoorbellToWithdraw(
        reactionDoorbell(eventName: 'slack_reaction_removed'),
        locate: (_, _) => (id: messageId, path: path),
        findReaction: ({required target, required emoji, required by}) => null,
      );
      expect(out, isNull);
    });

    test('parseDoorbellToWithdraw refuses a non-removed event', () {
      expect(
        () => parseDoorbellToWithdraw(
          reactionDoorbell(eventName: 'slack_reaction_added'),
          locate: (_, _) => null,
          findReaction: ({required target, required emoji, required by}) =>
              null,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('round-trip through the receiver', () {
    test('a parsed SlackMessage writes to the mirror and emits wantsTurn',
        () {
      final mirror = InMemorySlackMirror();
      final selfActor =
          SlackActorId.forWorkspace(workspaceId: team, userId: 'UBOT');
      final receiver = SlackReceiver(mirror: mirror, selfActor: selfActor);

      final (path, node) = parseDoorbellToSlackNode(
        messageDoorbell(eventName: 'slack_mention'),
      );
      final record = receiver.receive(path, node);

      expect(record.wantsTurn, isTrue);
      expect(record.epoch, 1);
      expect(mirror.headFor(path), record.mirroredAs);
    });
  });
}
