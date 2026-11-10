/// Write-ahead reply path: mirror first, then `chat.postMessage`.
///
/// Why write-ahead: the mirror is the record of what the agent intended to
/// post, and the record has to be authored by the receiver that intends to
/// post before the post goes out — otherwise two receivers racing to the
/// same thread could both see "no reply yet", both call Slack, and the
/// mirror would show only the one that called `postMessage` first. Writing
/// to the mirror first turns the race into a one-head CAS at the mirror
/// (future `SlackMirror.writeIfHead` — not yet implemented; the in-memory
/// mirror is single-writer).
///
/// Nick's choice on post-failure (confirmed 2026-11-10): the mirror node
/// stays. Rationale — the intent is a fact, and the failure is another fact,
/// and both belong on the chain. A future failure-annotation (an is_annotation
/// shape, e.g. `Posted(ts)` written on success / `PostFailed(reason)` on
/// failure) would close the loop without rewinding; this scaffold surfaces
/// the failure to the caller instead.
library;

import 'package:is_shapes/is_shapes.dart';

import 'journey_id.dart';
import 'outbound_metadata.dart';
import 'shapes.dart';
import 'slack_client.dart';
import 'slack_mirror.dart';

/// What the reply path returns. [postedTs] is the Slack `ts` the message
/// landed at; null when Slack refused the post (see [error]). Either way
/// [mirroredAs] is the TurnId that was written to the mirror before the
/// Slack call — the mirror node is NOT retracted on a Slack failure.
final class SlackReplyOutcome {
  const SlackReplyOutcome({
    required this.mirroredAs,
    required this.path,
    required this.epoch,
    required this.postedTs,
    required this.error,
  });

  final TurnId mirroredAs;
  final JourneyId path;
  final int epoch;
  final String? postedTs;
  final SlackApiError? error;

  bool get posted => postedTs != null;
}

final class SlackReply {
  SlackReply({
    required this.mirror,
    required this.client,
    required this.selfActor,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SlackMirror mirror;
  final SlackClient client;

  /// The agent's own [ActorId], used as `by` on every mirrored outbound
  /// message. Keeping it on the reply path (not the client) keeps the client
  /// a dumb Slack wrapper and makes multi-agent deployments possible.
  final ActorId selfActor;

  final DateTime Function() _now;

  /// Writes a reply. Steps, in order:
  ///
  ///   1. Mint a provisional `ts` for the mirror record (`_mintProvisionalTs`).
  ///      Slack returns the real `ts` from `chat.postMessage`; the mirror
  ///      records what we meant to say, so the provisional ts is enough for
  ///      ordering. If a caller needs to cross-reference the mirrored node to
  ///      the Slack message afterwards, [SlackReplyOutcome.postedTs] carries
  ///      Slack's returned ts.
  ///   2. `mirror.write(path, message)` — authoritative, happens first.
  ///   3. `client.chatPostMessage(...)`. On failure, caught and surfaced in
  ///      [SlackReplyOutcome.error]; mirror node stays.
  Future<SlackReplyOutcome> post({
    required JourneyId path,
    required String text,
  }) async {
    final provisionalTs = _mintProvisionalTs();
    final node = SlackMessage(
      channel: path.channel,
      ts: provisionalTs,
      by: selfActor,
      text: text,
      threadTs: path.threadTs,
    );
    final mirroredAs = mirror.write(path, node);
    final epoch = mirror.epochFor(path);

    String? postedTs;
    SlackApiError? error;
    try {
      postedTs = await client.chatPostMessage(
        channel: path.channel,
        text: text,
        threadTs: path.threadTs,
        metadata: SlackMessageMetadata(
          eventType: intersyntacticSlackReplyEventType,
          eventPayload: {
            'workspace': path.workspace,
            'channel': path.channel,
            'thread_ts': path.threadTs,
            'epoch': epoch,
          },
        ),
      );
    } on SlackApiError catch (e) {
      error = e;
    }

    return SlackReplyOutcome(
      mirroredAs: mirroredAs,
      path: path,
      epoch: epoch,
      postedTs: postedTs,
      error: error,
    );
  }

  /// A Slack-shaped provisional ts: unix-seconds.microseconds, stamped from
  /// our own clock. The mirror ids a node by its full bytes so a different
  /// ts yields a different TurnId — a later write that reuses this one's
  /// text but with Slack's real ts would correctly mint a new node, not
  /// collide with the provisional. (Future work: once the Slack call
  /// returns, write a `Posted(real_ts)` annotation that targets the
  /// provisional node, instead of trying to revise the ts in place.)
  String _mintProvisionalTs() {
    final n = _now().toUtc();
    final seconds = n.millisecondsSinceEpoch ~/ 1000;
    final micros = (n.microsecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
    return '$seconds.$micros';
  }
}
