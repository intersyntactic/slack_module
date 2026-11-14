/// The externally-anchored mirror: one record per [SlackNode] write, minting
/// a [TurnId] from `sha256(shape-tag ++ 0x00 ++ canonical-json(fields))` and
/// indexing it under its [SlackThread] and, where the shape carries one, its
/// `(channel, ts)`.
///
/// Flat by design: every lookup here is a map read, not a walk. There is no
/// stored parent-chain and no reconstructable thread history — nothing in
/// this module needs either today. A node's own fields always carry Slack's
/// own ts, which is unique per message, so dropping the chain costs nothing
/// in id-uniqueness: two different events never hash to the same id because
/// their own fields (including `ts`) differ.
///
/// - **Epoch per path.** Starts at 1. An `adopt` op (per §8.6) will bump a
///   path's epoch and bind outbound Slack message metadata to it, so a zombie
///   receiver's post is recognised as foreign. Not implemented here; the
///   epoch read is in the interface so callers don't need a second lookup
///   when they wire `adopt` in.
///
/// Nothing is ever erased: write-then-fail leaves the node recorded, and
/// deletion is a [SlackTombstone] node of its own. This matches the shape
/// family's invariant and is the reason there is no `remove` method here.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_shapes/is_shapes.dart';

import 'slack_thread.dart';
import 'shapes.dart';

abstract interface class SlackMirror {
  /// Records [node] under [path] and returns its minted [TurnId].
  TurnId write(SlackThread path, SlackNode node);

  /// The [TurnId] on [path] whose node's Slack `ts` equals [ts], or null if
  /// no such node is in the mirror. Used by `gate_parser.dart`'s
  /// [SlackMessageLookup] to anchor edits and tombstones to the message they
  /// replace or remove. O(1): a flat `(channel, ts)` lookup, restricted to
  /// [path]'s channel.
  ///
  /// Only matches shapes that carry a channel of their own (`SlackMessage`,
  /// `SlackEdit`, `SlackEventRaw`) — see [locate]. In practice the target of
  /// an edit or tombstone is always a message, so this is no narrower than
  /// what callers need.
  TurnId? find(SlackThread path, String ts);

  /// Reverse index: the node at `(channel, ts)`, with the journey it's on.
  /// O(1) lookup against a map maintained on write. Covers shapes that carry
  /// a channel directly — `SlackMessage`, `SlackEdit`, `SlackEventRaw`; a
  /// `SlackReaction` has no channel of its own (it references its target) so
  /// is indexed via that target. A `SlackTombstone` is not indexed.
  ///
  /// Used by the reaction path in `gate_parser.dart`: a reaction event
  /// carries `event.item.channel` and `event.item.ts` (the target message's
  /// ts), from which both the target's `TurnId` and the journey it sits on
  /// are needed.
  ({TurnId id, SlackThread path})? locate(String channel, String ts);

  /// The journey a node is on, or null if the mirror has never seen it.
  SlackThread? pathOf(TurnId id);

  /// The `TurnId` of a reaction node whose fields `(target, emoji, by)` match
  /// the arguments; null if none exists. O(1): a flat index keyed by that
  /// triple, maintained on write. Used to resolve `reaction_removed` to the
  /// exact `SlackReaction` it withdraws — Slack identifies the reaction
  /// indirectly via `(message, emoji, user)`, and `Withdrawal<SlackReaction>`
  /// requires the exact `TurnId` of what it undoes (per is_shapes' doctrine:
  /// a withdraw targets one node, not an anchor).
  TurnId? findReaction({
    required TurnId target,
    required String emoji,
    required ActorId by,
  });

  /// Records a `Withdrawal<SlackReaction>` in the mirror's side table — a
  /// withdrawal does NOT create a new [SlackNode] record (the sealed family
  /// deliberately has no `SlackReactionWithdrawn` variant; the withdrawal IS
  /// how reactions are taken back, per is_shapes' doctrine). After this,
  /// [withdrawnBy] returns `withdraw` for its target.
  void writeWithdraw(Withdrawal<SlackReaction> withdraw);

  /// The withdrawal targeting [target], or null if it has not been withdrawn.
  /// A reader asks this to decide whether an earlier reaction still counts.
  Withdrawal<SlackReaction>? withdrawnBy(TurnId target);

  /// The current epoch of [path]. Starts at 1 on first write; stays at 1
  /// until an `adopt`-like op bumps it. See §8.6.
  int epochFor(SlackThread path);

  /// The node at [id], or null if the mirror has never seen it.
  SlackNode? nodeAt(TurnId id);
}

final class InMemorySlackMirror implements SlackMirror {
  InMemorySlackMirror();

  final Map<SlackThread, int> _epochs = {};
  final Map<TurnId, _Entry> _nodes = {};

  /// `(channel, ts) → TurnId` reverse index. Keys are built by `_channelTsKey`,
  /// which concatenates channel + 0x00 + ts so a channel-id ending in digits
  /// and a numeric ts can't collide across boundaries.
  final Map<String, TurnId> _byChannelTs = {};

  /// `(target, emoji, by) → TurnId` reverse index for `SlackReaction` nodes.
  final Map<String, TurnId> _byReaction = {};

  /// Side table for `Withdrawal<SlackReaction>`. See [writeWithdraw] — the
  /// doctrine keeps withdrawals out of the node record.
  final Map<TurnId, Withdrawal<SlackReaction>> _withdrawals = {};

