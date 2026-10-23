import 'dart:convert';

import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:test/test.dart';

/// A fake sender that records what it got and returns programmed responses.
class FakeSender {
  final Queue<SlackHttpResponse> responses = Queue();
  final List<SlackHttpRequest> seen = [];

  void respondOk(Map<String, dynamic> payload) {
    responses.add(SlackHttpResponse(
      statusCode: 200,
      headers: const {},
      body: jsonEncode({'ok': true, ...payload}),
    ));
  }

  void respondError(String error) {
    responses.add(SlackHttpResponse(
      statusCode: 200,
      headers: const {},
      body: jsonEncode({'ok': false, 'error': error}),
    ));
  }

  void respondRateLimit({int retryAfter = 1}) {
    responses.add(SlackHttpResponse(
      statusCode: 429,
      headers: {'retry-after': '$retryAfter'},
      body: '',
    ));
  }

  SlackSend get send => (req) async {
        seen.add(req);
        if (responses.isEmpty) {
          throw StateError('no programmed response for ${req.method} ${req.url}');
        }
        return responses.removeFirst();
      };
}

class Queue<T> {
  final _list = <T>[];
  bool get isEmpty => _list.isEmpty;
  void add(T x) => _list.add(x);
  T removeFirst() => _list.removeAt(0);
}

void main() {
  group('SlackClient — call shape', () {
    test('chatPostMessage sends JSON with bearer auth and returns ts', () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      fake.respondOk({'ts': '1700000000.000500'});

      final ts = await client.chatPostMessage(
        channel: 'C1',
        text: 'hello',
        threadTs: '1700000000.000100',
      );
      expect(ts, '1700000000.000500');

      final req = fake.seen.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), endsWith('/chat.postMessage'));
      expect(req.headers['Authorization'], 'Bearer xoxb-X');
      expect(req.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(utf8.decode(req.body)), {
        'channel': 'C1',
        'text': 'hello',
        'thread_ts': '1700000000.000100',
      });
    });

    test('conversationsReplies pages through next_cursor', () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      fake.respondOk({
        'messages': [
          {'ts': '1', 'text': 'a'},
          {'ts': '2', 'text': 'b'},
        ],
        'response_metadata': {'next_cursor': 'next-page'},
      });
      fake.respondOk({
        'messages': [
          {'ts': '3', 'text': 'c'},
        ],
      });

      final messages = await client.conversationsReplies(
        channel: 'C1',
        threadTs: '1',
      );
      expect(messages.map((m) => m['text']), ['a', 'b', 'c']);
      expect(fake.seen, hasLength(2));
      expect(fake.seen[0].url.queryParameters['cursor'], isNull);
      expect(fake.seen[1].url.queryParameters['cursor'], 'next-page');
    });

    test('an API error becomes a SlackApiError, not a silent "ok"', () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      fake.respondError('channel_not_found');
      await expectLater(
        client.chatPostMessage(channel: 'C_BAD', text: 'x'),
        throwsA(isA<SlackApiError>()
            .having((e) => e.error, 'error', 'channel_not_found')),
      );
    });

    test('429 surfaces Retry-After', () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      fake.respondRateLimit(retryAfter: 3);
      await expectLater(
        client.chatUpdate(channel: 'C1', ts: '1', text: 'x'),
        throwsA(isA<SlackApiError>()
            .having((e) => e.retryAfterSeconds, 'retryAfter', 3)
            .having((e) => e.error, 'error', 'rate_limited')),
      );
    });
  });

  group('SlackMessageStream — pacing and final flush', () {
    test('close flushes the final buffer even without a timer elapsing',
        () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      // open() posts, then each flush updates. Clock stays frozen so no
      // intermediate flush fires via the Timer.
      fake.respondOk({'ts': '1700000000.000500'}); // chat.postMessage
      fake.respondOk({}); // chat.update at close

      final at = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final stream = await SlackMessageStream.open(
        client: client,
        channel: 'C1',
        threadTs: '1700000000.000100',
        initialText: '…',
        now: () => at,
      );
      stream.append('hello ');
      stream.append('world');
      await stream.close();

      final posts = fake.seen.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(2));
      final update = jsonDecode(utf8.decode(posts.last.body)) as Map;
      expect(update['text'], '…hello world');
      expect(update['channel'], 'C1');
      expect(update['ts'], '1700000000.000500');
    });

    test('no update is sent when nothing was appended', () async {
      final fake = FakeSender();
      final client = SlackClient(token: 'xoxb-X', sender: fake.send);
      fake.respondOk({'ts': '1700000000.000500'});

      final stream = await SlackMessageStream.open(
        client: client,
        channel: 'C1',
        initialText: 'done',
        now: () => DateTime.utc(2026, 10, 23, 12, 0, 0),
      );
      await stream.close();
      // Only the opening post happened; close saw the buffer already matched
      // what we last flushed, so no second call.
      expect(fake.seen.where((r) => r.method == 'POST'), hasLength(1));
    });
  });
}
