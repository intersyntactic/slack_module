# intersyntactic_slack

A Slack adapter for intersyntactic. An @-mention in Slack becomes a turn of a
run on an intersyntactic agent, with any model the sender has credentials for.
Threads are the conversation; the airlock, given this journey path's rules, decides
each effect the agent asks for, and a driver operates Slack.

A module, by intersyntactic's own shape: modules live in their own repos.
This package depends on intersyntactic's core, not the other way around.

## Shape

```
Slack  ──POST /webhook/slack──▶  SlackRelay (is_slack_relay)
                                     │  (verifies signing, dedupes replays,
                                     │   projects to a doorbell: team,
                                     │   channel, thread_ts, user, text)
                                     ▼
                                 /ws  ──doorbell──▶  intersyntactic agent
                                                        │  (re-reads thread
                                                        │   from Slack, runs
                                                        │   turn, streams
                                                        │   reply)
                                                        ▼
                                              Slack chat.update  ◀─ reply
```

Reply goes agent → Slack directly, not back through the relay. The relay stays
one-way.

## Status

Draft. The relay (signature verification, replay dedupe, the HTTP handler)
lives in its own package, `is_slack_relay`, for separation of concerns from
this module's domain logic: the Slack Web API client (`lib/src/slack_client.dart`),
the thread mirror (`lib/src/slack_mirror.dart`) and the receiver
(`lib/src/slack_receiver.dart`) that turns a doorbell into mirror writes.
Still missing: wiring the turn engine to the agent host (task #11, on hold
pending intersyntactic's shapes direction). Credentials live at the airlock
under the drivers ruling, not in this module.

## Running the tests

```
dart pub get
dart test
```

## Design anchors

- `composition.md`, intersyntactic's own design doc
  — the state of truth for how modules compose. Acceptors are places a module
  opens; offerings are what a module brings; the core binds each offering at
  the acceptors it names. Our manifest at [`.intersyntactic/manifest.json`](./.intersyntactic/manifest.json)
  declares one acceptor (`slack_mirror`) and nine offerings (five node shapes
  + four tool effects).
- `docs/externally-anchored-journey-paths.md` — the Slack-specific design. A
  Slack-anchored journey path has no git worktree; its writable state lives at
  `~/.intersyntactic/journey_paths/<journey_path_id>/`. The orchestrator (composition.md §7)
  resolves a webhook delivery to its journey path before anything becomes a node.
- `distributed.md`, intersyntactic's always-on design doc — the always-on target:
  a run is a tree of turns (grow-only), a head (one writer, epoch-fenced), and
  a working tree. For Slack journey paths, "working tree" is the home-pinned data
  directory above, not a git checkout.
