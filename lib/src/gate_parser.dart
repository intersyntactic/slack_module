/// Turns a `slackGate` doorbell payload into a `(SlackThread, SlackNode)`
/// pair the receiver can feed straight into its mirror.
///
/// This is the "doorbell-carries-text" side of §8.1's open decision: the gate
/// already forwards `event.text` and friends, so the parser does not call
/// `conversations.history` (per §8 Done-when rule 1: "all without the receiver
/// calling `conversations.replies` after the first-ever message of the
/// thread").
///
/// What this parser covers today:
///
///   - `slack_message`, `slack_mention` with no subtype → `SlackMessage`.
///   - `slack_message` with `subtype == "message_changed"`  → `SlackEdit`, iff
///     [lookup] resolves the replaced message's `TurnId`. Without a resolver
///     (or on a miss) the event falls back to `SlackEventRaw` so the mirror
///     stays faithful and a later turn can promote the shape.
///   - `slack_message` with `subtype == "message_deleted"` → `SlackTombstone`,
///     same lookup rule as edits.
///   - Any other subtype, or any `event` discriminator the parser doesn't
///     recognise → `SlackEventRaw` carrying the full inner event as JSON.
///
/// What this parser DOES NOT cover yet:
///
///   - Slash commands. They don't flow into the mirror — they are consumed by
///     the model-selection surface — so the parser deliberately rejects
///     `slack_command` doorbells with an [ArgumentError] rather than silently
///     fabricating a SlackEventRaw.
///
/// Reactions:
///
///   - `slack_reaction_added` is handled by this parser, emitting a
///     `SlackReaction`. It needs a [SlackChannelTsLocate] to resolve the
///     target message's `TurnId` and `SlackThread` in one query. On a miss
///     (the mirror has never seen the target) the parser falls back to
///     `SlackEventRaw` keyed as if the target's ts were the thread anchor —
///     correct for reactions-on-top-level messages, best-effort otherwise.
///   - `slack_reaction_removed` is handled by [parseDoorbellToWithdraw]
///     instead, which produces a `Withdraw<SlackReaction>`. A withdrawal is
///     not a `SlackNode`, so it cannot live in this function's return type.
library;

import 'dart:convert';

import 'package:is_shapes/is_shapes.dart';

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
/// carries `event.item.channel` and `event.item.ts` but no thread_ts, so
/// the journey can only be learned from a mirror index.
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

(SlackThread, SlackNode) parseDoorbellToSlackNode(
  Map<String, dynamic> doorbell, {
  SlackMessageLookup? lookup,
  SlackChannelTsLocate? locate,
}) {
  final event = doorbell['event'];
  if (event == 'slack_reaction_added') {
    return _reactionAdded(doorbell, locate);
  }
  if (event == 'slack_reaction_removed') {
    throw ArgumentError.value(
      event,
      'doorbell[event]',
      'use parseDoorbellToWithdraw for slack_reaction_removed; '
          'Withdraw<SlackReaction> is not a SlackNode',
    );
  }
  if (event != 'slack_mention' && event != 'slack_message') {
    throw ArgumentError.value(
      event,
      'doorbell[event]',
      'parser handles slack_mention, slack_message and '
          'slack_reaction_added; slack_command is consumed elsewhere',
    );
  }

  final workspace = doorbell['team'] as String;
  final channel = doorbell['channel'] as String;
  final anchor = doorbell['thread_ts'] as String;
  final path = SlackThread(
    workspace: workspace,
    channel: channel,
    threadTs: anchor,
  );

  final subtype = doorbell['subtype'] as String?;
  final raw = doorbell['raw_event'] as Map<String, dynamic>? ?? const {};

  if (subtype == null) {
    // Plain message or app_mention. Fields come straight from the doorbell.
    final userId = doorbell['user'] as String?;
    final text = doorbell['text'] as String?;
    final eventTs = doorbell['event_ts'] as String?;
    final rawThreadTs = doorbell['raw_thread_ts'] as String?;
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
    final deletorId = doorbell['user'] as String?;
    final deletedTs = raw['deleted_ts'] as String? ??
        ((raw['previous_message'] is Map
            ? raw['previous_message']['ts']
            : null) as String?);
    final eventTs = doorbell['event_ts'] as String?;
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

/// Resolves `slack_reaction_added` into a `(SlackThread, SlackReaction)`.
/// On a locate-miss (mirror has never seen the target) falls back to
/// `SlackEventRaw` keyed as if the target's ts were the thread anchor —
/// correct for reactions on top-level messages, best-effort otherwise.
(SlackThread, SlackNode) _reactionAdded(
  Map<String, dynamic> doorbell,
  SlackChannelTsLocate? locate,
) {
  final workspace = doorbell['team'] as String;
  final channel = doorbell['channel'] as String;
  final userId = doorbell['user'] as String;
  final emoji = doorbell['reaction'] as String;
  final targetTs = doorbell['target_ts'] as String;
  final eventTs = doorbell['event_ts'] as String;
  final raw = doorbell['raw_event'] as Map<String, dynamic>? ?? const {};

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

/// Turns a `slack_reaction_removed` doorbell into a
/// `(SlackThread, Withdraw<SlackReaction>)`, or null when the mirror has no
/// record of the target message or the reaction being undone.
///
/// Slack identifies the reaction indirectly by `(target_ts, reaction, user)`;
/// `Withdraw<SlackReaction>` needs the exact `TurnId` of the original
/// `SlackReaction` node (is_shapes doctrine: a withdraw targets one node,
/// not an anchor). So the parser does two lookups: [locate] to resolve the
/// target message's id and journey, [findReaction] to resolve the specific
/// reaction node on that journey.
///
/// A null return is not an error — the mirror may be cold, or the original
/// `reaction_added` may have been missed. The caller logs and drops.
(SlackThread, Withdraw<SlackReaction>)? parseDoorbellToWithdraw(
  Map<String, dynamic> doorbell, {
  required SlackChannelTsLocate locate,
  required SlackReactionFinder findReaction,
}) {
  final event = doorbell['event'];
  if (event != 'slack_reaction_removed') {
    throw ArgumentError.value(
      event,
      'doorbell[event]',
      'parseDoorbellToWithdraw handles slack_reaction_removed only',
    );
  }
  final workspace = doorbell['team'] as String;
  final channel = doorbell['channel'] as String;
  final userId = doorbell['user'] as String;
  final emoji = doorbell['reaction'] as String;
  final targetTs = doorbell['target_ts'] as String;

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
