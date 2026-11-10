/// The externally-anchored mirror: one head per [JourneyId], with every
/// [SlackNode] write minting a [TurnId] from `sha256(parent-id-hex ++ 0x00 ++
/// shape-tag ++ 0x00 ++ canonical-json(fields))`.
///
/// Why this shape, next to teams_module's `StandInJourneyPath`:
///
/// - **Keying.** Teams' stand-in has one linear path with no key. Slack lives
///   in many threads at once, so the mirror must address a path. A value-typed
///   [JourneyId] in, not a bare String.
/// - **Same id formula as Teams' stand-in** (parent id + the node's own bytes),
///   so when Teams grows past the stand-in, the id spaces line up and nothing
///   has to renegotiate what a TurnId means.
/// - **Epoch per path.** Starts at 1. An `adopt` op (per §8.6) will bump a
///   path's epoch and bind outbound Slack message metadata to it, so a zombie
///   receiver's post is recognised as foreign. Not implemented here; the
///   epoch read is in the interface so callers don't need a second lookup
///   when they wire `adopt` in.
///
/// Nothing is ever erased: write-then-fail leaves the node in the chain, and
/// deletion is a [SlackTombstone] node of its own. This matches the shape
/// family's invariant and is the reason there is no `remove` method here.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_shapes/is_shapes.dart';

import 'journey_id.dart';
import 'shapes.dart';

abstract interface class SlackMirror {
  /// Appends [node] to the chain at [path] and returns its minted [TurnId].
  /// If [path] has no head yet, [node] becomes the head (its parent is the
  /// empty digest-seed, so first-node ids are reproducible per-path from
  /// path-independent inputs).
  TurnId write(JourneyId path, SlackNode node);

  /// The current head of [path], or null if nothing has been written there.
  TurnId? headFor(JourneyId path);

  /// The [TurnId] on [path] whose node's Slack `ts` equals [ts], or null if
  /// no such node is in the chain. Used by `gate_parser.dart`'s
  /// [SlackMessageLookup] to anchor edits and tombstones to the message they
  /// replace or remove. Walks the chain from the head; O(chain-length). For
  /// threads of normal length that is a handful of nodes.
  ///
  /// The walk visits every shape (`SlackMessage`, `SlackEdit`,
  /// `SlackReaction`, `SlackTombstone`, `SlackEventRaw`) and matches the
  /// first `ts` collision — in practice Slack's message `ts` is thread-unique
  /// so the result is always the original message, but a caller that needs
  /// to distinguish "find a message" from "find any node at this ts" should
  /// filter the returned node via `nodeAt`.
  TurnId? find(JourneyId path, String ts);

  /// Reverse index: the node at `(channel, ts)`, with the journey it's on.
  /// O(1) lookup against a map maintained on write. Covers shapes that carry
  /// a channel directly — `SlackMessage`, `SlackEdit`, `SlackEventRaw`; a
  /// `SlackReaction` has no channel of its own (it references its target) so
  /// is indexed via that target. A `SlackTombstone` is not indexed.
  ///
  /// Used by the reaction path in `gate_parser.dart`: a reaction event
  /// carries `event.item.channel` and `event.item.ts` (the target message's
  /// ts), from which both the target's `TurnId` and the journey it sits on
  /// are needed. Edits and tombstones could in principle use this too; they
  /// currently continue to use [find] for continuity with the pre-reaction
  /// code — the two indexes agree for Slack-issued ts values, which are
  /// channel-unique.
  ({TurnId id, JourneyId path})? locate(String channel, String ts);

  /// The journey a node is on, or null if the mirror has never seen it.
  JourneyId? pathOf(TurnId id);

  /// The `TurnId` of a reaction node on the same path as [target] whose
  /// fields `(target, emoji, by)` match the arguments; null if none exists.
  /// Walks the chain from the head of `target`'s path. Used to resolve
  /// `reaction_removed` to the exact `SlackReaction` it withdraws — Slack
  /// identifies the reaction indirectly via `(message, emoji, user)`, and
  /// `Withdraw<SlackReaction>` requires the exact `TurnId` of what it undoes
  /// (per is_shapes' doctrine: a withdraw targets one node, not an anchor).
  TurnId? findReaction({
    required TurnId target,
    required String emoji,
    required ActorId by,
  });

  /// Records a `Withdraw<SlackReaction>` in the mirror's side table — a
  /// withdrawal does NOT append a new [SlackNode] to the chain (the sealed
  /// family deliberately has no `SlackReactionWithdrawn` variant; the
  /// withdrawal IS how reactions are taken back, per is_shapes' doctrine).
  /// After this, [withdrawnBy] returns `withdraw` for its target.
  void writeWithdraw(Withdraw<SlackReaction> withdraw);

