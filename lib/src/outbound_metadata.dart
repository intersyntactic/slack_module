/// The outbound-metadata stamp that [SlackReply] puts on every message it
/// posts, and the reader that inbound parsing uses to recognise its own
/// posts and to spot a zombie receiver's.
///
/// Per docs/externally-anchored-journey-paths.md §8.6: a message a receiver
/// posts carries `(journey_path, epoch)` in Slack's `metadata` field. A
/// different receiver reading the event back can ask three questions in
/// order:
///
///   1. Did we post this? — `extractIntersyntacticEpoch` returns non-null.
///   2. Is the path the same? — compare the extracted path to the local one.
///   3. Is the epoch current? — compare the extracted epoch to
///      `mirror.epochFor(path)`. A smaller epoch means a zombie posted this
///      message and the live receiver should drop it rather than mirror it.
///
/// The functions here are pure (no mirror, no I/O) so they are testable in
/// isolation and so the integration point on the SlackEvent → SlackNode
/// parser can reuse them unchanged.
library;

import 'slack_thread.dart';

/// Slack `metadata.event_type` value stamped on every reply this module
/// posts. Namespaced so multiple intersyntactic-origin event types can
/// coexist without colliding with other apps' metadata.
const String intersyntacticSlackReplyEventType = 'intersyntactic_slack.reply';

/// What [SlackReply] stamped on a message, read back out of a raw Slack
/// message map (the shape `conversations.replies` returns). Returns null
/// if the message has no intersyntactic metadata — i.e. a person posted
/// it, or another app did.
IntersyntacticStamp? extractIntersyntacticStamp(
    Map<String, dynamic> slackMessage) {
  final metadata = slackMessage['metadata'];
  if (metadata is! Map) return null;
  if (metadata['event_type'] != intersyntacticSlackReplyEventType) return null;
  final payload = metadata['event_payload'];
  if (payload is! Map) return null;
  final workspace = payload['workspace'];
  final channel = payload['channel'];
  final threadTs = payload['thread_ts'];
  final epoch = payload['epoch'];
  if (workspace is! String ||
      channel is! String ||
      threadTs is! String ||
      epoch is! int) {
    return null;
  }
  return IntersyntacticStamp(
    path: SlackThread(
      workspace: workspace,
      channel: channel,
      threadTs: threadTs,
    ),
    epoch: epoch,
  );
}

final class IntersyntacticStamp {
  const IntersyntacticStamp({required this.path, required this.epoch});

  final SlackThread path;
  final int epoch;

  /// True when this message was posted by a receiver at an epoch older than
  /// the live one. The live receiver should NOT mirror the message: a
  /// zombie wrote it, and the mirror's job is to reflect what the live
  /// chain is doing.
  bool isForeign({required int localEpoch}) => epoch < localEpoch;
}
