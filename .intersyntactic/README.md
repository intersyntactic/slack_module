# .intersyntactic/

Plugin manifest for `intersyntactic_slack`. Discoverable by intersyntactic at
wire-up time; versioned with the code (not with the user's home-pinned
runtime state, which lives in `~/.intersyntactic/lines/<line_id>/`).

See [`manifest.json`](./manifest.json) for the declared shape, and
[`../docs/externally-anchored-lines.md`](../docs/externally-anchored-lines.md)
§3 for what the fields mean.

## Format

JSON. Chosen over:

- **YAML** — parser-footgun jungle (the "Norway problem" is live: `no` parses
  as `false` in YAML 1.1), weak tooling guarantees across implementations.
- **Typed Dart source** — not consumable by other-language tooling at wire-up
  time. The manifest is read by intersyntactic (upstream of this package)
  before anything in this package runs.

The trade-off is no inline comments. This README absorbs the explanations the
file would otherwise carry.

## Scope of v0.1

Node-shape vocabulary, the three sets (`agent_facing` / `seat_facing` /
`ambient`), and the `restricted_kit` mapping to Dart methods on `SlackClient`.
No version field, no dependencies, no line-id shape — add when a reader needs
them. (An earlier draft also carried a `gaps` section; it fired exactly once —
caught `reactionsAdd` missing from `SlackClient` — and retired when the method
landed. See the commit log for the shape of that catch.)

## Where runtime state lives (not here)

Per `../docs/externally-anchored-lines.md` §1: a line's writable state (lock,
mirror, head) lives under `~/.intersyntactic/lines/<line_id>/`, not in-repo.
The in-repo `.intersyntactic/` carries declarative plugin shape only.
