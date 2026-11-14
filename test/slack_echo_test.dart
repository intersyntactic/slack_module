import 'dart:convert';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:test/test.dart';

import '../bin/slack_echo.dart';

/// A sender that records every `chat.postMessage` call and always answers ok.
class _RecordingSender {
  int postCount = 0;

  SlackSend get send => (req) async {
        if (req.url.pathSegments.last == 'chat.postMessage') postCount++;
        return SlackHttpResponse(
          statusCode: 200,
          headers: const {},
          body: jsonEncode({'ok': true, 'ts': '1700000000.000200'}),
        );
      };
}

relay.SlackMessage _message({
  String? subtype,
  Map<String, dynamic> rawEvent = const {},
  bool mention = false,
  String eventTs = '1700000000.000100',
}) =>
    relay.SlackMessage(
      workspace: 'T123',
      channel: 'C999',
      threadTs: eventTs,
      mention: mention,
      text: 'hello',
      eventTs: eventTs,
      subtype: subtype,
      rawEvent: rawEvent,
    );

void main() {
  test('a plain message from a human is not from a bot', () {
    expect(fromBot(_message()), isFalse);
  });

  test('a message carrying bot_id is from a bot', () {
    expect(fromBot(_message(rawEvent: {'bot_id': 'B123'})), isTrue);
  });

  test('a bot_message subtype is from a bot even without bot_id', () {
    expect(fromBot(_message(subtype: 'bot_message')), isTrue);
  });

  group('Answerer', () {
    test('replies once to a single message', () async {
      final sender = _RecordingSender();
      final answerer = Answerer(SlackClient(token: 't', sender: sender.send));
      await answerer.answer(_message());
      expect(sender.postCount, 1);
    });

    test(
      'an app_mention and a message for the same post reply only once, '
      'regardless of which arrives first',
      () async {
        final sender = _RecordingSender();
        final answerer = Answerer(SlackClient(token: 't', sender: sender.send));
        await answerer.answer(_message(mention: true));
        await answerer.answer(_message(mention: false));
        expect(sender.postCount, 1);
      },
    );

    test('two different posts in the same channel both get a reply', () async {
      final sender = _RecordingSender();
      final answerer = Answerer(SlackClient(token: 't', sender: sender.send));
      await answerer.answer(_message(eventTs: '1700000000.000100'));
      await answerer.answer(_message(eventTs: '1700000000.000200'));
      expect(sender.postCount, 2);
    });

    test('the same post answered again after the dedupe window gets a reply', () async {
      final sender = _RecordingSender();
      var now = DateTime.utc(2026);
      final answerer = Answerer(
        SlackClient(token: 't', sender: sender.send),
        now: () => now,
        answeredFor: const Duration(minutes: 2),
      );
      await answerer.answer(_message());
      now = now.add(const Duration(minutes: 3));
      await answerer.answer(_message());
      expect(sender.postCount, 2);
    });
  });
}