  /// The withdrawal targeting [target], or null if it has not been withdrawn.
  /// A reader asks this to decide whether an earlier reaction still counts.
  Withdraw<SlackReaction>? withdrawnBy(TurnId target);

  /// The current epoch of [path]. Starts at 1 on first write; stays at 1
  /// until an `adopt`-like op bumps it. See §8.6.
  int epochFor(JourneyId path);

  /// Walks [head] back to the root, yielding each node in reverse-chronological
  /// order (newest first). Throws [StateError] if [head] is not in the mirror.
  Iterable<SlackNode> walk(TurnId head);

  /// The node at [id], or null if the mirror has never seen it.
  SlackNode? nodeAt(TurnId id);
}

final class InMemorySlackMirror implements SlackMirror {
  InMemorySlackMirror();

  final Map<JourneyId, TurnId> _heads = {};
  final Map<JourneyId, int> _epochs = {};
  final Map<TurnId, _Entry> _nodes = {};

  /// `(channel, ts) → TurnId` reverse index. Keys are built by `_indexKey`,
  /// which concatenates channel + 0x00 + ts so a channel-id ending in digits
  /// and a numeric ts can't collide across boundaries.
  final Map<String, TurnId> _byChannelTs = {};

  /// Side table for `Withdraw<SlackReaction>`. See [writeWithdraw] — the
  /// doctrine keeps withdrawals off the main node chain.
  final Map<TurnId, Withdraw<SlackReaction>> _withdrawals = {};

  @override
  TurnId write(JourneyId path, SlackNode node) {
    final parent = _heads[path];
    final id = _mintId(parent, node);
    _nodes[id] = _Entry(parent: parent, node: node, path: path);
    _heads[path] = id;
    _epochs.putIfAbsent(path, () => 1);
    final indexable = _channelTsKey(node);
    if (indexable != null) {
      // First-write-wins: a later shape with the same (channel, ts) must not
      // shadow the original. In practice Slack's ts is channel-unique per
      // message, so this guards only against a buggy producer putting two
      // events at the same (channel, ts) into the mirror.
      _byChannelTs.putIfAbsent(indexable, () => id);
    }
    return id;
  }

  @override
  TurnId? headFor(JourneyId path) => _heads[path];

  @override
  int epochFor(JourneyId path) => _epochs[path] ?? 1;

  @override
  Iterable<SlackNode> walk(TurnId head) sync* {
    var cursor = _nodes[head];
    if (cursor == null) {
      throw StateError('walk: $head not in mirror');
    }
    while (cursor != null) {
      yield cursor.node;
      final p = cursor.parent;
      cursor = p == null ? null : _nodes[p];
    }
  }

  @override
  SlackNode? nodeAt(TurnId id) => _nodes[id]?.node;

  @override
  TurnId? find(JourneyId path, String ts) {
    var cursor = _heads[path];
    while (cursor != null) {
      final entry = _nodes[cursor];
      if (entry == null) return null;
      if (_tsOf(entry.node) == ts) return cursor;
      cursor = entry.parent;
    }
    return null;
  }

  @override
  ({TurnId id, JourneyId path})? locate(String channel, String ts) {
    final id = _byChannelTs['$channel\u0000$ts'];
    if (id == null) return null;
    final entry = _nodes[id];
    if (entry == null) return null;
    return (id: id, path: entry.path);
  }

  @override
  JourneyId? pathOf(TurnId id) => _nodes[id]?.path;

  @override
  TurnId? findReaction({
    required TurnId target,
    required String emoji,
    required ActorId by,
  }) {
    final path = _nodes[target]?.path;
    if (path == null) return null;
    var cursor = _heads[path];
    while (cursor != null) {
      final entry = _nodes[cursor];
      if (entry == null) return null;
      final node = entry.node;
      if (node is SlackReaction &&
          node.target == target &&
          node.emoji == emoji &&
          node.by == by) {
        return cursor;
      }
      cursor = entry.parent;
    }
    return null;
  }

  @override
  void writeWithdraw(Withdraw<SlackReaction> withdraw) {
    _withdrawals[withdraw.target] = withdraw;
  }

  @override
  Withdraw<SlackReaction>? withdrawnBy(TurnId target) => _withdrawals[target];
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

String? _tsOf(SlackNode node) => switch (node) {
      SlackMessage(:final ts) => ts,
      SlackEdit(:final editTs) => editTs,
      SlackReaction(:final ts) => ts,
      SlackTombstone(:final ts) => ts,
      SlackEventRaw(:final ts) => ts,
    };

class _Entry {
  const _Entry({required this.parent, required this.node, required this.path});
  final TurnId? parent;
  final SlackNode node;
  final JourneyId path;
}

TurnId _mintId(TurnId? parent, SlackNode node) {
  final (tag, fields) = _encode(node);
  final seed = <int>[
    ...utf8.encode(parent?.toString() ?? ''),
    0,
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
