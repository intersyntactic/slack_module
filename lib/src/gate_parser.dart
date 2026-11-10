/// Turns a `slackGate` doorbell payload into a `(JourneyPathId, SlackNode)`
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
///   - Reactions. `reaction_added` and `reaction_removed` are not in the
///     gate's default wake set yet because their journey-path anchor lives
///     on the target message, not on the reaction event itself, and resolving
///     it needs a mirror lookup that'd widen this slice. They land once the
///     `Withdraw<SlackReaction>` receiver seam is designed.
///   - Slash commands. They don't flow into the mirror — they are consumed by
///     the model-selection surface — so the parser deliberately rejects
///     `slack_command` doorbells with an [ArgumentError] rather than silently
///     fabricating a SlackEventRaw.
library;

import 'dart:convert';

import 'package:is_shapes/is_shapes.dart';

import 'journey_path_id.dart';
import 'shapes.dart';
import 'slack_actor_id.dart';

/// Resolves the `TurnId` of a prior Slack message by its `(path, ts)`, or
/// returns null if the mirror has no record of it. Typically backed by the
/// mirror itself. A null resolver, or a null return, is not an error: the
/// parser falls back to `SlackEventRaw` so nothing is dropped.
typedef SlackMessageLookup = TurnId? Function(JourneyPathId path, String ts);

(JourneyPathId, SlackNode) parseDoorbellToSlackNode(
  Map<String, dynamic> doorbell, {
  SlackMessageLookup? lookup,
}) {
  final event = doorbell['event'];
  if (event != 'slack_mention' && event != 'slack_message') {
    throw ArgumentError.value(
      event,
      'doorbell[event]',
      'parser handles slack_mention and slack_message only; '
          'slack_command is consumed elsewhere',
    );
  }

  final workspace = doorbell['team'] as String;
  final channel = doorbell['channel'] as String;
  final anchor = doorbell['thread_ts'] as String;
  final path = JourneyPathId(
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
