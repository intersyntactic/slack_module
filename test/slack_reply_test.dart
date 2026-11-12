import 'dart:convert';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:test/test.dart';

final _path = JourneyId(
  workspace: 'T01ABC',
  channel: 'C01',
  threadTs: '1730000000.000100',
);
final _self = ActorId.parse('agent:abc123')!;

class _Queue<T> {
  final _list = <T>[];
  bool get isEmpty => _list.isEmpty;
  void add(T x) => _list.add(x);
  T removeFirst() => _list.removeAt(0);
}

class _FakeSender {
  final _Queue<SlackHttpResponse> responses = _Queue();
  final List<SlackHttpRequest> seen = [];

  void respondPostOk(String ts) {
    responses.add(SlackHttpResponse(
      statusCode: 200,
      headers: const {},
      body: jsonEncode({'ok': true, 'ts': ts}),
    ));
  }

  void respondError(String error) {
    responses.add(SlackHttpResponse(
      statusCode: 200,
      headers: const {},
      body: jsonEncode({'ok': false, 'error': error}),
    ));
  }

  SlackSend get send => (req) async {
        seen.add(req);
        if (responses.isEmpty) {
          throw StateError('no programmed response');
        }
        return responses.removeFirst();
      };
}

DateTime _fixedNow() => DateTime.utc(2026, 11, 10, 10, 0, 0);

void main() {
  group('SlackReply', () {
    test('write-ahead: mirror has the node before Slack is called', () async {
      final mirror = InMemorySlackMirror();
      final sender = _FakeSender()..respondPostOk('1762790400.000000');
      final client = SlackClient(token: 'xoxb', sender: sender.send);
      final reply = SlackReply(
        mirror: mirror,
        client: client,
        selfActor: _self,
        now: _fixedNow,
      );

      expect(mirror.headFor(_path), isNull);
      final out = await reply.post(path: _path, text: 'hi');

      expect(out.posted, isTrue);
      expect(out.postedTs, '1762790400.000000');
      expect(mirror.headFor(_path), equals(out.mirroredAs));
      final node = mirror.nodeAt(out.mirroredAs);
      expect(node, isA<SlackMessage>());
      expect((node as SlackMessage).by, equals(_self));
      expect(node.text, 'hi');
    });

    test('Slack failure leaves the mirror node in place', () async {
      final mirror = InMemorySlackMirror();
      final sender = _FakeSender()..respondError('channel_not_found');
      final client = SlackClient(token: 'xoxb', sender: sender.send);
      final reply = SlackReply(
        mirror: mirror,
        client: client,
        selfActor: _self,
        now: _fixedNow,
      );

      final out = await reply.post(path: _path, text: 'hi');

      expect(out.posted, isFalse);
      expect(out.postedTs, isNull);
      expect(out.error?.error, 'channel_not_found');
      expect(mirror.headFor(_path), equals(out.mirroredAs),
          reason:
              'Write-ahead: the mirror records intent; a failed post is '
              'an annotation on the chain, not an erasure.');
    });

    test('chat.postMessage is called with path channel + thread_ts', () async {
      final mirror = InMemorySlackMirror();
      final sender = _FakeSender()..respondPostOk('1.0');
      final client = SlackClient(token: 'xoxb', sender: sender.send);
      final reply = SlackReply(
        mirror: mirror,
        client: client,
        selfActor: _self,
        now: _fixedNow,
      );

      await reply.post(path: _path, text: 'hello');

      expect(sender.seen, hasLength(1));
      final body = jsonDecode(utf8.decode(sender.seen.single.body)) as Map;
      expect(body['channel'], 'C01');
      expect(body['thread_ts'], '1730000000.000100');
      expect(body['text'], 'hello');
    });

    test('epoch flows through to the outcome', () async {
      final mirror = InMemorySlackMirror();
      final sender = _FakeSender()..respondPostOk('1.0');
      final client = SlackClient(token: 'xoxb', sender: sender.send);
      final reply = SlackReply(
        mirror: mirror,
        client: client,
        selfActor: _self,
        now: _fixedNow,
      );

      final out = await reply.post(path: _path, text: 'hi');
      expect(out.epoch, 1);
    });

    test('outbound message is stamped with (path, epoch) metadata (§8.6)',
        () async {
      final mirror = InMemorySlackMirror();
      final sender = _FakeSender()..respondPostOk('1.0');
      final client = SlackClient(token: 'xoxb', sender: sender.send);
      final reply = SlackReply(
        mirror: mirror,
        client: client,
        selfActor: _self,
        now: _fixedNow,
      );

      await reply.post(path: _path, text: 'hi');

      final body = jsonDecode(utf8.decode(sender.seen.single.body)) as Map;
      final metadata = body['metadata'] as Map;
      expect(metadata['event_type'], intersyntacticSlackReplyEventType);
      final payload = metadata['event_payload'] as Map;
      expect(payload['workspace'], 'T01ABC');
      expect(payload['channel'], 'C01');
      expect(payload['thread_ts'], '1730000000.000100');
      expect(payload['epoch'], 1);
    });
  });
}
