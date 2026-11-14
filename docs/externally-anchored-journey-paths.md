# Externally-anchored journey paths

**Status:** draft, 2026-10-23, aligned 2026-11-05 to `composition.md`, intersyntactic's
own design doc (PROPOSED 2026-11-04, ratified by Nick as the state of truth
2026-11-05). For a PR against intersyntactic's own design docs after review
and `/design-temper`. Written from a design conversation with Nick on
2026-10-23, extended by the 2026-11-03/04 cross-session conversations that
produced composition.md.
**Draft lived in this module's own private predecessor repo while it
stabilised; promoted once settled.**
**Builds on** intersyntactic's own design docs: `composition.md`
(acceptors, offerings, bindings, deliveries), `distributed.md` §1
(a run is a tree of turns, a head, a working tree) and `authority.md` §3
(invariants N, H, L, T, E). This note names a kind of journey path beyond
"worktree-pinned" and the service-local case `authority.md` already allows.
**Forcing function:** this module's own earlier private name, the first
inbound-event adapter. The Slack case is the concrete instance below; the type generalises.

## Rulings (Nick, 2026-10-23)

1. **Each user runs their agent on their own server.** The Slack adapter is a
   federation, not a monolith. A tiny workspace **shim** receives webhooks and
   routes; each user's own intersyntactic install does the agent work.
2. **The authoritative node store for an externally-anchored journey path is the external
   source itself.** Slack is the source of truth for Slack threads and the Slack KB.
   The local tree is a mirror, kept fresh by the event stream.
3. **All contributions to a journey path are node appends.** Edits, deletions, and
   reactions are not special signals; they are instances of this primitive,
   with particular node-shapes. The state model has no mutation; the head
   serialises append-order. §1 states this; §3 names the module-level
   consequence (a module's manifest declares its acceptors and the shapes
   that bind at each, with `from: [agent | seats | modules]` on each acceptor
   taking the place of the old "which party may append which shape" framing).
4. **Shared knowledge-base lives in a `#kb` channel**, one message per entry.
   Universal across Slack plans; permissioned by Slack's own channel membership.
5. **Any user may call `remember`.** The channel is the ACL. Slack's edit history
   covers who wrote what.
6. **The agent proactively asks before remembering**, via a reaction prompt. It
   never silently promotes a mid-conversation observation into the shared KB.

## 1. The type

An **externally-anchored journey path** is a journey path (per `authority.md` §1) where:

- the authoritative node store is a system *outside* intersyntactic (Slack, an
  IMAP mailbox, a GitHub issue, a Google Doc);
- the local tree is a **mirror** of that store, written write-if-absent by nodes
  derived from the external system's event stream;
- the journey path has **no git worktree**. The "world" the journey path touches is the external
  source, not a filesystem. `authority.md` §1.3's "the world pins the writer"
  still holds; the world is just a SaaS instead of a working tree.

The journey path's **home** is the service that owns it (the user's intersyntactic
install, in the Slack case). The journey path's **lock** sits in a service-local path
(`~/.intersyntactic/journey_paths/<journey_path_id>/journey_path.lock`), not in a worktree's git dir.
`authority.md` L generalises: the lock lives where the journey path's writable state
lives, which here means the service's own data directory.

Everything else carries over unchanged. **N** holds (any process writes a node,
union merges); **H** holds (owner CASes the head); **E** holds and matters more
here than for a worktree journey path, because the "world" (the external SaaS) is where
`(journey_path, epoch)` as a far-side mark actually fences a zombie's writes.

**The state model is pure-append.** Every touch on a journey path is a node written
into its tree. The head's role is to serialise append-order; nothing is ever
mutated. "Edit," "delete," and "reaction" are not special events in the state
model — they are node-shapes whose semantics are supplied by downstream readers
(edit chains collapse to latest text; tombstones hide a branch; reactions
annotate their target). The §2 table catalogues the Slack-specific shape
vocabulary; other sources substitute their own. What can append which shape,
and where it lands, is declared in the module's manifest per composition.md:
§3 walks this through for the Slack case.

## 2. The pattern, in three pieces

