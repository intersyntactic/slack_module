/// Turns a `SlackRelay`-delivered [relay.SlackEvent] into a
/// `(SlackThread, SlackNode)` pair the receiver can feed straight into its
/// mirror.
///
/// This is the "the event carries text" side of §8.1's open decision: the
/// relay already forwards `event.text` and friends, so the parser does not
/// call `conversations.history` (per §8 Done-when rule 1: "all without the
/// receiver calling `conversations.replies` after the first-ever message of
/// the thread").
///
/// What this parser covers today:
///
///   - a [relay.SlackMessage] with no `subtype` → `SlackMessage` (the domain
///     shape; `event.mention` distinguishes app_mention from a plain message
///     at the relay layer, but both produce the same node here).
///   - a [relay.SlackMessage] with `subtype == "message_changed"` →
///     `SlackEdit`, iff [lookup] resolves the replaced message's `TurnId`.
///     Without a resolver (or on a miss) the event falls back to
///     `SlackEventRaw` so the mirror stays faithful and a later turn can
///     promote the shape.
///   - a [relay.SlackMessage] with `subtype == "message_deleted"` →
///     `SlackTombstone`, same lookup rule as edits.
///   - Any other subtype → `SlackEventRaw` carrying the full inner event as
///     JSON.
///
/// Slash commands ([relay.SlackCommand]) never reach this parser — they
/// don't flow into the mirror, they are consumed by the model-selection
/// surface — so there is no `parseCommandToSlackNode`; the caller routes
/// them to `onCommand` directly.
///
/// Reactions:
///
///   - [relay.SlackReactionAdded] is handled by [parseReactionAddedToSlackNode],
///     emitting a `SlackReaction`. It needs a [SlackChannelTsLocate] to
///     resolve the target message's `TurnId` and `SlackThread` in one query.
///     On a miss (the mirror has never seen the target) the parser falls
///     back to `SlackEventRaw` keyed as if the target's ts were the thread
///     anchor — correct for reactions-on-top-level messages, best-effort
///     otherwise.
///   - [relay.SlackReactionRemoved] is handled by [parseReactionRemovedToWithdraw]
///     instead, which produces a `Withdraw<SlackReaction>`. A withdrawal is
///     not a `SlackNode`, so it cannot live in that function's return type.
library;

import 'dart:convert';

import 'package:is_shapes/is_shapes.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;

import 'slack_thread.dart';
import 'shapes.dart';
import 'slack_actor_id.dart';

/// Resolves the `TurnId` of a prior Slack message by its `(path, ts)`, or
/// returns null if the mirror has no record of it. Typically backed by the
/// mirror itself. A null resolver, or a null return, is not an error: the
/// parser falls back to `SlackEventRaw` so nothing is dropped.
typedef SlackMessageLookup = TurnId? Function(SlackThread path, String ts);

/// Resolves `(channel, ts)` to the mirrored node's id and the journey it
/// sits on, in one query. Used by the reaction path — a reaction event
/// carries `event.targetTs` but no `threadTs`, so the journey can only be
/// learned from a mirror index.
typedef SlackChannelTsLocate =
    ({TurnId id, SlackThread path})? Function(String channel, String ts);

/// Resolves `(target, emoji, by)` to the `TurnId` of the matching
/// `SlackReaction` on `target`'s path. `Withdraw<SlackReaction>` requires
/// the exact `TurnId` of what it undoes (is_shapes doctrine: a withdraw
/// targets one node, not an anchor); Slack identifies the reaction
/// indirectly, so we need the mirror to walk and match.
typedef SlackReactionFinder = TurnId? Function({
  required TurnId target,
  required String emoji,
  required ActorId by,
});

(SlackThread, SlackNode) parseMessageToSlackNode(
  relay.SlackMessage event, {
  SlackMessageLookup? lookup,
}) {
  final workspace = event.workspace;
  final channel = event.channel;
  final anchor = event.threadTs;
  final path = SlackThread(
    workspace: workspace,
    channel: channel,
    threadTs: anchor,
  );

  final subtype = event.subtype;
  final raw = event.rawEvent;

  if (subtype == null) {
    // Plain message or app_mention. Fields come straight from the event.
    final userId = event.user;
    final text = event.text;
    final eventTs = event.eventTs;
    final rawThreadTs = event.rawThreadTs;
    if (userId == null || text == null || eventTs == null) {
      return (path, _raw(raw, channel, anchor, workspace, userId: userId));
    }
    return (
      path,
      SlackMessage(
        channel: channel,
        ts: eventTs,
        by: SlackActorId.forWorkspace(workspaceId: workspace, userId: userId),
        text: text,
        threadTs: rawThreadTs,
      ),
    );
  }

  if (subtype == 'message_changed') {
    // event.message is the new state; event.previous_message is the prior.
    // The *edit's* actor and ts live on event.message (Slack puts the editor
    // under message.edited.user for API callers, but the event.message's own
    // `user`/`ts` always match the current state, which is what we record).
    final message = raw['message'];
    final previousTs =
        (raw['previous_message'] is Map ? raw['previous_message']['ts'] : null)
            as String?;
    if (message is! Map ||
        previousTs == null ||
        message['user'] is! String ||
        message['text'] is! String ||
        message['ts'] is! String) {
      return (path, _raw(raw, channel, anchor, workspace));
    }
    final replaced = lookup?.call(path, previousTs);
    if (replaced == null) {
      // Can't anchor the edit without a prior TurnId; keep the faithful raw
      // record so a later promotion can rewrite it as a SlackEdit.
      return (path, _raw(raw, channel, anchor, workspace));
    }
    return (
      path,
      SlackEdit(
        replaces: replaced,
        channel: channel,
        editTs: message['ts'] as String,
        by: SlackActorId.forWorkspace(
          workspaceId: workspace,
          userId: message['user'] as String,
        ),
        newText: message['text'] as String,
      ),
    );
  }

  if (subtype == 'message_deleted') {
    // Slack puts the deletor at the top level (`event.user`) when available;
    // the gone message's ts is at `event.deleted_ts` or `event.previous_message.ts`.
    final deletorId = event.user;
    final deletedTs = raw['deleted_ts'] as String? ??
        ((raw['previous_message'] is Map
            ? raw['previous_message']['ts']
            : null) as String?);
    final eventTs = event.eventTs;
    if (deletorId == null || deletedTs == null || eventTs == null) {
      return (path, _raw(raw, channel, anchor, workspace, userId: deletorId));
    }
    final target = lookup?.call(path, deletedTs);
    if (target == null) {
      return (path, _raw(raw, channel, anchor, workspace, userId: deletorId));
    }
    return (
      path,
      SlackTombstone(
        target: target,
        by: SlackActorId.forWorkspace(
          workspaceId: workspace,
          userId: deletorId,
        ),
        ts: eventTs,
      ),
    );
  }

  // Unrecognised subtype — faithful mirror, no field loss.
  return (path, _raw(raw, channel, anchor, workspace));
}

