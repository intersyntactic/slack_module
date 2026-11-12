import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:test/test.dart';

import '../bin/slack_bot.dart';

const secret = 'correct horse battery staple';
const team = 'T123';

/// Opens an HttpServer on an ephemeral port, drives [bot] from it, and tears
/// down automatically at the end of the test's zone.
Future<Uri> _serve(SlackBot bot) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  // Run the request loop in the background; failures surface through the
  // bot's own log, not the test.
  unawaited(() async {
    await for (final req in server) {
      unawaited(bot.handle(req));
    }
  }());
  return Uri.parse('http://127.0.0.1:${server.port}');
}

Future<HttpClientResponse> _post(
  Uri base,
  String path, {
  required String contentType,
  required List<int> body,
  required Map<String, String> headers,
}) async {
  final client = HttpClient();
  addTearDown(client.close);
  final req = await client.postUrl(base.replace(path: path));
  req.headers.contentType = ContentType.parse(contentType);
  headers.forEach(req.headers.set);
  req.add(body);
  return req.close();
}

String _sig(String ts, List<int> body) =>
    'v0=${slackSignBody(secret, ts, body)}';

String _ts(DateTime at) =>
    (at.millisecondsSinceEpoch ~/ 1000).toString();

void main() {
  group('SlackBot HTTP roundtrip', () {
    test('url_verification echoes the challenge', () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final bot = SlackBot(
        spec: const SlackSourceSpec(signingSecret: secret),
        now: () => at,
      );
      final base = await _serve(bot);
      final body = utf8.encode(jsonEncode({
        'type': 'url_verification',
        'challenge': 'xyz',
      }));
      final ts = _ts(at);
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': ts,
          'X-Slack-Signature': _sig(ts, body),
        },
      );
      expect(res.statusCode, 200);
      expect(await res.transform(utf8.decoder).join(), 'xyz');
    });

    test('a correctly signed app_mention is 200 and mirrors + kicks off',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final mirror = InMemorySlackMirror();
      final kickoffs = <KickoffRecord>[];
      final dispatched = Completer<void>();
      final bot = SlackBot(
        spec: SlackSourceSpec(
          signingSecret: secret,
          teamIdAllowlist: const {team},
        ),
        now: () => at,
        mirror: mirror,
        onKickoff: (r) {
          kickoffs.add(r);
          if (!dispatched.isCompleted) dispatched.complete();
        },
      );
      final base = await _serve(bot);
      final body = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'text': 'hi bot',
          'ts': '1700000000.000100',
        },
      }));
      final ts = _ts(at);
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': ts,
          'X-Slack-Signature': _sig(ts, body),
        },
      );
      expect(res.statusCode, 200);
      await dispatched.future.timeout(const Duration(seconds: 2));
      expect(kickoffs, hasLength(1));
      final record = kickoffs.single;
      expect(record.path.workspace, team);
      expect(record.path.channel, 'C1');
      expect(record.path.threadTs, '1700000000.000100');
      expect(record.epoch, 1);
      // Placeholder selfActor, so a real U1 is "someone else" → turn-worthy.
      expect(record.wantsTurn, isTrue);
      final head = mirror.headFor(record.path);
      expect(head, record.mirroredAs);
      final node = mirror.nodeAt(head!);
      expect(node, isA<SlackMessage>());
      expect((node! as SlackMessage).text, 'hi bot');
    });

    test('a wrong signature answers 401 and does not dispatch', () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final kickoffs = <KickoffRecord>[];
      final bot = SlackBot(
        spec: const SlackSourceSpec(signingSecret: secret),
        now: () => at,
        mirror: InMemorySlackMirror(),
        onKickoff: kickoffs.add,
      );
      final base = await _serve(bot);
      final body = utf8.encode(jsonEncode({'type': 'event_callback'}));
      final res = await _post(
        base,
        '/webhook/slack',
        contentType: 'application/json',
        body: body,
        headers: {
          'X-Slack-Request-Timestamp': _ts(at),
          'X-Slack-Signature': 'v0=0000',
        },
      );
      expect(res.statusCode, 401);
      // Give the (should-not-fire) handler a tick to run if the ACK path is
      // broken; if it hasn't fired by now, the gate held.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(kickoffs, isEmpty);
    });

    test('a replay of a correctly signed event is accepted but not re-dispatched',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final kickoffs = <KickoffRecord>[];
      final bot = SlackBot(
        spec: SlackSourceSpec(
          signingSecret: secret,
          teamIdAllowlist: const {team},
        ),
        now: () => at,
        mirror: InMemorySlackMirror(),
        onKickoff: kickoffs.add,
      );
      final base = await _serve(bot);
      final body = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'app_mention',
          'channel': 'C1',
          'user': 'U1',
          'ts': '1700000000.000100',
        },
      }));
      final ts = _ts(at);
      final headers = {
        'X-Slack-Request-Timestamp': ts,
        'X-Slack-Signature': _sig(ts, body),
      };
      final first = await _post(base, '/webhook/slack',
          contentType: 'application/json', body: body, headers: headers);
      expect(first.statusCode, 200);
      // Give the first dispatch time to land before replaying.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final second = await _post(base, '/webhook/slack',
          contentType: 'application/json', body: body, headers: headers);
      expect(second.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(kickoffs, hasLength(1),
          reason: 'replay should ACK 200 but not re-run the pipeline');
    });

    test('an edit resolves its prior turn via the mirror and mints SlackEdit',
        () async {
      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final mirror = InMemorySlackMirror();
      final kickoffs = <KickoffRecord>[];
      final bot = SlackBot(
        spec: SlackSourceSpec(
          signingSecret: secret,
          teamIdAllowlist: const {team},
        ),
        now: () => at,
        mirror: mirror,
        onKickoff: kickoffs.add,
      );
      final base = await _serve(bot);
      final ts = _ts(at);

      // First: a plain message that seeds the thread.
      final firstBody = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'message',
          'channel': 'C1',
          'user': 'U1',
          'text': 'original',
          'ts': '1700000000.000100',
        },
      }));
      final r1 = await _post(base, '/webhook/slack',
          contentType: 'application/json',
          body: firstBody,
          headers: {
            'X-Slack-Request-Timestamp': ts,
            'X-Slack-Signature': _sig(ts, firstBody),
          });
      expect(r1.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Then: an edit of that message. Slack wraps the new state in
      // event.message and the prior state in event.previous_message.
      final editBody = utf8.encode(jsonEncode({
        'type': 'event_callback',
        'team_id': team,
        'event': {
          'type': 'message',
          'subtype': 'message_changed',
          'channel': 'C1',
          'ts': '1700000005.000200',
          'thread_ts': '1700000000.000100',
          'message': {
            'user': 'U1',
            'text': 'revised',
            'ts': '1700000000.000100',
          },
          'previous_message': {
            'user': 'U1',
            'text': 'original',
            'ts': '1700000000.000100',
          },
        },
      }));
      final r2 = await _post(base, '/webhook/slack',
          contentType: 'application/json',
          body: editBody,
          headers: {
            'X-Slack-Request-Timestamp': ts,
            'X-Slack-Signature': _sig(ts, editBody),
          });
      expect(r2.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(kickoffs, hasLength(2));
      final editHead = mirror.nodeAt(kickoffs.last.mirroredAs);
      expect(editHead, isA<SlackEdit>(),
          reason: 'mirror.find(path, previousTs) should resolve, producing '
              'a SlackEdit rather than falling back to SlackEventRaw');
      expect((editHead! as SlackEdit).newText, 'revised');
    });

    test('a path other than /webhook/slack is 404', () async {
      final bot = SlackBot(spec: const SlackSourceSpec(signingSecret: secret));
      final base = await _serve(bot);
      final res = await _post(
        base,
        '/elsewhere',
        contentType: 'application/json',
        body: const [],
        headers: const {},
      );
      expect(res.statusCode, 404);
    });
  });
}
