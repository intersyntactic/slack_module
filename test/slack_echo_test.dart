import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:test/test.dart';

import '../bin/slack_echo.dart';

relay.SlackMessage _message({String? subtype, Map<String, dynamic> rawEvent = const {}}) =>
    relay.SlackMessage(
      workspace: 'T123',
      channel: 'C999',
      threadTs: '1700000000.000100',
      text: 'hello',
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
}
