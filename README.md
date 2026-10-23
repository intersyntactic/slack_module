# intersyntactic_slack

A Slack adapter for intersyntactic. An @-mention in Slack becomes a turn of a
run on an intersyntactic agent, with any model the sender has credentials for.
Threads are the conversation; the restricted Slack kit decides what the agent
can touch when answering.

A plugin, by intersyntactic's own shape: *everything is a plugin, and plugins
live in their own repos.* This package depends on `enspyrco/intersyntactic`,
not the other way around.

## Shape

```
Slack  ──POST /webhook/slack──▶  intersyntactic_relay
                                     │  (verifies signing, projects to a
                                     │   doorbell: team, channel, thread_ts,
                                     │   user — no Slack text)
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

Draft. The signing/parsing gate is here (`lib/src/slack_gate.dart`) with tests;
the HTTP handler, the Slack Web API client, the credential store, the
restricted kit and the local turn-store are not written yet.

## Running the tests

```
dart pub get
dart test
```

## Design anchors

- `enspyrco/intersyntactic/docs/design/distributed.md` — the always-on target.
  A run is a tree of turns (grow-only), a head (one writer, epoch-fenced), and
  a working tree (pins the writer to a machine). Slack threads map to the tree
  cleanly; this package writes its turns in that shape from day one.
- `enspyrco/intersyntactic/docs/design-cross-machine-sessions.md` §4.8 — the
  machine-peer model. The Slack bot will eventually be one more roster entry
  alongside `claudius`, `lyra-avatar` and the rest.
