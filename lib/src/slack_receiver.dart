/// The handler side of §4.1: takes a parsed [SlackNode] + its [SlackThread],
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
///   - The gate-doorbell → SlackNode parser lives in `gate_parser.dart`; this
///     receiver is defined over a `SlackNode` so the mirror and kickoff logic
///     stays testable without it. The parser went the doorbell-carries-text
///     route (§8 Done-when rule 1: no `conversations.history`).
///   - Edit → 🔄 → consent re-run flow (§8.2). The mirror supports it
///     structurally (edit nodes land as SlackEdit); the reaction-as-consent
///     side loops back through the turn engine and belongs with it.
library;

import 'package:is_shapes/is_shapes.dart';

import 'slack_thread.dart';
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
  final SlackThread path;
  final int epoch;
  final bool wantsTurn;
}

/// The withdrawal analogue of [KickoffRecord]. A `Withdraw<SlackReaction>`
/// does not append to the main node chain (is_shapes doctrine: withdrawals
/// are a side mechanism, not a shape family member), so there is no new
/// `mirroredAs` id — instead [withdrew] points at the `SlackReaction` the
/// withdrawal takes back. The turn engine reads the undoes-a-🔄 signal
/// here.
final class WithdrawRecord {
  const WithdrawRecord({
    required this.withdrew,
    required this.path,
    required this.epoch,
    required this.wantsTurn,
  });

  /// The `TurnId` of the `SlackReaction` that was taken back.
  final TurnId withdrew;
  final SlackThread path;
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

  KickoffRecord receive(SlackThread path, SlackNode node) {
    final id = mirror.write(path, node);
    return KickoffRecord(
      mirroredAs: id,
      path: path,
      epoch: mirror.epochFor(path),
      wantsTurn: _wantsTurn(node),
    );
  }

  /// Records a `Withdraw<SlackReaction>` and emits the record the turn
  /// engine consumes. The withdrawal is written to the mirror's side table
  /// (see [SlackMirror.writeWithdraw]) rather than appended to the chain.
  ///
  /// `wantsTurn` follows the same rule as [receive]: foreign authorship
  /// wakes a turn, self authorship does not. A user removing their own 🔄
  /// consent after the agent prompted for one is the textbook case for
  /// wanting a turn (to retract the running edit-fork, per §4.1); a
  /// self-removal is the receiver's own reply pipeline cleaning up.
  WithdrawRecord withdraw(SlackThread path, Withdraw<SlackReaction> w) {
    mirror.writeWithdraw(w);
    return WithdrawRecord(
      withdrew: w.target,
      path: path,
      epoch: mirror.epochFor(path),
      wantsTurn: w.by != selfActor,
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