  @override
  TurnId write(SlackThread path, SlackNode node) {
    final id = _mintId(node);
    _nodes[id] = _Entry(node: node, path: path);
    _epochs.putIfAbsent(path, () => 1);
    final indexable = _channelTsKey(node);
    if (indexable != null) {
      // First-write-wins: a later shape with the same (channel, ts) must not
      // shadow the original. In practice Slack's ts is channel-unique per
      // message, so this guards only against a buggy producer putting two
      // events at the same (channel, ts) into the mirror.
      _byChannelTs.putIfAbsent(indexable, () => id);
    }
    if (node is SlackReaction) {
      // Last-write-wins: unlike (channel, ts), the (target, emoji, by) triple
      // is not expected to be unique — a remove-then-re-add cycle writes two
      // SlackReaction nodes under the same triple, and findReaction must
      // resolve to the newest one (matching the old chain-walk's head-first
      // traversal, which found the most recent match).
      _byReaction[_reactionKey(node.target, node.emoji, node.by)] = id;
    }
    return id;
  }

  @override
  int epochFor(SlackThread path) => _epochs[path] ?? 1;

  @override
  SlackNode? nodeAt(TurnId id) => _nodes[id]?.node;

  @override
  TurnId? find(SlackThread path, String ts) {
    final id = _byChannelTs['${path.channel}\u0000$ts'];
    if (id == null) return null;
    final entry = _nodes[id];
    if (entry == null || entry.path != path) return null;
    return id;
  }

  @override
  ({TurnId id, SlackThread path})? locate(String channel, String ts) {
    final id = _byChannelTs['$channel\u0000$ts'];
    if (id == null) return null;
    final entry = _nodes[id];
    if (entry == null) return null;
    return (id: id, path: entry.path);
  }

  @override
  SlackThread? pathOf(TurnId id) => _nodes[id]?.path;

  @override
  TurnId? findReaction({
    required TurnId target,
    required String emoji,
    required ActorId by,
  }) =>
      _byReaction[_reactionKey(target, emoji, by)];

  @override
  void writeWithdraw(Withdrawal<SlackReaction> withdraw) {
    _withdrawals[withdraw.target] = withdraw;
  }

  @override
  Withdrawal<SlackReaction>? withdrawnBy(TurnId target) => _withdrawals[target];
}

/// Build the `(channel, ts)` index key for a node, or null for shapes that
/// don't carry a channel of their own. A `SlackReaction` has no channel —
/// its position in the channel space is through its target — and a
/// `SlackTombstone` is deliberately excluded (its ts is the deletion event's
/// ts, which is seldom asked for by `(channel, ts)` and would shadow nothing).
String? _channelTsKey(SlackNode node) => switch (node) {
      SlackMessage(:final channel, :final ts) => '$channel\u0000$ts',
      SlackEdit(:final channel, :final editTs) => '$channel\u0000$editTs',
      SlackEventRaw(:final channel, :final ts) =>
          channel.isEmpty ? null : '$channel\u0000$ts',
      SlackReaction() => null,
      SlackTombstone() => null,
    };

String _reactionKey(TurnId target, String emoji, ActorId by) =>
    '$target\u0000$emoji\u0000$by';

class _Entry {
  const _Entry({required this.node, required this.path});
  final SlackNode node;
  final SlackThread path;
}

TurnId _mintId(SlackNode node) {
  final (tag, fields) = _encode(node);
  final seed = <int>[
    ...utf8.encode(tag),
    0,
    ...utf8.encode(_canonicalJson(fields)),
  ];
  return TurnId.of(Uint8List.fromList(seed));
}

(String, Map<String, Object?>) _encode(SlackNode node) => switch (node) {
      SlackMessage() => (
          'slack_message',
          {
            'by': node.by.toString(),
            'channel': node.channel,
            'text': node.text,
            'thread_ts': node.threadTs,
            'ts': node.ts,
          },
        ),
      SlackEdit() => (
          'slack_edit',
          {
            'by': node.by.toString(),
            'channel': node.channel,
            'edit_ts': node.editTs,
            'new_text': node.newText,
            'replaces': node.replaces.toString(),
          },
        ),
      SlackReaction() => (
          'slack_reaction',
          {
            'by': node.by.toString(),
            'emoji': node.emoji,
            'target': node.target.toString(),
            'ts': node.ts,
          },
        ),
      SlackTombstone() => (
          'slack_tombstone',
          {
            'by': node.by.toString(),
            'target': node.target.toString(),
            'ts': node.ts,
          },
        ),
      SlackEventRaw() => (
          'slack_event_raw',
          {
            'by': node.by?.toString(),
            'channel': node.channel,
            'raw_payload': node.rawPayload,
            'slack_event_type': node.slackEventType,
            'ts': node.ts,
          },
        ),
    };

/// Sorted-key JSON, no whitespace. Given the same node, two runs mint the
/// same id (across processes, across machines). `dart:convert`'s `jsonEncode`
/// preserves Map insertion order, so we sort the keys explicitly.
String _canonicalJson(Map<String, Object?> fields) {
  final sorted = <String, Object?>{};
  for (final k in fields.keys.toList()..sort()) {
    sorted[k] = fields[k];
  }
  return jsonEncode(sorted);
}
