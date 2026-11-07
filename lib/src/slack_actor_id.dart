/// Helpers that mint Slack-sourced [ActorId]s in the format ruled by Nick on
/// 2026-11-06: `slack:<workspace_id>/<user_id>` for ordinary workspaces,
/// `slack:<enterprise_id>/<user_id>` for Enterprise Grid orgs. The authority
/// (workspace or enterprise) sits before the `/` because it owns the
/// id-namespace. In Grid, user identity lives at the enterprise level, so
/// using workspace id there would give one person different actor ids
/// depending on which workspace the event came through.
///
/// Every Slack-authored `ActorId` the module produces goes through here, so
/// the grammar is enforced in exactly one place — before `ActorId.parse` sees
/// the string.
library;

import 'package:is_shapes/is_shapes.dart';

final class SlackActorId {
  const SlackActorId._();

  /// A Slack user in an ordinary (non-Grid) workspace. [workspaceId] is
  /// Slack's `team_id` payload field (legacy name from Slack's early days;
  /// `T...` prefix).
  static ActorId forWorkspace({
    required String workspaceId,
    required String userId,
  }) =>
      ActorId.parse('slack:$workspaceId/$userId')!;

  /// A Slack user in an Enterprise Grid org. [enterpriseId] is Slack's
  /// `enterprise_id` payload field (`E...` prefix). Use this instead of
  /// [forWorkspace] whenever the event carries an `enterprise_id`.
  static ActorId forGrid({
    required String enterpriseId,
    required String userId,
  }) =>
      ActorId.parse('slack:$enterpriseId/$userId')!;
}
