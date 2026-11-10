/// The five Slack-anchored node shapes bound at the `slack_mirror` acceptor.
///
/// The mirror never drifts from what Slack sent (#1068 Q3): every Slack event
/// produces exactly one node here. Four typed shapes cover the common cases;
/// [SlackEventRaw] carries anything else, loosely typed with a discriminator.
///
/// Identity follows #1068's ruling: a shape with no `@identity` has every
/// field as identity (append-only, safe default). A shape with `@identity`
/// marks what the anchor is derived from, and the un-marked fields are either
/// values (what the node currently says) or references, which `@identity`'s
/// dichotomy conflates. For [SlackEdit], `replaces` is a reference, not
/// identity, per #1068 ruling 2.
///
/// On the pure list (#1046): imports only `is_shapes`.
library;

import 'package:is_shapes/is_shapes.dart';

/// The common type for every Slack-anchored node shape, so the `slack_mirror`
/// acceptor can type-check offerings against something sharper than `Object`
/// (per intersyntactic's module loader, slice 2).
///
/// `sealed` so the five shapes below are the complete set; a sixth would break
/// the acceptor's type check loudly rather than silently widen it.
sealed class SlackNode {}

/// A message appended to a Slack channel or thread.
///
/// Identity is channel + ts + by + threadTs; text is not, so the semantic
/// anchor stays stable through [SlackEdit]s. Edits are separate nodes that
/// reference this one, not revisions in place.
final class SlackMessage implements SlackNode {
  const SlackMessage({
    required this.channel,
    required this.ts,
    required this.by,
    required this.text,
    this.threadTs,
  });

  @identity
  final String channel;

  @identity
  final String ts;

  @identity
  final ActorId by;

  @identity
  final String? threadTs;

  final String text;
}

/// An edit of a [SlackMessage].
///
/// Identity is channel + editTs + by + newText. [replaces] is a reference, not
/// identity, per #1068 ruling 2: an edit's anchor is stable regardless of
/// what it edits, so edits-of-already-revised content don't cascade through
/// their anchors and the one-way edit-chain walk holds.
final class SlackEdit implements SlackNode {
  const SlackEdit({
    required this.replaces,
    required this.channel,
    required this.editTs,
    required this.by,
    required this.newText,
  });

  @identity
  final String channel;

  @identity
  final String editTs;

  @identity
  final ActorId by;

  @identity
  final String newText;

  /// The message being edited. Reference, not identity.
  final TurnId replaces;
}

/// A reaction (emoji) added to a Slack node.
///
/// Unannotated: every field is identity (default rule). [ts] being identity
/// matters for the add → `Withdraw<SlackReaction>` → re-add cycle: the re-add
/// has a distinct TurnId because its ts differs, so it's a new reaction node
/// rather than colliding with the first.
///
/// Declared `final` for covariance safety: a subclass of SlackReaction would
/// let `Withdraw<SubReaction>` bind where `Withdraw<SlackReaction>` is
/// accepted. `final` closes that door.
///
/// Implements [Withdrawable]: a reaction can be taken back by a
/// `Withdraw<SlackReaction>`. The other Slack shapes deliberately do NOT
/// implement it — a message is removed by its [SlackTombstone], not a
/// withdrawal, so `Withdraw<SlackMessage>` is refused at compile time.
final class SlackReaction implements SlackNode, Withdrawable {
  const SlackReaction({
    required this.target,
    required this.emoji,
    required this.by,
    required this.ts,
  });

  /// The node being reacted to (usually a SlackMessage).
  final TurnId target;

  /// The emoji name as Slack sends it (e.g. "thumbsup"), without colons.
  final String emoji;

  /// Who added the reaction.
  final ActorId by;

  /// When the reaction was added (Slack's event_ts).
  final String ts;
}

/// A tombstone marking a [SlackMessage] as deleted in Slack.
///
/// Unannotated: every field is identity. The deletion itself is the node;
/// the original message stays in the line (nothing is ever erased).
final class SlackTombstone implements SlackNode {
  const SlackTombstone({
    required this.target,
    required this.by,
    required this.ts,
  });

  /// The message deleted.
  final TurnId target;

  /// Who deleted it.
  final ActorId by;

  /// When the deletion happened (Slack's event_ts).
  final String ts;
}

/// A catch-all for any Slack event the four typed shapes don't cover.
///
/// Discriminated by [slackEventType]; the raw payload stays as a JSON string
/// so the mirror can record what Slack sent without the shape vocabulary
/// having to grow for every event type. Per #1068 Q3 and the manifest's
/// `slack_event_raw` offering.
///
/// Unannotated: every field is identity.
final class SlackEventRaw implements SlackNode {
  const SlackEventRaw({
    required this.slackEventType,
    required this.channel,
    required this.ts,
    required this.rawPayload,
    this.by,
  });

  /// Slack's own `type` field (e.g. "pin_added", "channel_join").
  final String slackEventType;

  /// The channel the event is in; empty string for workspace-level events.
  final String channel;

  /// The event timestamp.
  final String ts;

  /// Who the event is from, if Slack said so; null otherwise.
  final ActorId? by;

  /// The whole Slack payload as JSON text, for faithful mirror.
  final String rawPayload;
}
