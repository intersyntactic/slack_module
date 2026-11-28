import 'dart:convert';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart'
    show NothingRan, Outcome, Ran, StoppedPartway;
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart'
    show BodyToKeep, Method, ProposedRequest, TextBody, WebResponse;
import 'package:is_airlock_api/is_airlock_api.dart'
    show TrajectoryId, WritesPinnedBodyReplyRequests;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show
        RepliesWithPinnedBodyFields,
        ReplyContent,
        ServerAssignedMessageId,
        SourceMessageId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;

import 'slack_reply_endpoint.dart';

/// The `chat.postMessage` requests that post a reply in a Slack
/// conversation, and what each one posted. Pure: no token, no sending.
///
/// The text is escaped, so `<!channel>` or `<@U…>` in a reply is shown as
/// written and never pings anyone. A reply longer than [piece] is split
/// into several messages, at a line break where there is one, then a
/// space, and never inside an escape or a character. The footer ends the
/// last message, or is a message of its own when it won't fit there.
final class SlackReplyRequests implements WritesPinnedBodyReplyRequests {
  const SlackReplyRequests();

  /// The most UTF-16 code units one message carries: Slack's advice for a
  /// message's text, which it truncates far above this.
  static const piece = 4000;

  @override
  Set<({Origin origin, WebPath path})> get addresses => {
    (origin: slackReplyOrigin, path: slackPostMessagePath),
  };

  /// The requests that post [content] in [to]'s conversation. Each body is
  /// [to]'s pinned fields as pinned, so it names that conversation and no
  /// other, plus `text`: [content]'s escaped (`&`, `<`, `>`), so it differs
  /// from the decided text exactly where the decided text would have
  /// mentioned someone or the channel: escaping only takes that power away.
  @override
  List<ProposedRequest> draw(
    RepliesWithPinnedBodyFields to,
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
          path: to.path,
          headers: const {'content-type': 'application/json; charset=utf-8'},
          body: jsonEncode({...to.pinned.mustEqual, 'text': text}),
          keep: BodyToKeep.text,
        ),
    ];
  }

  @override
  Outcome<ServerAssignedMessageId> posted(
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

  /// What a reply to [to] posted, from the [responses] to its requests in
  /// the order [draw] wrote them: [Ran] with each message's id, as
  /// [slackSourceMessageId] writes it, so a later reaction on one names
  /// the same id. [NothingRan] when Slack says the first posted nothing, or
  /// there was no response at all. [StoppedPartway] otherwise, with `done`
  /// the ids of the messages known posted, null when none is.
  Outcome<List<SourceMessageId>> postedMessages(
    RepliesWithPinnedBodyFields to,
    List<WebResponse> responses,
  ) {
    final channel = to.pinned.mustEqual['channel'];
    if (channel == null) {
      return const StoppedPartway(
        why: 'the reply endpoint names no Slack channel',
        done: null,
      );
    }
    if (responses.isEmpty) return const NothingRan('no request was sent');
    final ids = <SourceMessageId>[];
    Outcome<List<SourceMessageId>> stopped(String why) =>
        StoppedPartway(why: why, done: ids.isEmpty ? null : ids);
    for (final response in responses) {
      switch (posted(response)) {
        case Ran(output: final ts):
          final id = slackSourceMessageId(channel, ts.value);
          if (id == null) return stopped('no message id for $channel|$ts');
          ids.add(id);
        case NothingRan(:final why):
          return ids.isEmpty ? NothingRan(why) : stopped(why);
        case StoppedPartway(:final why):
          return stopped(why);
      }
    }
    return Ran(ids);
  }

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
        final ts? => _Posted(ServerAssignedMessageId.parse(ts.value)!),
        null => null,
      };
    } on FormatException {
      return null;
    }
  }
}

final class _Posted extends _SlackAnswer {
  const _Posted(this.ts);
  final ServerAssignedMessageId ts;
}

final class _Refused extends _SlackAnswer {
  const _Refused(this.error);
  final String error;
}
