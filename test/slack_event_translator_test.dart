import 'dart:convert';
import 'dart:typed_data';

import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict;
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show ConversationKind, RepliesWithPinnedBodyFields;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:test/test.dart';

const team = 'T0TEAM';
const channel = 'C0DEPLOYS';
const dm = 'D0ADA';
const ourBot = 'U0BOT';

/// A message as the relay's parse hands it on.
relay.SlackMessage said({
  required String ts,
  String? threadTs,
  String? user = 'U0ADA',
  String text = 'deployed checkout-v2 to staging, needs e2e',
  String inChannel = channel,
  relay.SlackChannelType? channelType = relay.SlackChannelType.channel,
  relay.SlackMessageSubtype? subtype,
  String? botId,
  String? deliveredForUser = ourBot,
  String? enterprise,
  bool mention = false,
}) => relay.SlackMessage(
  mention: mention,
  workspace: team,
  channel: inChannel,
  threadTs: threadTs ?? ts,
  rawThreadTs: threadTs,
  user: user,
  text: text,
  eventTs: ts,
  subtype: subtype,
  botId: botId,
  channelType: channelType,
  deliveredForUser: deliveredForUser,
  enterprise: enterprise,
);

/// A message our bot posted.
relay.SlackMessage shown(String ts, {String threadTs = '1800000001.000100'}) =>
    said(
      ts: ts,
      threadTs: threadTs,
      user: ourBot,
      botId: 'B0BOT',
      text: 'Step 2: Bea, did the receipt email arrive?',
    );

relay.SlackReactionAdded reacted(
  String emoji,
  String targetTs, {
  String eventTs = '1800000099.000100',
}) => relay.SlackReactionAdded(
  workspace: team,
  channel: channel,
  user: 'U0BEA',
  reaction: emoji,
  targetTs: targetTs,
  eventTs: eventTs,
  deliveredForUser: ourBot,
);

/// Where [e]'s replies go in Slack, `<channel>/<thread>` or `<channel>`;
/// null when it names no Slack conversation.
String? replyTo(AddressedEvent e) => switch (e.replyEndpoint) {
  final RepliesWithPinnedBodyFields to
      when to == slackReplyEndpointFrom(to.pinned.mustEqual) =>
    [
      to.pinned.mustEqual['channel'],
      ?to.pinned.mustEqual['thread_ts'],
    ].join('/'),
  _ => null,
};

/// The endpoint [slackReplyEndpoint] makes for [fields]' channel and
/// thread, to check an endpoint is exactly one it makes; null when [fields]
/// name no Slack channel.
RepliesWithPinnedBodyFields? slackReplyEndpointFrom(
  Map<String, String> fields,
) => switch (SlackChannelId.parse(fields['channel'] ?? '')) {
  final channel? => slackReplyEndpoint(
    channel,
    thread: SlackMessageTimestamp.parse(fields['thread_ts'] ?? ''),
  ),
  null => null,
};

/// [bytes] as the docking station hands them over: recorded as the relay
/// records them and read back from the entry.
RelayedEvent recorded(List<int> bytes) {
  final (kind, body) = encodeRelayedEvent(
    slackEventSource,
    at: DateTime.utc(2026, 11, 24),
    bytes: Uint8List.fromList(bytes),
  );
  return RelayedEvent.read(ObjectId.of(body), kind, body)!;
}

/// Every one of [events], folded from the start as the docking station
/// folds them. The bytes recorded name which event they were.
List<TranslatedEvent> fold(List<relay.SlackEvent> events) {
  final translator = SlackEventTranslator(
    parse: (bytes) => events[int.parse(utf8.decode(bytes))],
  );
  var state = translator.start;
  final out = <TranslatedEvent>[];
  for (var i = 0; i < events.length; i++) {
    final (next, t) = translator.step(state, recorded(utf8.encode('$i')));
    state = next;
    out.add(t);
  }
  return out;
}

