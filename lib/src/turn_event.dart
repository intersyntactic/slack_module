/// The sealed family a turn-engine sink consumes: a normalised view of an
/// agent-host turn, factored so Slack's and Teams' sinks diverge only where
/// their journey rules actually diverge.
///
/// Sibling of teams_module's TurnEvent family. Naming matches on purpose (per
/// teams-module-e2's inventory, 2026-11-10): once both modules have shipped a
/// turn engine in anger, diffing the two families is how we tell real
/// divergence from vocabulary drift. Where the variants are the same shape,
/// Layer 1 (the host client) and the normaliser can move into
/// `intersyntactic_protocol`; where they diverge, the sinks absorb it.
///
/// Four host silences this family must carry correctly (teams-module-e2's
/// blood-on-the-floor, 2026-11-10):
///
///   - The host NEVER emits `StatusChanged(running)`. The echo of the user's
///     own message is the only "turn started" signal. [TurnBegan] is therefore
///     SYNTHESISED by the normaliser when it recognises its own echo, not
///     forwarded from the host. A fake host that emits a polite "running"
///     status models a host that doesn't exist.
///   - The host's echo of our own message arrives on the event stream
///     BEFORE the HTTP response to `POST /agent/<id>/message` returns. The
///     normaliser's "this is ours" register must therefore be populated
///     BEFORE `say` is sent, and dropped only if `say` refuses — a matcher
///     wired after `say` returns will miss the echo whenever the race goes
///     that way (it does, in the live host). Fakes that answer `say`
///     instantly and fan events afterwards hide this; a test with the fake
///     echoing INSIDE `say()` before returning catches it.
///   - Resume needs `after_at` (the host-side timestamp of the last event
///     seen) in addition to `after` (its sequence number). Without `after_at`
///     the host sends `reset` and replays the whole log. Every variant
///     therefore carries [at]; a Layer 1 resume reads the latest one.
///   - A mid-turn user message is refused with HTTP 409, not queued. There
///     is no `TurnQueued` or similar in this family; a 409 belongs in Layer
///     1's `say` return, not in the normalised event stream.
///
/// Carry the full host status string in [TurnWorking.status] rather than
/// extracting fields: Slack and Teams will likely want different extractions,
/// and premature extraction is harder to undo than to delay.
///
/// Pure: no imports beyond `dart:core`. This file is the natural candidate
/// to move into `intersyntactic_protocol` first when the hoist happens.
library;

/// The common type for every host-level event, so a sink can switch over the
/// full set with a compile-time-checked switch. A seventh variant would turn
/// such a switch red rather than silently widen the set.
sealed class TurnEvent {
  const TurnEvent({required this.at});

  /// The host-side timestamp of this event, kept on every variant so Layer 1
  /// can read `after_at` from the latest one without a type-aware walk.
  final DateTime at;
}

/// A turn has started. The normaliser synthesises this when it sees the
/// host's echo of a message that was registered as ours before `say` was
/// sent (see the pre-`say` register constraint in the file comment above);
/// the host itself never signals "running". [echoedText] is the exact text
/// the host echoed back.
final class TurnBegan extends TurnEvent {
  const TurnBegan({required super.at, required this.echoedText});

  final String echoedText;
}

/// The host is working on the turn; [status] is the full host-side status
/// string, uninterpreted. Slack's sink and Teams' sink may extract different
/// fields from it (or none), which is why this variant does not pre-split.
///
/// The host never sends `status: 'running'` — a [TurnWorking] with any other
/// status is the host's first signal AFTER [TurnBegan].
final class TurnWorking extends TurnEvent {
  const TurnWorking({required super.at, required this.status});

  final String status;
}

/// Streaming text has arrived. [textSoFar] is the full buffered text up to
/// this event, NOT just the delta — the sink is responsible for diffing it
/// against the previous [TurnWriting] if it wants a delta. Shaping it this
/// way means a sink that falls behind the stream only needs the latest
/// event to catch up, which matches Slack's debounced-`chat.update` rhythm.
final class TurnWriting extends TurnEvent {
  const TurnWriting({required super.at, required this.textSoFar});

  final String textSoFar;
}

/// A step within the turn finished. Carried separately from [TurnEnded] so
/// a turn with multiple steps still ends exactly once. A fresh [TurnWriting]
/// stream commonly starts after this — in ChatGPT-driven journeys, writing
/// a sentence before the first tool call is the typical case, not the edge
/// (teams-module-e2, 2026-11-10). A sink that buffers `textSoFar` across
/// steps will leak prior-step text into the next; reset the buffer here.
final class StepEnded extends TurnEvent {
  const StepEnded({required super.at});
}

/// The agent is asking the user something and is waiting on a reply.
/// [prompt] is the question; a sink surfaces it to the user and the next
/// user message answers it. The turn is not over.
final class TurnAsked extends TurnEvent {
  const TurnAsked({required super.at, required this.prompt});

  final String prompt;
}

/// How a turn ended. Only the two reasons the host distinguishes today:
/// [idle] (the agent finished normally), [failed] (the host surfaced an
/// error). "Interrupted" is not here because the host does not report it as
/// a distinct kind — an interrupt becomes an [idle] end with a short detail.
enum TurnEndedKind { idle, failed }

/// The terminal event. [kind] says how it ended; [detail] carries the
/// host's free-text description (e.g. the error message, or empty on a
/// clean idle). After this, no more [TurnEvent]s belong to this turn.
final class TurnEnded extends TurnEvent {
  const TurnEnded({
    required super.at,
    required this.kind,
    required this.detail,
  });

  final TurnEndedKind kind;
  final String detail;
}
