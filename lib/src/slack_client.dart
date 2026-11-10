/// A thin typed wrapper over the handful of Slack Web API endpoints this
/// package calls: read a thread, post the first reply, update it as the model
/// streams, delete a user's `/connect` command so an API key does not linger
/// in Slack history.
///
/// The sender is injected (a [SlackSend]), so the client can be exercised in
/// tests without a network and without opening a Slack app. The methods below
/// never read `SLACK_BOT_TOKEN` from the environment — the caller supplies it
/// as [SlackClient.token], once, at the top of the process.
///
/// Slack's error model is odd: HTTP 200 with `{"ok": false, "error": "..."}`
/// for application errors, HTTP 429 with a `Retry-After` for rate limits.
/// Both surface here as a thrown [SlackApiError], with the error string from
/// Slack so a reader can act on it (e.g. `channel_not_found`, `not_in_channel`).
library;

import 'dart:async';
import 'dart:convert';

const _slack = 'https://slack.com/api/';

/// A minimal HTTP sender: given a request shape, returns the response. Keeps
/// this file framework-free and testable; the real one wraps `dart:io`'s
/// `HttpClient`.
typedef SlackSend = Future<SlackHttpResponse> Function(SlackHttpRequest req);

class SlackHttpRequest {
  final String method; // 'GET' or 'POST'
  final Uri url;
  final Map<String, String> headers;

  /// Body is UTF-8 JSON for POST, empty for GET.
  final List<int> body;

  const SlackHttpRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body = const [],
  });
}

class SlackHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const SlackHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });
}

/// Slack's `metadata` on a posted message: an `event_type` string plus a
/// free-form `event_payload` object. Slack echoes it back on reads of the
/// same message (via `conversations.replies`), so this is the one place a
/// poster can leave bytes on its own message that survive the round-trip
/// without being part of the visible text.
///
/// Used by §8.6 to carry `(journey_path, epoch)` on outbound replies, so a
/// live receiver can tell its own posts from a zombie's.
class SlackMessageMetadata {
  const SlackMessageMetadata({
    required this.eventType,
    required this.eventPayload,
  });

  final String eventType;
  final Map<String, Object?> eventPayload;

  Map<String, Object?> toJson() => {
        'event_type': eventType,
        'event_payload': eventPayload,
      };
}

class SlackApiError implements Exception {
  final String method;
  final String error;
  final int statusCode;

  /// For a Slack 429, this is `Retry-After` in seconds. Null otherwise. The
  /// caller decides whether to back off and retry; the client does not spin.
  final int? retryAfterSeconds;

  SlackApiError(
    this.method,
    this.error, {
    this.statusCode = 200,
    this.retryAfterSeconds,
  });

  @override
  String toString() =>
      'SlackApiError($method, $error${statusCode == 200 ? '' : ', http=$statusCode'}${retryAfterSeconds == null ? '' : ', retry-after=${retryAfterSeconds}s'})';
}

class SlackClient {
  SlackClient({required this.token, required SlackSend sender}) : _send = sender;


  final String token;
  final SlackSend _send;

