/// The externally-anchored mirror: one head per [JourneyPathId], with every
/// [SlackNode] write minting a [TurnId] from `sha256(parent-id-hex ++ 0x00 ++
/// shape-tag ++ 0x00 ++ canonical-json(fields))`.
///
/// Why this shape, next to teams_module's `StandInJourneyPath`:
///
/// - **Keying.** Teams' stand-in has one linear path with no key. Slack lives
///   in many threads at once, so the mirror must address a path. A value-typed
///   [JourneyPathId] in, not a bare String.
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

import 'journey_path_id.dart';
import 'shapes.dart';

abstract interface class SlackMirror {
  /// Appends [node] to the chain at [path] and returns its minted [TurnId].
  /// If [path] has no head yet, [node] becomes the head (its parent is the
  /// empty digest-seed, so first-node ids are reproducible per-path from
  /// path-independent inputs).
  TurnId write(JourneyPathId path, SlackNode node);

  /// The current head of [path], or null if nothing has been written there.
  TurnId? headFor(JourneyPathId path);

  /// The current epoch of [path]. Starts at 1 on first write; stays at 1
  /// until an `adopt`-like op bumps it. See §8.6.
  int epochFor(JourneyPathId path);

  /// Walks [head] back to the root, yielding each node in reverse-chronological
  /// order (newest first). Throws [StateError] if [head] is not in the mirror.
  Iterable<SlackNode> walk(TurnId head);

  /// The node at [id], or null if the mirror has never seen it.
  SlackNode? nodeAt(TurnId id);
}

final class InMemorySlackMirror implements SlackMirror {
  InMemorySlackMirror();

  final Map<JourneyPathId, TurnId> _heads = {};
  final Map<JourneyPathId, int> _epochs = {};
  final Map<TurnId, _Entry> _nodes = {};

  @override
  TurnId write(JourneyPathId path, SlackNode node) {
    final parent = _heads[path];
    final id = _mintId(parent, node);
    _nodes[id] = _Entry(parent: parent, node: node, path: path);
    _heads[path] = id;
    _epochs.putIfAbsent(path, () => 1);
    return id;
  }

  @override
  TurnId? headFor(JourneyPathId path) => _heads[path];

  @override
  int epochFor(JourneyPathId path) => _epochs[path] ?? 1;

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
}

class _Entry {
  const _Entry({required this.parent, required this.node, required this.path});
  final TurnId? parent;
  final SlackNode node;
  final JourneyPathId path;
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
