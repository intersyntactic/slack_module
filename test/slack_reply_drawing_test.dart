import 'dart:convert';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show encodeReplyEndpoint;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:test/test.dart';

import '../bin/slack_reply_drawing.dart' as program;

const channel = 'C0DEPLOYS';
const ourBot = 'U0BOT';
const trajectory =
    '0101010101010101010101010101010101010101010101010101010101010101';

/// slack-reply-drawing's contract with the loop that runs it: the requests
/// it prints for a reply, and the ids it reads back from what they posted.
void main() {
  final endpoint = jsonEncode(
    encodeReplyEndpoint(
      slackReplyEndpoint(
        SlackChannelId.parse(channel)!,
        thread: SlackMessageTimestamp.parse('1800000001.000100'),
      ),
    ),
  );

  Future<(int, String, String)> run(List<String> args, String stdin) async {
    final (out, err) = (StringBuffer(), StringBuffer());
    final code = await program.run(
      args,
      input: Stream.value(utf8.encode(stdin)),
      out: out,
      err: err,
    );
    return (code, out.toString(), err.toString());
  }

  Future<(int, String, String)> draw(String text) => run([
    '--reply-endpoint',
    endpoint,
    '--sign-in',
    'agent-slack',
    '--trajectory',
    trajectory,
  ], text);

  Future<Object?> posted(List<WebResponse> responses) async {
    final (code, out, err) = await run([
      'posted',
      '--reply-endpoint',
      endpoint,
    ], jsonEncode([for (final r in responses) encodeWebResponse(r)]));
    expect((code, err), (0, ''));
    return jsonDecode(out);
  }

  WebResponse ok(String ts) =>
      WebResponse(status: 200, body: TextBody('{"ok":true,"ts":"$ts"}'));

  test(
    'it prints the reply as signed requests that keep their answer',
    () async {
      final (code, out, err) = await draw('step 2: Bea, did the email arrive?');
      expect((code, err), (0, ''));
      final [r] = [
        for (final j in jsonDecode(out) as List<Object?>)
          decodeProposedRequest(j),
      ];
      expect(
        '${r.origin}${r.path.value}',
        'https://slack.com/api/chat.postMessage',
      );
      expect(r.signIn?.name, 'agent-slack');
      expect(r.keep, BodyToKeep.text);
      expect(jsonDecode(r.body!), {
        'channel': channel,
        'thread_ts': '1800000001.000100',
        'text': 'step 2: Bea, did the email arrive?',
      });
    },
  );

  test('the id an ask is posted as is the id a reaction on it names', () async {
    final outcome = await posted([ok('1800000002.000200')]);
    expect(outcome, {
      'kind': 'ran',
      'output': ['$channel|1800000002.000200'],
    });

    // Our bot's post of that message comes back from Slack, then a ✅ on it.
    final events = <relay.SlackEvent>[
      relay.SlackMessage(
        workspace: 'T0TEAM',
        channel: channel,
        threadTs: '1800000001.000100',
        rawThreadTs: '1800000001.000100',
        user: ourBot,
        botId: 'B0BOT',
        text: 'step 2: Bea, did the email arrive?',
        eventTs: '1800000002.000200',
        channelType: relay.SlackChannelType.channel,
        deliveredForUser: ourBot,
      ),
      relay.SlackReactionAdded(
        workspace: 'T0TEAM',
        channel: channel,
        user: 'U0BEA',
        reaction: 'white_check_mark',
        targetTs: '1800000002.000200',
        eventTs: '1800000003.000300',
        deliveredForUser: ourBot,
      ),
    ];
    final translator = SlackEventTranslator(
      parse: (bytes) => events[int.parse(utf8.decode(bytes))],
    );
    var state = translator.start;
    TranslatedEvent? last;
    for (var i = 0; i < events.length; i++) {
      final (kind, body) = encodeRelayedEvent(
        slackEventSource,
        at: DateTime.utc(2026, 11, 28),
        bytes: Uint8List.fromList(utf8.encode('$i')),
      );
      (state, last) = translator.step(
        state,
        RelayedEvent.read(ObjectId.of(body), kind, body)!,
      );
    }
    expect(
      (last! as ShownMessageJudged).to.value,
      '$channel|1800000002.000200',
    );
  });

  test(
    'a long reply posted as several messages gives every id, in order',
    () async {
      expect(await posted([ok('1800000002.000200'), ok('1800000002.000300')]), {
        'kind': 'ran',
        'output': ['$channel|1800000002.000200', '$channel|1800000002.000300'],
      });
    },
  );

  test('Slack refusing the first message posted nothing', () async {
    final refused = WebResponse(
      status: 200,
      body: TextBody('{"ok":false,"error":"not_in_channel"}'),
    );
    expect(await posted([refused]), {
      'kind': 'nothingRan',
      'why': contains('not_in_channel'),
    });
  });

  test(
    'a refusal after a message posted stopped partway, keeping its id',
    () async {
      final refused = WebResponse(
        status: 200,
        body: TextBody('{"ok":false,"error":"msg_too_long"}'),
      );
      expect(await posted([ok('1800000002.000200'), refused]), {
        'kind': 'stoppedPartway',
        'why': contains('msg_too_long'),
        'done': ['$channel|1800000002.000200'],
      });
    },
  );

  test(
    'an answer it cannot read may have posted, so nothing is known done',
    () async {
      expect(await posted([const WebResponse(status: 500)]), {
        'kind': 'stoppedPartway',
        'why': isA<String>(),
        'done': null,
      });
    },
  );

  test('a reply endpoint that is not Slack\'s is a usage error', () async {
    final teams = jsonEncode({
      'case': 'under-web-address',
      'addressPrefix': {
        'origin': 'https://smba.trafficmanager.net',
        'pathPrefix': '/amer/v3/conversations/a/',
      },
    });
    final (code, out, _) = await run([
      'posted',
      '--reply-endpoint',
      teams,
    ], '[]');
    expect((code, out), (64, ''));
  });

  test('no text to say is refused, printing nothing', () async {
    final (code, out, _) = await draw('   ');
    expect((code, out), (65, ''));
  });
}
