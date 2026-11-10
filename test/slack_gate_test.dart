import 'dart:convert';

import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:test/test.dart';

const secret = 'correct horse battery staple';
const team = 'T123';
final now = DateTime.utc(2026, 10, 23, 12, 0, 0);
final ts = (now.millisecondsSinceEpoch ~/ 1000).toString();

SlackSourceSpec spec({Set<String>? allow}) => SlackSourceSpec(
      signingSecret: secret,
      teamIdAllowlist: allow ?? const {team},
    );

Map<String, String> signedHeaders(
  List<int> body, {
  String? secretUsed,
  String? tsOverride,
}) {
  final useTs = tsOverride ?? ts;
  return {
    'X-Slack-Request-Timestamp': useTs,
    'X-Slack-Signature':
        'v0=${slackSignBody(secretUsed ?? secret, useTs, body)}',
  };
}

List<int> jsonBody(Map<String, dynamic> payload) =>
    utf8.encode(jsonEncode(payload));

List<int> formBody(Map<String, String> payload) =>
    utf8.encode(payload.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&'));

Map<String, dynamic> appMention({
  String channel = 'C999',
  String user = 'U999',
  String tsVal = '1700000000.000100',
  String? threadTs,
}) =>
    {
      'type': 'event_callback',
      'team_id': team,
      'event': {
        'type': 'app_mention',
        'channel': channel,
        'user': user,
        'ts': tsVal,
        'thread_ts': ?threadTs,
      },
    };

SlackGateDecision run({
  Map<String, String>? headers,
  List<int>? body,
  String contentType = 'application/json',
  SlackSourceSpec? s,
  DateTime? at,
  bool Function(String)? hasSeen,
}) {
  final b = body ?? jsonBody(appMention());
  return slackGate(
    spec: s ?? spec(),
    headers: headers ?? signedHeaders(b),
    body: b,
    contentType: contentType,
    now: at ?? now,
    hasSeen: hasSeen,
  );
}

void main() {
  group('authentication', () {
    test('a correctly signed app_mention triggers', () {
      final d = run();
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['event'], 'slack_mention');
      expect(d.message?['channel'], 'C999');
      expect(d.message?['thread_ts'], '1700000000.000100');
      expect(d.message?['team'], team);
    });

    test('a body signed with the wrong secret is rejected', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body, secretUsed: 'nope'),
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('mismatch'));
    });

    test('a tampered body is rejected even with a well-formed signature', () {
      final signed = jsonBody(appMention());
      final headers = signedHeaders(signed);
      final tampered = jsonBody(appMention(user: 'U_INJECTED'));
      final d = run(headers: headers, body: tampered);
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('mismatch'));
    });

    test('a missing signature header is rejected', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: {'X-Slack-Request-Timestamp': ts},
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('x-slack-signature'));
    });

    test('a bare digest with no v0= prefix is rejected', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': ts,
          'X-Slack-Signature': slackSignBody(secret, ts, body),
        },
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('prefix'));
    });

    test('an empty signing secret is a configuration refusal', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        s: const SlackSourceSpec(signingSecret: ''),
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('not configured'));
    });
  });

  group('timestamp window', () {
    test('a timestamp more than 5 minutes in the past is rejected', () {
      final oldTs = (now
                  .subtract(const Duration(minutes: 6))
                  .millisecondsSinceEpoch ~/
              1000)
          .toString();
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body, tsOverride: oldTs),
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('off'));
    });

    test('a timestamp from the future is rejected the same way', () {
      final futureTs = (now
                  .add(const Duration(minutes: 10))
                  .millisecondsSinceEpoch ~/
              1000)
          .toString();
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body, tsOverride: futureTs),
      );
      expect(d.outcome, SlackGateOutcome.reject);
    });

    test('a non-integer timestamp is rejected', () {
      final body = jsonBody(appMention());
      final headers = signedHeaders(body);
      headers['X-Slack-Request-Timestamp'] = 'not-a-number';
      final d = run(body: body, headers: headers);
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('integer'));
    });
  });

  group('replay cache', () {
    test('a signature already seen is ignored, not re-triggered', () {
      final d = run(hasSeen: (_) => true);
      expect(d.outcome, SlackGateOutcome.ignore);
      expect(d.reason, 'replay');
    });

    test('digest is returned on both trigger and ignore for cache insertion',
        () {
      final triggered = run();
      final replayed = run(hasSeen: (_) => true);
      expect(triggered.digest, isNotNull);
      expect(replayed.digest, isNotNull);
      expect(triggered.digest, replayed.digest);
    });
  });

  group('url_verification', () {
    test('a handshake returns the challenge', () {
      final body = jsonBody({
        'type': 'url_verification',
        'challenge': 'abc123',
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.urlVerification);
      expect(d.challenge, 'abc123');
    });

    test('a handshake missing the challenge is rejected', () {
      final body = jsonBody({'type': 'url_verification'});
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('challenge'));
    });
  });

  group('event_callback', () {
    test('app_mention in a thread uses thread_ts as the anchor', () {
      final body = jsonBody(appMention(threadTs: '1699999999.000050'));
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['thread_ts'], '1699999999.000050');
    });

    test('a message (non-mention) wakes as slack_message', () {
      final body = jsonBody({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'message',
          'channel': 'D777',
          'user': 'U1',
          'ts': '1700000000.0',
        },
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['event'], 'slack_message');
    });

    test('reaction_added on a message triggers slack_reaction_added', () {
      final body = jsonBody({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'reaction_added',
          'user': 'U42',
          'reaction': 'thumbsup',
          'item': {
            'type': 'message',
            'channel': 'C999',
            'ts': '1700000000.000100',
          },
          'event_ts': '1700000500.000700',
        },
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['event'], 'slack_reaction_added');
      expect(d.message?['channel'], 'C999');
      expect(d.message?['target_ts'], '1700000000.000100');
      expect(d.message?['event_ts'], '1700000500.000700');
      expect(d.message?['reaction'], 'thumbsup');
      expect(d.message?['user'], 'U42');
      // No thread_ts in a reaction event — the parser resolves the journey
      // from the mirror.
      expect(d.message?['thread_ts'], isNull);
    });

    test('reaction_removed on a message triggers slack_reaction_removed', () {
      final body = jsonBody({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'reaction_removed',
          'user': 'U42',
          'reaction': 'thumbsup',
          'item': {
            'type': 'message',
            'channel': 'C999',
            'ts': '1700000000.000100',
          },
          'event_ts': '1700000600.000800',
        },
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['event'], 'slack_reaction_removed');
      expect(d.message?['target_ts'], '1700000000.000100');
    });

    test('reaction on a non-message item is ignored, not rejected', () {
      final body = jsonBody({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'reaction_added',
          'user': 'U42',
          'reaction': 'thumbsup',
          'item': {'type': 'file', 'file': 'F1'},
          'event_ts': '1700000500.000700',
        },
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.ignore);
    });

    test('a quiet event (channel_created) is ignored, not rejected', () {
      final body = jsonBody({
        'type': 'event_callback',
        'team_id': team,
        'event': {'type': 'channel_created'},
      });
      final d = run(body: body, headers: signedHeaders(body));
      expect(d.outcome, SlackGateOutcome.ignore);
    });
  });

  group('slash commands', () {
    test('/model with a value triggers slack_command with the text', () {
      final body = formBody({
        'team_id': team,
        'channel_id': 'C1',
        'user_id': 'U1',
        'command': '/model',
        'text': 'claude-opus-4-7',
        'trigger_id': 'tr1',
        'response_url': 'https://hooks.slack.com/x',
      });
      final d = run(
        body: body,
        headers: signedHeaders(body),
        contentType: 'application/x-www-form-urlencoded',
      );
      expect(d.outcome, SlackGateOutcome.trigger);
      expect(d.message?['event'], 'slack_command');
      expect(d.message?['command'], '/model');
      expect(d.message?['text'], 'claude-opus-4-7');
      expect(d.message?['trigger_id'], 'tr1');
    });

    test('an unknown slash command is ignored, not rejected', () {
      final body = formBody({
        'team_id': team,
        'channel_id': 'C1',
        'user_id': 'U1',
        'command': '/unknown',
        'text': '',
      });
      final d = run(
        body: body,
        headers: signedHeaders(body),
        contentType: 'application/x-www-form-urlencoded',
      );
      expect(d.outcome, SlackGateOutcome.ignore);
    });
  });

  group('workspace allowlist', () {
    test('a team not in the allowlist is rejected AFTER signature checks', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body),
        s: spec(allow: const {'T_OTHER'}),
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('allowlist'));
    });

    test('an empty allowlist accepts any correctly signed workspace', () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body),
        s: spec(allow: const {}),
      );
      expect(d.outcome, SlackGateOutcome.trigger);
    });
  });

  group('content type', () {
    test('an unexpected content type is rejected after the signature holds',
        () {
      final body = jsonBody(appMention());
      final d = run(
        body: body,
        headers: signedHeaders(body),
        contentType: 'text/plain',
      );
      expect(d.outcome, SlackGateOutcome.reject);
      expect(d.reason, contains('content type'));
    });
  });
}
