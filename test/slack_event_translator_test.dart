import 'dart:convert';
import 'dart:typed_data';

import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict;
import 'package:is_content_id/is_content_id.dart' show ObjectId;
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
}) => relay.SlackMessage(
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
  RepliesInSlackConversation(:final channel, :final thread) =>
    thread == null ? channel.value : '${channel.value}/${thread.value}',
  _ => null,
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
    final reply = m.replyEndpoint as RepliesInSlackConversation;
    expect(reply.origin, slackReplyOrigin);
    expect(replyTo(m), '$channel/1800000001.000100');
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

  test('a mention, delivered as app_mention and message, has one key', () {
    final [a, b] = fold([
      said(
        ts: '1800000003.000100',
        text: '<@U0BOT> e2e please',
        channelType: null,
      ),
      said(ts: '1800000003.000100', text: '<@U0BOT> e2e please'),
    ]);
    final (ma, mb) = (a as MessageSaid, b as MessageSaid);
    expect(ma.key, mb.key);
    expect(ma.addressInExternalSystem, mb.addressInExternalSystem);
    expect(ma.node.text, 'e2e please');
  });

  test('a DM is one address inside none', () {
    final [t] = fold([
      said(
        ts: '1800000004.000100',
        inChannel: dm,
        channelType: relay.SlackChannelType.im,
      ),
    ]);
    final m = t as MessageSaid;
    expect(m.addressInExternalSystem.value, 'slack:$dm');
    expect(m.containingAddress, isNull);
    expect(replyTo(m), dm);
  });

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
