/// The compound key naming one externally-anchored journey on the Slack side:
/// a thread, keyed by `(workspace, channel, threadTs)`.
///
/// Per docs/externally-anchored-journey-paths.md §4.1 and the RULINGS grain:
/// a *journey* holds journey paths, and a thread can hold more than one
/// (edit-fork in §4.1 preserves the old answer PATH as a branch while the new
/// one takes the head). The thread itself — the externally-anchored tuple — is
/// the journey; individual paths within it are the host's opaque
/// `JourneyPathId`s (formerly `RunId`s), tracked by the binding store.
///
/// Named `SlackThread`, not `JourneyId`, because the protocol now has its own
/// `JourneyId` (landed in intersyntactic PR 1126) — this type names a Slack
/// thread, which happens to anchor a journey, not the journey itself.
///
/// The Teams side does not have a keyed equivalent yet — it uses a linear
/// stand-in with no key at all (see teams_module's `stand_in_journey_path.dart`).
/// Keeping this as a value type (not a String) so a channel id and a thread_ts
/// can't be mistakenly swapped, and so the Dart analyzer refuses
/// `headFor(channel)` where a full journey is expected.
library;

final class SlackThread {
  const SlackThread({
    required this.workspace,
    required this.channel,
    required this.threadTs,
  });

  /// Slack's `team_id` for a workspace (`T...` prefix), or `enterprise_id`
  /// (`E...`) for a Grid org. The authority that owns the channel id-namespace.
  final String workspace;

  /// Slack channel id (`C...`, `G...`, `D...`).
  final String channel;

  /// The thread's anchor timestamp: the `ts` of the top-level message that
  /// seeded the thread. For a top-level mention that will seed a thread,
  /// callers pass the mention's own `ts` (matches the gate's `anchor`
  /// derivation in `slack_gate.dart`).
  final String threadTs;

  @override
  bool operator ==(Object other) =>
      other is SlackThread &&
      other.workspace == workspace &&
      other.channel == channel &&
      other.threadTs == threadTs;

  @override
  int get hashCode => Object.hash(workspace, channel, threadTs);

  @override
  String toString() => 'SlackThread($workspace/$channel/$threadTs)';
}
