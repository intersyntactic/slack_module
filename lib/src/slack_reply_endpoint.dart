import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show PinnedBodyFields, RepliesWithPinnedBodyFields;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;

/// Where every Slack reply is sent: one site for every workspace, since the
/// bot's sign-in names the workspace.
final slackReplyOrigin = Origin.parse('https://slack.com')!;

/// The one path every Slack reply is posted to.
final slackPostMessagePath = WebPath.parse('/api/chat.postMessage')!;

/// A Slack conversation's id: a public or private channel (`C…`), a direct
/// message (`D…`) or a group message (`G…`).
final class SlackChannelId {
  const SlackChannelId._(this.value);

  /// The id, as Slack writes it.
  final String value;

  /// [s] as a channel id; null unless it is one.
  static SlackChannelId? parse(String s) =>
      _id.hasMatch(s) ? SlackChannelId._(s) : null;

  static final _id = RegExp(r'^[CDG][A-Z0-9]+$');

  @override
  bool operator ==(Object other) =>
      other is SlackChannelId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The timestamp (`ts`) Slack names a message by, such as
/// `1700000000.000100`. A thread is named by its root message's timestamp.
final class SlackMessageTimestamp {
  const SlackMessageTimestamp._(this.value);

  /// The timestamp, as Slack writes it.
  final String value;

  /// [s] as a message timestamp; null unless it is one.
  static SlackMessageTimestamp? parse(String s) =>
      _ts.hasMatch(s) ? SlackMessageTimestamp._(s) : null;

  static final _ts = RegExp(r'^\d+\.\d+$');

  @override
  bool operator ==(Object other) =>
      other is SlackMessageTimestamp && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A reply in [channel], in [thread] when there is one: `chat.postMessage`
/// with `channel`, and `thread_ts` for a thread, pinned, and `text` the only
/// other field allowed. Allowing only `text` refuses every field that would
/// reach past the pin or the text's escaping, such as `reply_broadcast`,
/// `blocks`, `link_names` or `username`, and, for a reply with no thread,
/// a `thread_ts` that would put it in someone else's.
RepliesWithPinnedBodyFields slackReplyEndpoint(
  SlackChannelId channel, {
  SlackMessageTimestamp? thread,
}) => RepliesWithPinnedBodyFields.at(
  origin: slackReplyOrigin,
  path: slackPostMessagePath,
  pinned: PinnedBodyFields.allowingOnly(
    {'channel': channel.value, 'thread_ts': ?thread?.value},
    otherFields: const {'text'},
  )!,
)!;
