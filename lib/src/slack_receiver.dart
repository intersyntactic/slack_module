/// The handler side of §4.1: takes a parsed [SlackNode] + its [JourneyPathId],
/// writes it to the mirror, and emits a [KickoffRecord] carrying what a turn
/// engine needs to decide whether to run.
///
/// This stops at the kickoff seam deliberately. The turn engine (the thing
/// that takes the record, opens a run on the agent host, reads SSE back and
/// drives the reply) is a separate concern that will share the mechanism with
/// Teams. teams-module-e2's blood-on-the-floor on the host side, relevant
/// when that engine is wired:
///
///   - The agent host (:8899) never emits `StatusChanged(running)`; the
///     user-message echo is the only "turn started" signal. Fakes must model
///     the host's silences, not polite versions of them.
///   - Resume needs `after_at` (exact time of last event) as well as `after`;
///     without it the host sends `reset` and replays the whole log.
///   - A mid-turn message is refused with HTTP 409, not queued.
///
/// None of those bite the mirror or the receiver, but they're the reason a
/// [KickoffRecord] carries both the mirrored node id AND the (path, epoch)
/// stamp: the turn engine will need to bind an agent-host run to that pair.
///
/// What's NOT here, deliberately:
///
///   - The gate-doorbell → SlackNode parser. The gate's `message` map drops
///     the message text today; closing that gap is a separate sub-task once
///     we decide doorbell-carries-text vs. receiver-fetches-once-via-
///     `conversations.history`. The receiver's core is defined over a
///     SlackNode so the mirror and kickoff logic is testable without that
///     decision.
///   - Edit → 🔄 → consent re-run flow (§8.2). The mirror supports it
///     structurally (edit nodes land as SlackEdit); the reaction-as-consent
///     side loops back through the turn engine and belongs with it.
library;

import 'package:is_shapes/is_shapes.dart';

import 'journey_path_id.dart';
import 'shapes.dart';
import 'slack_mirror.dart';

/// A record the turn engine consumes to decide whether to run. [wantsTurn]
/// is true for nodes that are inbound to the agent (mentions, messages,
/// reactions, edits by other actors); false for nodes the agent itself
/// wrote (the receiver's `selfActor` wrote them, so the reply path already
/// recorded them write-ahead and the turn engine has nothing to do).
///
/// The `(path, epoch)` pair is what §8.6 calls for: an outbound Slack
/// message carries the epoch in its metadata, so a zombie receiver's post
/// is recognised as foreign by the live receiver.
final class KickoffRecord {
  const KickoffRecord({
    required this.mirroredAs,
    required this.path,
    required this.epoch,
    required this.wantsTurn,
  });

  final TurnId mirroredAs;
  final JourneyPathId path;
  final int epoch;
  final bool wantsTurn;
}

final class SlackReceiver {
  SlackReceiver({required this.mirror, required this.selfActor});

  final SlackMirror mirror;

  /// The [ActorId] this receiver writes as. Nodes authored by this actor are
  /// the agent's own replies (recorded write-ahead by `SlackReply`), so the
  /// receiver flags them `wantsTurn: false` to prevent self-reaction loops.
  final ActorId selfActor;

  KickoffRecord receive(JourneyPathId path, SlackNode node) {
    final id = mirror.write(path, node);
    return KickoffRecord(
      mirroredAs: id,
      path: path,
      epoch: mirror.epochFor(path),
      wantsTurn: _wantsTurn(node),
    );
  }

  bool _wantsTurn(SlackNode node) => switch (node) {
        SlackMessage(:final by) => by != selfActor,
        SlackEdit(:final by) => by != selfActor,
        SlackReaction(:final by) => by != selfActor,
        // Tombstones don't run a turn; they record a deletion for readers.
        SlackTombstone() => false,
        // Raw events are kept for faithful-mirror reasons (#1068 Q3), not
        // to wake the agent. A later shape promotion is how one becomes
        // turn-worthy.
        SlackEventRaw() => false,
      };
}
