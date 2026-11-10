# .intersyntactic/

Module manifest for `intersyntactic_slack`. Discoverable by intersyntactic at
composition time; versioned with the code (not with the user's home-pinned
runtime state, which lives in `~/.intersyntactic/lines/<line_id>/`).

The format follows [`composition.md`](https://github.com/enspyrco/intersyntactic/blob/main/docs/design/composition.md)
(PROPOSED 2026-11-04, ratified as the state of truth by Nick 2026-11-05):
**acceptors** are places this module opens for others; **offerings** are what
this module brings to theirs. The core binds each offering at the acceptors it
names, refusing a mismatch with its reason before anything runs.

See [`manifest.json`](./manifest.json) for the declared shape, and
[`../docs/externally-anchored-lines.md`](../docs/externally-anchored-lines.md)
for how a Slack-anchored line works as a kind of line.

## Format

JSON. Chosen over YAML's parser footguns (the Norway problem: `no` → `false`)
and typed Dart's non-portability at composition time. The trade-off is no
inline comments; this README absorbs the explanations.

## Shape

The Slack module:

- **Opens one acceptor**, `slack_mirror`. Shape: a Slack-anchored node
  (`message`, `edit`, `reaction`, `tombstone`, or `slack_event_raw`). Use:
  keep the mirror of a Slack-anchored line in sync with Slack. From: other
  modules — the orchestrator (`composition.md` §7) delivers nodes here after
  resolving an incoming webhook to its line.
- **Offers five node shapes** at `slack_mirror`: the four typed shapes plus
  the catch-all `slack_event_raw`, which carries a `slack_event_type`
  discriminator. The catch-all is what lets composition.md §2's "a node of
  a shape nothing bound is refused" rule hold without Slack events going
  missing when Slack adds a new subtype we haven't typed yet.
- **Offers four tool effects** at a `tools` acceptor (opened by intersyntactic's `agent_loop` module): `chat_post`,
  `chat_update`, `chat_delete`, `reactions_add`. These describe HTTP
  effects only; a web driver operates the Slack API and the airlock adds
  the bot token (`drivers` ruling), so the module never holds a secret.

## Scope of v0.2

**Carried:** the five Slack node shapes, the four Slack tool effects, the
`slack_mirror` acceptor.

**Deliberately NOT carried, pending upstream ratification:**

- **`identity_fields`.** Which of a shape's fields are identity vs. verdict
  is part of composition.md §14's open "one shape language" question. The
  mapping for Slack is well-understood (`message` identity = `[ts]`, `edit`
  identity = `[ts]` with `replaces` as a reference, `reaction` identity =
  `[target, emoji, by]`, `tombstone` identity = `[target]`) but the format
  for declaring it isn't settled upstream. `intersyntactic-hart-aspects`
  and this module both carry the mapping in design docs rather than in the
  manifest, and intersyntactic-16 is drafting it for Nick.
- **A line's working-tree shape.** Whether a journey may have a working
  tree that isn't a git checkout is open (same note). The design doc
  describes what a Slack-anchored line needs (a plain directory at
  `~/.intersyntactic/lines/<line_id>/`, no `.git`, no remote, just a lock
  + head + append-only nodes store) but the manifest doesn't bake it in
  until the ruling lands.
- **`restricted_kit` from v0.1.** Retired. Tools describe effects; drivers
  operate; the airlock adds credentials. The old mapping from node shape
  to Dart method dissolves into offerings of HTTP effects at a `tools`
  acceptor.

## The gap-pattern precedent

v0.1 carried an explicit `gaps` section that fired exactly once — caught
`reactionsAdd` missing from `SlackClient` — and retired when the method
landed. Under composition.md the same check happens at composition-time
(the core refuses to compose if an offering's backing code is unbound at
`tools`), so the `gaps` field itself retires: the discipline moves into
the composition check. The habit that earned its keep — declare intent
loudly, close the loop in a single commit — stays.

## Where runtime state lives (not here)

A line's writable state (lock, head, append-only nodes) lives at the
line's home under `~/.intersyntactic/lines/<line_id>/`, not in-repo. The
in-repo `.intersyntactic/` carries declarative module shape only, per the
"configuration with code; writable state with the user" split.