/// Resolves a [relay.SlackReactionAdded] into a `(SlackThread, SlackReaction)`.
/// On a locate-miss (mirror has never seen the target) falls back to
/// `SlackEventRaw` keyed as if the target's ts were the thread anchor —
/// correct for reactions on top-level messages, best-effort otherwise.
(SlackThread, SlackNode) parseReactionAddedToSlackNode(
  relay.SlackReactionAdded event, {
  SlackChannelTsLocate? locate,
}) {
  final workspace = event.workspace;
  final channel = event.channel;
  final userId = event.user;
  final emoji = event.reaction;
  final targetTs = event.targetTs;
  final eventTs = event.eventTs;
  final raw = event.rawEvent;

  final hit = locate?.call(channel, targetTs);
  if (hit == null) {
    // No target in the mirror — can't anchor the SlackReaction (its `target`
    // field is required). Fall back to a faithful raw record keyed on the
    // best-available journey, so nothing is dropped. target_ts is usually
    // the thread_ts for top-level reactions; for mid-thread reactions this
    // is a best-effort guess, deliberately NOT fabricating a SlackReaction.
    final path = SlackThread(
      workspace: workspace,
      channel: channel,
      threadTs: targetTs,
    );
    return (path, _raw(raw, channel, targetTs, workspace, userId: userId));
  }
  return (
    hit.path,
    SlackReaction(
      target: hit.id,
      emoji: emoji,
      by: SlackActorId.forWorkspace(
        workspaceId: workspace,
        userId: userId,
      ),
      ts: eventTs,
    ),
  );
}

/// Turns a [relay.SlackReactionRemoved] into a
/// `(SlackThread, Withdraw<SlackReaction>)`, or null when the mirror has no
/// record of the target message or the reaction being undone.
///
/// Slack identifies the reaction indirectly by `(targetTs, reaction, user)`;
/// `Withdraw<SlackReaction>` needs the exact `TurnId` of the original
/// `SlackReaction` node (is_shapes doctrine: a withdraw targets one node,
/// not an anchor). So the parser does two lookups: [locate] to resolve the
/// target message's id and journey, [findReaction] to resolve the specific
/// reaction node on that journey.
///
/// A null return is not an error — the mirror may be cold, or the original
/// reaction-added event may have been missed. The caller logs and drops.
(SlackThread, Withdraw<SlackReaction>)? parseReactionRemovedToWithdraw(
  relay.SlackReactionRemoved event, {
  required SlackChannelTsLocate locate,
  required SlackReactionFinder findReaction,
}) {
  final workspace = event.workspace;
  final channel = event.channel;
  final userId = event.user;
  final emoji = event.reaction;
  final targetTs = event.targetTs;

  final target = locate(channel, targetTs);
  if (target == null) return null;
  final by = SlackActorId.forWorkspace(
    workspaceId: workspace,
    userId: userId,
  );
  final reactionId = findReaction(target: target.id, emoji: emoji, by: by);
  if (reactionId == null) return null;
  return (target.path, Withdraw<SlackReaction>(target: reactionId, by: by));
}

SlackEventRaw _raw(
  Map<String, dynamic> raw,
  String channel,
  String anchor,
  String workspace, {
  String? userId,
}) {
  final slackEventType = raw['type'] is String ? raw['type'] as String : 'unknown';
  final ts = raw['event_ts'] is String
      ? raw['event_ts'] as String
      : (raw['ts'] is String ? raw['ts'] as String : anchor);
  final rawUser = userId ?? (raw['user'] is String ? raw['user'] as String : null);
  return SlackEventRaw(
    slackEventType: slackEventType,
    channel: channel,
    ts: ts,
    by: rawUser == null
        ? null
        : SlackActorId.forWorkspace(
            workspaceId: workspace,
            userId: rawUser,
          ),
    rawPayload: jsonEncode(raw),
  );
}