void main() {
  test('Slack\'s own bytes, through the relay\'s parse, are said', () {
    const translator = SlackEventTranslator();
    final bytes = utf8.encode(
      jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event_id': 'Ev0DEPLOY',
        'authorizations': [
          {'team_id': team, 'user_id': ourBot, 'is_bot': true},
        ],
        'event': {
          'type': 'message',
          'channel': channel,
          'channel_type': 'channel',
          'user': 'U0ADA',
          'text': 'deployed checkout-v2 to staging, needs e2e',
          'ts': '1800000001.000100',
        },
      }),
    );
    final (_, t) = translator.step(translator.start, recorded(bytes));
    final m = t as MessageSaid;
    expect(m.addressInExternalSystem.value, 'slack:$channel/1800000001.000100');
    expect(m.addressedTo?.value, 'slack:$team/$ourBot');
    expect(m.node.text, 'deployed checkout-v2 to staging, needs e2e');
  });

  test('a channel post is said in its own thread, inside the channel', () {
    final [t] = fold([said(ts: '1800000001.000100')]);
    final m = t as MessageSaid;
    expect(m.addressInExternalSystem.value, 'slack:$channel/1800000001.000100');
    expect(m.containingAddress?.value, 'slack:$channel');
    expect(m.node.author.value, 'slack:$team/U0ADA');
    expect(m.node.source.value, '$channel|1800000001.000100');
    expect(m.key.value, 'message:1800000001.000100');
    expect(m.replyEndpoint?.origin, slackReplyOrigin);
    expect(replyTo(m), '$channel/1800000001.000100');
    expect(m.conversationKind, ConversationKind.publicChannel);
  });

  test('a reply is said, and answered, in the thread it replies in', () {
    final [_, t] = fold([
      said(ts: '1800000001.000100'),
      said(ts: '1800000002.000100', threadTs: '1800000001.000100'),
    ]);
    expect(
      (t as MessageSaid).addressInExternalSystem.value,
      'slack:$channel/1800000001.000100',
    );
    expect(replyTo(t), '$channel/1800000001.000100');
  });

  test('a mention is said once, from its message copy, with its kind', () {
    final [a, b] = fold([
      // app_mention, which Slack sends with no channel type.
      said(
        ts: '1800000003.000100',
        text: '<@U0BOT> e2e please',
        channelType: null,
        mention: true,
      ),
      said(ts: '1800000003.000100', text: '<@U0BOT> e2e please'),
    ]);
    expect(a, isA<NothingToAdmit>());
    final m = b as MessageSaid;
    expect(m.node.text, 'e2e please');
    expect(m.conversationKind, ConversationKind.publicChannel);
  });

  test('each Slack channel type is said as its kind of conversation', () {
    final kinds = {
      relay.SlackChannelType.channel: ConversationKind.publicChannel,
      relay.SlackChannelType.group: ConversationKind.privateChannel,
      relay.SlackChannelType.im: ConversationKind.oneToOne,
      relay.SlackChannelType.appHome: ConversationKind.oneToOne,
      relay.SlackChannelType.mpim: ConversationKind.groupChat,
      null: ConversationKind.notKnown,
    };
    for (final MapEntry(key: type, value: kind) in kinds.entries) {
      final [t] = fold([said(ts: '1800000005.000100', channelType: type)]);
      expect((t as MessageSaid).conversationKind, kind, reason: '$type');
    }
  });

  group('whether a message is for our bot', () {
    WhetherForTheAgent forTheAgent(
      relay.SlackEvent last, [
      List<relay.SlackEvent> before = const [],
    ]) => (fold([...before, last]).last as MessageSaid).forTheAgent;

    test('every message in a DM is', () {
      expect(
        forTheAgent(
          said(
            ts: '1800000004.000100',
            inChannel: dm,
            channelType: relay.SlackChannelType.im,
          ),
        ),
        WhetherForTheAgent.everyMessageHereIsForTheAgent,
      );
    });

    test('a channel message that mentions it anywhere does', () {
      expect(
        forTheAgent(
          said(ts: '1800000005.000100', text: 'staging is up, <@U0BOT> go'),
        ),
        WhetherForTheAgent.mentionsTheAgent,
      );
    });

    test('a reply in a thread our bot posted in replies to it', () {
      expect(
        forTheAgent(
          said(
            ts: '1800000006.000100',
            threadTs: '1800000001.000100',
            text: 'yes, it arrived',
          ),
          [shown('1800000002.000100')],
        ),
        WhetherForTheAgent.repliesToTheAgent,
      );
    });

    test('a reply to our bot\'s top-level post replies to it', () {
      expect(
        forTheAgent(
          said(ts: '1800000008.000100', threadTs: '1800000007.000100'),
          [shown('1800000007.000100', threadTs: '1800000007.000100')],
        ),
        WhetherForTheAgent.repliesToTheAgent,
      );
    });

    test('anything else in a channel, a CI deploy post too, is neither', () {
      expect(
        forTheAgent(
          said(ts: '1800000009.000100', threadTs: '1800000001.000100'),
          [shown('1800000002.000100', threadTs: '1800000099.000100')],
        ),
        WhetherForTheAgent.neitherMentionsNorRepliesToTheAgent,
      );
      expect(
        forTheAgent(said(ts: '1800000010.000100', user: 'U0CI', botId: 'B0CI')),
        WhetherForTheAgent.neitherMentionsNorRepliesToTheAgent,
      );
    });

    test('with no channel type, which may be a DM, it is not known', () {
      expect(
        forTheAgent(said(ts: '1800000011.000100', channelType: null)),
        WhetherForTheAgent.notKnown,
      );
    });
  });

  test(
    'a DM, the app\'s Messages tab included, is one address inside none',
    () {
      for (final type in [
        relay.SlackChannelType.im,
        relay.SlackChannelType.appHome,
      ]) {
        final [t] = fold([
          said(ts: '1800000004.000100', inChannel: dm, channelType: type),
        ]);
        final m = t as MessageSaid;
        expect(m.addressInExternalSystem.value, 'slack:$dm', reason: '$type');
        expect(m.containingAddress, isNull, reason: '$type');
        expect(replyTo(m), dm, reason: '$type');
      }
    },
  );

  test('a CI bot\'s deploy post is said, by that bot', () {
    final [user, webhook] = fold([
      said(ts: '1800000010.000100', user: 'U0CI', botId: 'B0CI'),
      said(
        ts: '1800000011.000100',
        user: null,
        botId: 'B0HOOK',
        subtype: relay.SlackMessageSubtype.botMessage,
      ),
    ]);
    expect((user as MessageSaid).node.author.value, 'slack:$team/U0CI');
    expect((webhook as MessageSaid).node.author.value, 'slack:$team/B0HOOK');
  });

  test('our bot\'s post, and a bot\'s with no recipient named, are not', () {
    final [ours, unknown] = fold([
      shown('1800000012.000100'),
      said(
        ts: '1800000013.000100',
        user: 'U0CI',
        botId: 'B0CI',
        deliveredForUser: null,
      ),
    ]);
    expect(ours, isA<NothingToAdmit>());
    expect(unknown, isA<NothingToAdmit>());
  });

  test('a check on our bot\'s message approves it; a cross holds off', () {
    const step = '1800000005.000100';
    final events = fold([
      shown(step),
      reacted('white_check_mark', step),
      reacted('x', step, eventTs: '1800000099.000200'),
      reacted('thumbsup', step, eventTs: '1800000099.000300'),
    ]);
    final approved = events[1] as ShownMessageJudged;
    expect(approved.verdict, isA<ApprovedVerdict>());
    expect(approved.from.value, 'slack:$team/U0BEA');
    expect(approved.to.value, '$channel|$step');
    expect(
      approved.addressInExternalSystem.value,
      'slack:$channel/1800000001.000100',
    );
    expect(replyTo(approved), '$channel/1800000001.000100');
    expect((events[2] as ShownMessageJudged).verdict, isA<HeldOffVerdict>());
    expect(events[3], isA<NothingToAdmit>());
  });

  test('a check on anyone else\'s message is no verdict', () {
    final [_, t] = fold([
      said(ts: '1800000006.000100', user: 'U0CI', botId: 'B0CI'),
      reacted('white_check_mark', '1800000006.000100'),
    ]);
    expect(t, isA<NothingToAdmit>());
  });

  test('an edit is nothing yet; a reply sent to the channel too is said', () {
    final [edit, broadcast] = fold([
      said(
        ts: '1800000007.000100',
        subtype: relay.SlackMessageSubtype.messageChanged,
      ),
      said(
        ts: '1800000008.000100',
        threadTs: '1800000001.000100',
        subtype: relay.SlackMessageSubtype.threadBroadcast,
      ),
    ]);
    expect(edit, isA<NothingToAdmit>());
    expect(broadcast, isA<MessageSaid>());
  });

  test('in an Enterprise Grid org, people are named by the org', () {
    final [t] = fold([said(ts: '1800000009.000100', enterprise: 'E0ORG')]);
    expect((t as MessageSaid).node.author.value, 'slack:E0ORG/U0ADA');
  });
}
