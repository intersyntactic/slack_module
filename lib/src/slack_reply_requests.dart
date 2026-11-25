import 'dart:convert';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_effects/is_effects.dart'
    show
        BodyToKeep,
        Method,
        NothingRan,
        Outcome,
        ProposedRequest,
        Ran,
        StoppedPartway,
        TextBody,
        WebResponse;
import 'package:is_reply_requests_api/is_reply_requests_api.dart'
    show WritesSlackReplyRequests;
import 'package:is_reply_vocabulary/is_reply_vocabulary.dart'
    show RepliesInSlackConversation, ReplyContent, SlackMessageTimestamp;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show WebPath;

/// The `chat.postMessage` requests that post a reply in a Slack
/// conversation, and what each one posted. Pure: no token, no sending.
///
/// The text is escaped, so `<!channel>` or `<@U…>` in a reply is shown as
/// written and never pings anyone. A reply longer than [piece] is split
/// into several messages, at a line break where there is one, then a
/// space, and never inside an escape or a character. The footer ends the
/// last message, or is a message of its own when it won't fit there.
final class SlackReplyRequests implements WritesSlackReplyRequests {
  const SlackReplyRequests();

  /// The most UTF-16 code units one message carries: Slack's advice for a
  /// message's text, which it truncates far above this.
  static const piece = 4000;

  static final _postMessage = WebPath.parse('/api/chat.postMessage')!;

  /// The requests that post [content] in [to]'s conversation. Each body's
  /// text is [content]'s escaped (`&`, `<`, `>`), so it differs from the
  /// decided text exactly where the decided text would have mentioned
  /// someone or the channel: escaping only takes that power away.
  @override
  List<ProposedRequest> draw(
    RepliesInSlackConversation to,
    TrajectoryId trajectory,
    ReplyContent content,
  ) {
    final pieces = _split(_escaped(content.text.value));
    if (content.footer case final footer?) {
      final last = '${pieces.last}\n\n${_escaped(footer.value)}';
      if (last.length <= piece) {
        pieces.last = last;
      } else {
        pieces.addAll(_split(_escaped(footer.value)));
      }
    }
    return [
      for (final text in pieces)
        ProposedRequest(
          to.origin,
          method: Method.post,
          path: _postMessage,
          headers: const {'content-type': 'application/json; charset=utf-8'},
          body: jsonEncode({
            'channel': to.channel.value,
            if (to.thread case final thread?) 'thread_ts': thread.value,
            'text': text,
          }),
          keep: BodyToKeep.text,
        ),
    ];
  }

  @override
  Outcome<SlackMessageTimestamp> posted(
    WebResponse response,
  ) => switch (response) {
    // Slack's rate limit refuses the request before reading it.
    WebResponse(status: 429) => NothingRan(
      'Slack rate-limited the message: ${response.refusedBecause ?? '429'}',
    ),
    WebResponse(status: >= 200 && < 300, body: TextBody(:final text)) =>
      switch (_SlackAnswer.parse(text)) {
        _Posted(:final ts) => Ran(ts),
        _Refused(:final error) => NothingRan('Slack refused: $error'),
        null => StoppedPartway(
          why: 'Slack answered ${response.status} with no answer to read',
          done: null,
        ),
      },
    _ => StoppedPartway(
      why:
          'Slack answered ${response.status}'
          '${response.refusedBecause == null ? '' : ': ${response.refusedBecause}'}'
          ', so the message may have posted',
      done: null,
    ),
  };

  /// [text] with Slack's three control characters escaped, as Slack asks.
  static String _escaped(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// [text] in pieces of at most [piece] code units, none of them blank.
  static List<String> _split(String text) {
    final pieces = <String>[];
    var rest = text;
    while (rest.length > piece) {
      final cut = _cutIn(rest);
      pieces.add(rest.substring(0, cut));
      rest = rest.substring(cut);
      if (rest.startsWith('\n')) rest = rest.substring(1);
    }
    pieces.add(rest);
    return [
      for (final p in pieces)
        if (p.trim().isNotEmpty) p,
    ];
  }

  /// Where to end the first piece of [text], which is longer than [piece].
  static int _cutIn(String text) {
    final head = text.substring(0, piece);
    var cut = head.lastIndexOf('\n');
    if (cut < piece ~/ 2) cut = head.lastIndexOf(' ');
    if (cut < piece ~/ 2) cut = piece;
    // Not inside an escape such as `&amp;`.
    final amp = text.lastIndexOf('&', cut - 1);
    if (amp >= 0 && amp > cut - 5 && !text.substring(amp, cut).contains(';')) {
      cut = amp;
    }
    // Not between the two halves of a surrogate pair.
    final before = text.codeUnitAt(cut - 1);
    if (before >= 0xD800 && before <= 0xDBFF) cut -= 1;
    return cut;
  }
}

/// What Slack's answer to `chat.postMessage` says, read once from its body.
sealed class _SlackAnswer {
  const _SlackAnswer();

  /// [body] as Slack's answer; null when it is no answer Slack gives, so
  /// whether the message posted can't be told.
  static _SlackAnswer? parse(String body) {
    try {
      final answer = JsonObject.decode(body);
      if (!answer.boolean('ok')) {
        return _Refused(answer.stringOrNull('error') ?? 'no error named');
      }
      return switch (SlackMessageTimestamp.parse(
        answer.stringOrNull('ts') ?? '',
      )) {
        final ts? => _Posted(ts),
        null => null,
      };
    } on FormatException {
      return null;
    }
  }
}

final class _Posted extends _SlackAnswer {
  const _Posted(this.ts);
  final SlackMessageTimestamp ts;
}

final class _Refused extends _SlackAnswer {
  const _Refused(this.error);
  final String error;
}