```
  external source  ──events──▶  shim (one per source)   ──typed event──▶   receiver
   (Slack, IMAP,                 verifies, projects to                    (one per
    GitHub, …)                   a typed event, routes                     owner)
                                 to the right receiver                     mirrors,
                                                                           writes
                                 no code execution,                        nodes,
                                 no credentials,                           runs
                                 no filesystem touch                       turns

  receiver  ──side-effects──▶  external source
   (via tool calls that                      (sink shape: `slack.chat_post`,
    carry (journey_path, epoch))              `imap.append`, `github.comment`;
                                              far-side mark carries the fence)
```

The **shim** is small and auditable. Its job is: verify the external source's
signature, project each event to a typed event (a sealed class per source,
named for the source's own vocabulary — not a generic payload), look up the
owner for that journey path, forward. Nothing else. A source with nothing
useful to say beyond "something changed" (GitHub's webhook) still gets a
minimal notice naming only external IDs; a source that carries content
inline (Slack, Teams) carries it in the event rather than making the
receiver fetch it back — see N below.

The **receiver** is an ordinary journey path owner, with one additional responsibility:
it maintains a mirror of the external store for its owned journey paths, updated by the
events it receives. The mirror is the journey path's local node store.

### Edits, deletes, reactions as nodes

Per §1, every event is an append. The table below is not a special-case
translation layer; it is the Slack-side shape vocabulary. Other sources
substitute their own node-shapes under the same rule. The mapping, for Slack:

| External event | Node written |
|---|---|
| New message | A child of the thread anchor (or of the message replied to): `{kind: message, text, user, ts}` |
| `message_changed` | A child of the original: `{kind: edit, replaces: <original_id>, text, by, ts}` |
| `message_deleted` | A tombstone child: `{kind: tombstone, by, ts}` |
| `reaction_added` | An annotation child of the target: `{kind: reaction, emoji, by, ts}` |
| The agent's own reply, written write-ahead per `authority.md` W1 | Normal `{kind: message}`, authored by the agent, with the `(journey_path, epoch)` far-side mark embedded in Slack-side metadata before `chat.postMessage` runs |

The thread's "current state" for the agent's reading is **derived**: follow edit
chains to the latest text, skip tombstoned branches, surface reactions as
annotations on their targets. Same shape as git's working-copy view derived from
the object store, same shape as `authority.md` §5's first-parent walk.

## 3. The module manifest: acceptors and offerings

Per §1, a journey path's state is a tree of appended nodes. A module that binds to a
journey path declares, in its manifest (composition.md §6), two things:

- **Acceptors**: places the module opens for others. An acceptor has a
  *shape* (what can bind here), a *use* (what the module does with
  whatever binds — composition.md §6: "the use belongs to the acceptor,
  never to the offering"), a *version*, and a *from* (`agent`, `seats`
  or `modules`: who may offer to it).
- **Offerings**: what the module brings to other modules' acceptors. An
  offering has a shape (a node shape, or a tool, or data), a `binds`
  list naming the acceptors it goes to, and optional `needs` (what else
  must be bound for it to work).

For the Slack module:

- **One acceptor**, `slack_mirror`. Shape: a Slack-anchored node
  (`message`, `edit`, `reaction`, `tombstone`, or `slack_event_raw`).
  Use: keep the mirror of a Slack-anchored journey path in sync with Slack.
  From: `modules` (the orchestrator per composition.md §7 delivers
  nodes here after resolving a webhook to its journey path).
- **Five node-shape offerings** at `slack_mirror`: the four typed shapes
  plus the catch-all `slack_event_raw`. The catch-all carries a
  `slack_event_type` discriminator so composition.md §2's rule — *a node
  of a shape nothing bound is refused* — holds even for Slack event
  subtypes we haven't typed explicitly. "Loosely typed with a known
  discriminator" is what lets "every shape bound at composition" hold
  for mirror-style journey paths without losing events Slack adds later.
- **Four tool offerings** at a `tools` acceptor (opened by intersyntactic's `agent_loop` module): `chat_post`,
  `chat_update`, `chat_delete`, `reactions_add`. These describe HTTP
  effects only; a web driver operates the Slack API and the airlock
  adds the bot token (the drivers ruling), so the module never holds
  a secret.

**Design implication:** `reactions_add` must be offered at `tools`, not
left out as nice-to-have. Agent-initiated consent prompts — the agent
appends a question-shaped node and a seat appends a `reaction`-shaped
node under it, with "refusal is the default" following from "no append
= no node"; §4.1 and §4.2 are instances — depend on it.

**Where this meets `authority.md`:** N's "any process writes a node,
union merges" is unchanged; the manifest doesn't gate writes beyond
the composition-time check. A composition that includes the Slack
module must include an acceptor that binds its shapes (the module's
own `slack_mirror` normally does), or composition fails with the
reason, per composition.md §2.

**What retired from the v0.1 draft:** the `agent_facing` / `seat_facing`
/ `ambient` sets, and the `restricted_kit` field. The three sets become
`from: [agent | seats | modules]` on individual acceptors; the kit
dissolves into tool offerings whose effects are HTTP, operated by a
driver not owned by this module.

## 4. Three concrete instances

### 4.1 Slack thread as a journey path

The first and most obvious instance. The journey path's id is derived from `(workspace,
channel, thread_ts)`. One head per journey path; `authority.md` H's CAS applies. Mirror
updates on every thread event the owner is subscribed to. Agent's turn runs
read from the mirror (no Slack API round-trip in the critical path);
agent's reply writes a mirror node and *then* calls `chat.postMessage`
(write-ahead, W1).

**Edit of a prior user message:** emits a `message_changed` event; receiver
writes an edit node; agent reacts 🔄 to the edited message as a consent prompt.
User-click-🔄 fires a `reaction_added` event; receiver treats as consent;
re-runs the turn from the edited message as the new head. The old answer path
is preserved as a branch and is readable via `authority.md` §5's `--first-parent`
walk if the user wants it.

### 4.2 Slack KB as a journey path

A `#kb` channel per workspace (or per team's choice); each top-level message is
one KB entry, **capped at Slack's single-message text limit**. The journey path's id is
`(workspace, #kb-channel-id)`. The agent exposes:

- `remember(title, body?, reference?, scope?)` — posts a new message to the
  `#kb` channel. The message is **one Slack message**: title + a short body
  that fits the message cap. Returns the Slack `ts` as the entry's id. Writes
  write-ahead to the mirror before the Slack call.
- `recall(query, scope?)` — reads the local mirror, which is kept in sync by the
  channel's event stream.

**Long content lives elsewhere.** The KB is a *facts database*, not a document
store. When a memory wouldn't fit one Slack message, the entry becomes a
*reference*: title + summary + a link to a document in whatever document store
the team uses (Google Docs, a wiki, a canvas, an uploaded file). The KB holds
the summary and the pointer; the document store holds the content. This mirrors
intersyntactic's own `MEMORY.md` + content-file pattern — `MEMORY.md` is the
index with one-line-per-entry, and bodies live in separate files. Splitting
index from content is the pattern, not threading content under a header.

**Proactive promotion:** when the agent spots something worth keeping (a stated
preference, a correction, a decision), it does *not* call `remember` directly.
Instead it posts the candidate as an ephemeral message in the originating
thread with a 💾 reaction, framed as "worth saving to the channel KB?" User-
click-💾 fires `reaction_added`; receiver treats as consent; agent runs
`remember` with the agreed text. Because entries fit one message, the whole
candidate shows in the ephemeral — consent is informed by what the user sees.

**Who may edit a KB entry:** anyone in the channel, through Slack's own UI. An
edit emits `message_changed`; the receiver's mirror updates. One-message
entries use Slack's native edit-visibility affordances (the `(edited)` suffix,
hover-to-see-history). The KB tracks what the channel believes right now, with
Slack's edit history as the authoritative log of who-changed-what-and-when. A
reference-style entry edits by updating the summary or the pointer; the
referenced document edits through its own system's history.

### 4.3 Future (not scoped here, named so the pattern can carry them)

- **Email**: an IMAP folder as a journey path, with the IMAP IDLE event stream feeding
  the mirror; `imap.append` as the sink.
- **GitHub issues/PRs**: an issue or PR as a journey path, with the webhook event stream
  (via `intersyntactic_relay` or similar) feeding the mirror; `issue.comment`,
  `pulls.create_review_comment` as the sinks.
- **Wiki page**: a page as a single-head journey path, mirror on edit webhooks, API
  write as the sink.

Each of these would want its own shim (one per external source) but the
receiver-side shape — mirror, event-to-node mapping, side-effects carrying
`(journey_path, epoch)` — is the same.

## 5. The bus pressure, restated

`plugins-as-services.md §2` lists options for inter-machine transport. The
externally-anchored journey path pattern — specifically the shim-to-receiver call —
needs:

- **Streaming** (so streamed model output can flow back from the receiver to
  the shim, which forwards to Slack as `chat.update` edits);
- **Authentication of both ends** (the shim proves it's the shim, so a random
  requester can't burn the user's provider budget; the receiver proves it's
  the receiver that the user registered);
- **Firewall-friendliness** (the receiver may be on a laptop with no inbound
  port; `intersyntactic_relay`'s dial-out pattern already solves this).

HTTP + SSE and JSON-RPC-over-a-socket both work. Aiko MQTT is harder because
the broker becomes a trust surface for provider budgets. The strong hint from
this adapter: whatever the first spike settles for §2, it should carry a
streaming test with cross-machine auth from day one.

## 6. The roster, as a first-class module-system concern

`cross-machine-sessions.md` §4.5 names "roster" as "explicit, opt-in per
machine, maintained by the relay." The externally-anchored journey path pattern makes
roster-shaped routing general:

```
(external_source, external_actor_id) → (receiver_endpoint, bearer_token)
```

Per Slack: `(workspace, slack_user_id) → (receiver_endpoint, bearer)`. Added
by a user running an "install me" call from their intersyntactic to the shim,
which validates workspace membership (via Slack API) and pins the mapping.

The reverse map matters too: a receiver needs to know "which shim is allowed
to call `run_turn` on me, and whose events am I expecting from it?" so a
compromised shim can't ask the receiver to run arbitrary work. Receiver pins
`(shim_endpoint, shim_bearer, allowed_external_actors)` at registration.

In the vocabulary of §7, the roster IS the orchestrator state. It exists
because Slack's servers POST to one URL per workspace and cannot dial out to
discover a user's receiver. Receivers in `intersyntactic_relay` dial out and
need no equivalent roster. §7.1 generalises this as a design axis.

## 7. Open questions

- **The `/design-temper` list** from this session:
    1. **Identity resolution when the sender can't dial out.** This is a
       design axis, not a wart to resolve. An orchestrator (shim, in Slack's
       case) exists exactly when the external sender is physically incapable
       of resolving logical→physical identity itself: Slack's servers POST to
       one URL per workspace and won't dial out, so the `(workspace,
       slack_user_id) → (receiver_endpoint, bearer)` map must live somewhere
       persistent. Receivers that dial out (via `intersyntactic_relay`) need
       no equivalent. The axis — *bootstrapped-from-inside pipelines vs
       sender-can't-dial-out systems* — determines whether an adapter needs
       an orchestrator at all. **The routing-location question
       (`/design-temper` 2026-11-06, RECAST → fold):** the four candidates
       split into two groups.
       - *Self-anchored routing* — Slack profile field (Slack as config store
         the user edits with their mouse); DNS TXT/SRV record on a user-owned
         domain. The identified entity has native edit access to its own
         routing, so the recursion terminates: no stranger's-shim-audit
         question arises because no stranger is in the path. Default for
         users who have either affordance.
       - *Third-party-anchored routing* — a shim (as §6); a meta-journey-path
         (recursive, since its routing has to live somewhere); a well-known
         per-workspace endpoint (which IS the routing table, just hosted
         elsewhere). These all push the routing-of-routing problem one level
         back. Fallback for populations without a domain or whose workspace
         admins disable profile fields. The audit question — given the shim
         holds signing secrets plus the routing table, what's the minimum
         audit a user should do before pointing their receiver at a
         stranger's shim? — re-enters here, not in the self-anchored case.
    2. **Reaction consent window** (`/design-temper` 2026-11-06, RECAST →
       fold). A reaction prompt is live **until the next event changes the
       state it proposes to modify, OR 10 minutes elapse, whichever comes
       first**. State-change is the natural ceiling (the context has moved
       on); 10 minutes is the floor for the user-walked-away case. **On an
       expired 💾, the agent posts a reply naming the expiry and offering to
       re-run** — silent drop is a trust break on a consent gesture. The
       prompt mechanism needs an ephemeral that persists across view
       refreshes; `chat.postEphemeral` doesn't, so the implementation
       probably uses a short-lived non-ephemeral message in a dedicated
       thread rather than a true ephemeral.
    3. ~~**KB entry structure.** One Slack message per entry gives a flat list.
       Does the agent chunk long memories across multiple messages (threaded
       under a header), or is each entry capped to one message's text limit?
       The `MEMORY.md` + hunks pattern suggests threaded.~~ **Resolved via
       `/design-temper` 2026-11-06 (RECAST → fold).** Entries are capped at
       one Slack message; long content lives in a document store the entry
       references. The `MEMORY.md` pattern actually supports this (index +
       separate content files), not threaded chunks — the earlier framing
       misread its own cited precedent. Rationale and new text in §4.2.
    4. **The receiver's identity to the shim** (`/design-temper` 2026-11-06,
       RECAST → fold). On-tailnet: Tailscale whois, unchanged. **Off-tailnet:
       Slack OAuth, not a static bearer.** The receiver holds a short-lived
       Slack-issued OAuth token for its app, refreshed via Slack's
       refresh-token flow. Rotation is built into the OAuth flow; revocation
       is one-click via Slack's app management UI; the trust anchor is Slack
       itself, which the user already trusts to carry the consent signal.
       Bearers as a primitive are declined — a leaked static bearer would
       give receive-access until manual re-registration, whereas a leaked
       OAuth token has a bounded lifetime and a visible revocation path.
    5. **When does a turn run?** Surfaced 2026-11-06, unresolved. The mirror
       updates on every event the owner is subscribed to — that's the
       "never drifts from Slack" guarantee of §1. A turn (a model call)
       is a different layer, and must not fire on every mirror write;
       otherwise a stray 👍 in the channel burns provider budget. The
       invariant the receiver must hold: **mirror updates on every event;
       turns run on named triggers.** §8.1 names one trigger (`@-mention`
       in the thread); §4.1/§4.2 name two more (user clicks the specific
       consent emoji the agent is waiting on). The following cases are
       unspecified and need a ruling before task 5 is built:
       - **In-thread reply after an `@-mention`.** Does every subsequent
         user message in that thread trigger a turn, or must the user
         re-@-mention? Natural reading: while the thread is active, yes;
         the conversation would break otherwise. But "active" is
         unbounded — how long after the last turn is the thread still
         treated as live?
       - **DMs with the bot.** Natural reading: every user message in
         a DM triggers a turn (the DM itself is the invitation). State
         this explicitly rather than inherit from the thread case.
       - **Reactions outside a live prompt.** If a user puts the
         consent emoji on an agent message that wasn't a live prompt,
         the consent-window ruling (§7.2) implies it's ignored — but
         by implication, not by statement. Say it.
       - **Edits to messages the agent already replied to.** §4.1 is
         explicit: a `message_changed` writes an edit node and the
         agent 🔄-reacts as a re-prompt. The re-turn fires only on
         user confirmation. This one is actually resolved; it's listed
         so the full enumeration is visible in one place.

       The resolution should land in this section once ruled, and in
       task 5's acceptance criteria (which already names the invariant).
- **Related open questions already in other docs:**
    - `plugins-as-services.md §7` — which option for each slot in §2. The
      shim-receiver call is this pattern's first serious cross-machine use.
    - `open-core.md §6` — trust for strangers' modules beyond UI. The shim
      is a stranger's-module-in-the-small for whoever runs it.

## 8. Done when

1. A Slack thread @-mention arrives, the shim forwards a typed event, the correct
   user's receiver writes a mirror node, runs a turn against their own
   provider, posts a reply via `chat.postMessage`, and the reply appears in the
   mirror as a sibling node authored by the agent — all without the receiver
   calling `conversations.replies` after the first-ever message of the thread.
2. An edit of a prior user message adds an edit node; the agent 🔄-reacts to
   the edited message; the user adds the same 🔄; a new turn runs from the
   edited message as the new head, and both answers remain readable via
   first-parent walks.
3. A `remember` call via `/remember` writes to the `#kb` channel and the
   mirror; a direct Slack-UI edit of the resulting message updates the mirror
   via `message_changed`; `recall` returns the edited text.
4. The agent spots a save-worthy observation, posts an ephemeral 💾 prompt,
   and does not call `remember` until the user adds the 💾 reaction (within
   the consent window).
5. A grep of the shim's source for `anthropic`, `openai`, `conversations.
   history` finds nothing. The shim handles no credentials and makes no model
   calls.
6. A zombie receiver that reconnects after an `adopt` and tries to post to
   Slack carries an epoch `n`; its Slack post is recognised as foreign by the
   `(journey_path, epoch)` mark in the message's metadata and does not update the
   mirror on the live receiver. (This is the externally-anchored equivalent
   of `authority.md`'s "a stale CAS is refused.")