  /// Returns the thread's messages in Slack's own shape (list of `{user, text,
  /// ts, thread_ts?}` maps). The handler decides which fields matter. Paginated
  /// internally only if a `response_metadata.next_cursor` appears; this
  /// package does not expose pagination to callers for MVP (threads over ~1000
  /// messages are rare in a bot context).
  Future<List<Map<String, dynamic>>> conversationsReplies({
    required String channel,
    required String threadTs,
  }) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final url = Uri.parse('${_slack}conversations.replies').replace(
        queryParameters: {
          'channel': channel,
          'ts': threadTs,
          'cursor': ?cursor,
          'limit': '200',
        },
      );
      final res = await _get(url);
      final messages = res['messages'];
      if (messages is List) {
        for (final m in messages) {
          if (m is Map) out.add(m.cast<String, dynamic>());
        }
      }
      final meta = res['response_metadata'];
      cursor = (meta is Map && meta['next_cursor'] is String)
          ? (meta['next_cursor'] as String).isEmpty
              ? null
              : meta['next_cursor'] as String
          : null;
    } while (cursor != null);
    return out;
  }

  /// Posts a new message, returning its `ts` so the caller can edit it later.
  /// Passing `threadTs` makes the message a reply in that thread; omit it to
  /// post to the top of the channel.
  ///
  /// [metadata] rides along as Slack's `metadata` field (`{event_type,
  /// event_payload}`), visible on the posted message when read back via
  /// `conversations.replies`. Used by the externally-anchored journey path
  /// pattern (§8.6) to stamp `(journey_path, epoch)` on outbound messages so
  /// a live receiver can tell its own posts from a zombie's.
  Future<String> chatPostMessage({
    required String channel,
    required String text,
    String? threadTs,
    SlackMessageMetadata? metadata,
  }) async {
    final res = await _post('chat.postMessage', {
      'channel': channel,
      'text': text,
      'thread_ts': ?threadTs,
      'metadata': ?metadata?.toJson(),
    });
    final ts = res['ts'];
    if (ts is! String) {
      throw SlackApiError('chat.postMessage', 'no ts in response');
    }
    return ts;
  }

  /// Replaces the text of an existing message. Slack rate-limits this to
  /// ~1 call per second per message; the caller is responsible for pacing —
  /// see [SlackMessageStream] for the streaming pattern.
  Future<void> chatUpdate({
    required String channel,
    required String ts,
    required String text,
  }) async {
    await _post('chat.update', {
      'channel': channel,
      'ts': ts,
      'text': text,
    });
  }

  /// Removes a message. Used after `/connect <provider> <key>` to keep API
  /// keys out of Slack history.
  Future<void> chatDelete({
    required String channel,
    required String ts,
  }) async {
    await _post('chat.delete', {
      'channel': channel,
      'ts': ts,
    });
  }

  /// Adds an emoji reaction to a message. The design uses this as a one-click
  /// consent prompt: the agent reacts, a seat adds the same emoji to agree,
  /// no reaction means no action. See docs/externally-anchored-journey-paths.md §3
  /// (consent is an instance of appending a reaction-shaped node) and §4.1,
  /// §4.2 for the edit-replay and proactive-remember uses.
  ///
  /// [name] is the Slack emoji name without surrounding colons
  /// (e.g. `arrows_counterclockwise`, `floppy_disk`).
  Future<void> reactionsAdd({
    required String channel,
    required String ts,
    required String name,
  }) async {
    await _post('reactions.add', {
      'channel': channel,
      'timestamp': ts,
      'name': name,
    });
  }

  Future<Map<String, dynamic>> _get(Uri url) async {
    final res = await _send(SlackHttpRequest(
      method: 'GET',
      url: url,
      headers: {'Authorization': 'Bearer $token'},
    ));
    return _decode(url.pathSegments.last, res);
  }

  Future<Map<String, dynamic>> _post(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final body = utf8.encode(jsonEncode(payload));
    final res = await _send(SlackHttpRequest(
      method: 'POST',
      url: Uri.parse('$_slack$method'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body,
    ));
    return _decode(method, res);
  }

  static Map<String, dynamic> _decode(
    String method,
    SlackHttpResponse res,
  ) {
    if (res.statusCode == 429) {
      final retryAfter =
          int.tryParse(res.headers['retry-after'] ?? res.headers['Retry-After'] ?? '');
      throw SlackApiError(
        method,
        'rate_limited',
        statusCode: 429,
        retryAfterSeconds: retryAfter,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SlackApiError(
        method,
        'http_${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw SlackApiError(method, 'non_object_response');
    }
    final map = decoded.cast<String, dynamic>();
    if (map['ok'] != true) {
      final err = map['error'];
      throw SlackApiError(method, err is String ? err : 'unknown_error');
    }
    return map;
  }
}

/// Growing a Slack message as text arrives. The pattern:
///
///   final stream = await SlackMessageStream.open(
///     client: client,
///     channel: channel,
///     threadTs: threadTs,
///     initialText: '…',
///   );
///   // for each piece of streamed model output:
///   stream.append('tokens…');
///   // when the turn is finished:
///   await stream.close();
///
/// Edits are debounced to [minInterval] (default 1 second: Slack's documented
/// per-message tier-4 ceiling) and always flushed at close so the final text
/// matches what the model produced. The underlying `chat.update` is awaited;
/// a Slack rate-limit error pauses this stream for the server's Retry-After
/// rather than throwing it to the caller.
class SlackMessageStream {
  SlackMessageStream._({
    required this.client,
    required this.channel,
    required this.ts,
    required this.minInterval,
    required DateTime Function() nowFn,
  })  : _buffer = StringBuffer(),
        _now = nowFn;

  static Future<SlackMessageStream> open({
    required SlackClient client,
    required String channel,
    String? threadTs,
    String initialText = '…',
    Duration minInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) async {
    final ts = await client.chatPostMessage(
      channel: channel,
      text: initialText,
      threadTs: threadTs,
    );
    final s = SlackMessageStream._(
      client: client,
      channel: channel,
      ts: ts,
      minInterval: minInterval,
      nowFn: now ?? DateTime.now,
    );
    s._buffer.write(initialText);
    s._lastFlushAt = s._now();
    s._lastFlushed = initialText;
    return s;
  }

  final SlackClient client;
  final String channel;
  final String ts;
  final Duration minInterval;
  final DateTime Function() _now;

  final StringBuffer _buffer;
  DateTime? _lastFlushAt;
  String _lastFlushed = '';
  Timer? _pending;
  bool _closed = false;

  /// Add text to the pending message. A flush is scheduled no sooner than
  /// [minInterval] after the previous one.
  void append(String piece) {
    if (_closed) return;
    _buffer.write(piece);
    _schedule();
  }

  void _schedule() {
    if (_pending != null) return;
    final since = _lastFlushAt == null
        ? minInterval
        : _now().difference(_lastFlushAt!);
    final wait = since >= minInterval ? Duration.zero : minInterval - since;
    _pending = Timer(wait, _flushNow);
  }

  Future<void> _flushNow() async {
    _pending = null;
    if (_closed) return;
    final text = _buffer.toString();
    if (text == _lastFlushed) return;
    try {
      await client.chatUpdate(channel: channel, ts: ts, text: text);
      _lastFlushed = text;
      _lastFlushAt = _now();
    } on SlackApiError catch (e) {
      // Give Slack what it asked for, then try again on the next append or at
      // close. Not raised to the caller: a streamed edit failing mid-turn is
      // a style issue, not an outcome.
      if (e.retryAfterSeconds != null) {
        _pending = Timer(
          Duration(seconds: e.retryAfterSeconds!),
          _flushNow,
        );
      }
    }
  }

  /// Final flush. After this returns the message's text matches the full
  /// buffer, or an error has been thrown.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending?.cancel();
    _pending = null;
    final text = _buffer.toString();
    if (text != _lastFlushed) {
      await client.chatUpdate(channel: channel, ts: ts, text: text);
      _lastFlushed = text;
      _lastFlushAt = _now();
    }
  }
}
