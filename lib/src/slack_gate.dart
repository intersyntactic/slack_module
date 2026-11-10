/// Decides whether an inbound Slack delivery is authentic and worth acting on.
///
/// A sibling of intersyntactic's `webhook_gate.dart`, not an extension of it:
/// Slack signs `v0:{timestamp}:{body}` rather than the bare body, carries the
/// event kind inside the signed payload rather than in a header, and
/// (crucially for us) delivers slash commands whose `text` the receiver must
/// ACT ON, not merely re-read something idempotent in response to. That last
/// point is the one `webhook_gate.dart`'s long comment calls out as the
/// condition under which "digest-keyed replay protection becomes required":
/// the Slack gate therefore takes a `hasSeen` closure and refuses a signature
/// it has seen before.
///
/// Pure, like its sibling: the replay cache is caller-owned, so the gate's
/// cases are testable without a clock, a socket, or Slack.
///
/// Slack's own `X-Slack-Request-Timestamp` is signed (unlike GitHub's
/// `X-GitHub-Delivery`), so a replayer cannot edit it to defeat a signature
/// cache. The timestamp window below (default 5 min, per Slack's docs) bounds
/// how long a captured delivery remains replayable at all; the digest cache
/// collapses it further to "once".
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What the caller should do.
enum SlackGateOutcome {
  /// Fan this doorbell out to listeners; answer 200.
  trigger,

  /// Authentic but uninteresting (a quiet event, or a replay we have already
  /// delivered once). Answer 200; do not fan out.
  ignore,

  /// The one-time setup handshake. Answer 200 with [SlackGateDecision.challenge]
  /// in the response body; do not fan out.
  urlVerification,

  /// Refused. Never say why in the response body; the log may.
  reject,
}

class SlackGateDecision {
  final SlackGateOutcome outcome;

  /// Operator-facing, logged. A rejection reason in a response body is a hint
  /// to whoever is guessing at the signature.
  final String reason;

  /// The doorbell payload to broadcast to listeners, present iff
  /// [outcome] == [SlackGateOutcome.trigger]. Shape:
  /// ```
  /// {
  ///   "event": "slack_mention" | "slack_message" | "slack_command",
  ///   "team": "T...",
  ///   "channel": "C...",
  ///   "thread_ts": "...",       // event.thread_ts || event.ts (the anchor)
  ///   "user": "U...",
  ///   // slack_mention / slack_message only — the parser (gate_parser.dart)
  ///   // consumes these to build a SlackNode without re-fetching from Slack:
  ///   "text": "hi there",       // event.text
  ///   "event_ts": "1700…",      // event.ts (the message's own ts; may equal
  ///                             //           thread_ts for a top-level mention)
  ///   "subtype": "message_changed" | "message_deleted" | null,
  ///   "raw_thread_ts": "1700…" | null,  // event.thread_ts as-sent
  ///   "raw_event": {...},       // the full inner event map — SlackEventRaw
  ///                             // fallback for unrecognised subtypes
  ///   // slack_command only:
  ///   "command": "/model",
  ///   "text": "opus-4.7",
  ///   "trigger_id": "...",
  ///   "response_url": "...",
  /// }
  /// ```
  final Map<String, dynamic>? message;

  /// Challenge to echo in the response body, present iff
  /// [outcome] == [SlackGateOutcome.urlVerification].
  final String? challenge;

  /// The digest the caller should add to its replay cache. Present on every
  /// outcome except [SlackGateOutcome.reject], so that an authentic
  /// replay-of-ignore does not become a trigger if someone changes the wake
  /// set mid-flight.
  final String? digest;

  const SlackGateDecision(
    this.outcome,
    this.reason, {
    this.message,
    this.challenge,
    this.digest,
  });

  bool get shouldBroadcast => outcome == SlackGateOutcome.trigger;
}

class SlackSourceSpec {
  /// Slack's "Signing Secret" from the app's Basic Information page. Empty is
  /// a configuration error — the gate refuses rather than opens.
  final String signingSecret;

  /// Workspaces this gate accepts events from. Empty means "accept any
  /// workspace that signs correctly", which is only ever right in tests.
  final Set<String> teamIdAllowlist;

  /// Inner event types from an `event_callback` that should wake listeners.
  /// Anything else (including a well-known-but-uninteresting kind) is
  /// [SlackGateOutcome.ignore]d.
  final Set<String> wakeEventTypes;

  /// Slash commands that should wake listeners.
  final Set<String> wakeCommands;

  const SlackSourceSpec({
    required this.signingSecret,
    this.teamIdAllowlist = const {},
    this.wakeEventTypes = const {'app_mention', 'message'},
    this.wakeCommands = const {'/model', '/connect', '/forget'},
  });
}

/// The hex HMAC-SHA256 Slack expects: `v0=` + hex(hmac(secret, "v0:{ts}:{body}")).
/// Returned WITHOUT the `v0=` prefix; the caller compares the suffixes.
String slackSignBody(String secret, String timestamp, List<int> body) {
  final mac = Hmac(sha256, utf8.encode(secret));
  final input = <int>[
    ...utf8.encode('v0:$timestamp:'),
    ...body,
  ];
  return mac.convert(input).toString();
}

/// Constant-time comparison. A `==` on a hex digest leaks, through timing, how
/// many leading characters a guess got right, which turns forging a signature
/// into a per-character search instead of a 2^256 one. Length is compared
/// first and separately because differing lengths cannot be compared in
/// constant time anyway, and length is not the secret.
///
/// Inlined (rather than imported from intersyntactic's `webhook_gate.dart`) so
/// this leaf package stays free of a path-dep on intersyntactic for the gate
/// alone.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

SlackGateDecision slackGate({
  required SlackSourceSpec spec,
  required Map<String, String> headers,
  required List<int> body,
  required String contentType,
  required DateTime now,
  bool Function(String digest)? hasSeen,
  Duration maxTimestampSkew = const Duration(minutes: 5),
  int maxBodyBytes = 1024 * 1024,
}) {
  // FAIL CLOSED on a missing secret. Matches `webhook_gate.dart`: a deploy
  // that forgot to set an env var becomes a refuser, not a public endpoint.
  if (spec.signingSecret.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'slack signing secret not configured',
    );
  }

  if (body.length > maxBodyBytes) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'body ${body.length}b over cap',
    );
  }

  final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

  final timestamp = lower['x-slack-request-timestamp'];
  if (timestamp == null || timestamp.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'missing x-slack-request-timestamp',
    );
  }
  final tsSeconds = int.tryParse(timestamp);
  if (tsSeconds == null) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'x-slack-request-timestamp is not an integer',
    );
  }

  // Per Slack's docs: refuse timestamps more than 5 minutes off. Both
  // directions matter: a future timestamp is as suspicious as a past one, and
  // a clock stepped backwards must not open a replay window into the future.
  final skew = now.difference(
    DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000, isUtc: true),
  );
  if (skew.abs() > maxTimestampSkew) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'timestamp ${skew.inSeconds}s off',
    );
  }

  final presented = lower['x-slack-signature'];
  if (presented == null || presented.isEmpty) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'missing x-slack-signature',
    );
  }
  const prefix = 'v0=';
  if (!presented.startsWith(prefix)) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'signature prefix not recognised',
    );
  }
  final expected = slackSignBody(spec.signingSecret, timestamp, body);
  final offered = presented.substring(prefix.length).toLowerCase();
  if (!constantTimeEquals(expected, offered)) {
    return const SlackGateDecision(
      SlackGateOutcome.reject,
      'signature mismatch',
    );
  }

  // Authentic from here. The signature itself is the dedupe key: it is bound
  // to the body AND the signed timestamp, so a replay reproduces it exactly
  // and a tampered body never gets this far.
  final digest = expected;
  if (hasSeen != null && hasSeen(digest)) {
    return SlackGateDecision(
      SlackGateOutcome.ignore,
      'replay',
      digest: digest,
    );
  }

  // Parse. The content type tells us which body shape to expect; both have
  // already been signed, so a lie here only turns a valid delivery into a
  // parse failure.
  final mime = contentType.split(';').first.trim().toLowerCase();
  final Map<String, dynamic> payload;
  if (mime == 'application/json') {
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) {
        return SlackGateDecision(
          SlackGateOutcome.reject,
          'json body is not an object',
          digest: digest,
        );
      }
      payload = decoded.cast<String, dynamic>();
    } catch (_) {
      return SlackGateDecision(
        SlackGateOutcome.reject,
        'json body did not parse',
        digest: digest,
      );
    }
  } else if (mime == 'application/x-www-form-urlencoded') {
    payload = Uri.splitQueryString(utf8.decode(body));
  } else {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'unexpected content type "$mime"',
      digest: digest,
    );
  }

  // url_verification is the one-time handshake Slack makes when the webhook
  // URL is first configured. It carries a `challenge` field we must echo
  // back; no team_id is present because the app may not be installed
  // anywhere yet.
  if (payload['type'] == 'url_verification') {
    final challenge = payload['challenge'];
    if (challenge is! String || challenge.isEmpty) {
      return SlackGateDecision(
        SlackGateOutcome.reject,
        'url_verification missing challenge',
        digest: digest,
      );
    }
    return SlackGateDecision(
      SlackGateOutcome.urlVerification,
      'handshake',
      challenge: challenge,
      digest: digest,
    );
  }

  // Workspace allowlist. Checked AFTER the signature, so timing cannot be
  // used to probe which workspaces are allowed.
  final teamId = _teamIdOf(payload);
  if (teamId == null) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'no team_id in payload',
      digest: digest,
    );
  }
  if (spec.teamIdAllowlist.isNotEmpty &&
      !spec.teamIdAllowlist.contains(teamId)) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'team "$teamId" not in allowlist',
      digest: digest,
    );
  }

  // Three Slack shapes we recognise: event_callback, slash command,
  // view_submission (deferred). Anything else is ignored by name so the log
  // can tell "quiet" from "unknown".
  if (payload['type'] == 'event_callback') {
    return _event(spec, payload, teamId, digest);
  }
  if (payload.containsKey('command')) {
    return _command(spec, payload, teamId, digest);
  }
  return SlackGateDecision(
    SlackGateOutcome.ignore,
    'unknown payload type "${payload['type']}"',
    digest: digest,
  );
}

String? _teamIdOf(Map<String, dynamic> payload) {
  final direct = payload['team_id'];
  if (direct is String && direct.isNotEmpty) return direct;
  final team = payload['team'];
  if (team is Map && team['id'] is String) return team['id'] as String;
  return null;
}

SlackGateDecision _event(
  SlackSourceSpec spec,
  Map<String, dynamic> payload,
  String teamId,
  String digest,
) {
  final event = payload['event'];
  if (event is! Map) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'event_callback has no event object',
      digest: digest,
    );
  }
  final type = event['type'];
  if (type is! String || !spec.wakeEventTypes.contains(type)) {
    return SlackGateDecision(
      SlackGateOutcome.ignore,
      'quiet event type "$type"',
      digest: digest,
    );
  }
  final channel = event['channel'];
  if (channel is! String || channel.isEmpty) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'event missing channel',
      digest: digest,
    );
  }
  final user = event['user'];
  final ts = event['ts'];
  final threadTs = event['thread_ts'];
  // The conversation anchor: thread_ts when the event is already in a thread,
  // the message's own ts when it is a top-level mention that will seed one.
  final anchor = (threadTs is String && threadTs.isNotEmpty)
      ? threadTs
      : (ts is String ? ts : null);
  if (anchor == null) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'event missing ts and thread_ts',
      digest: digest,
    );
  }
  // A message_changed / message_deleted subtype moves fields inside the
  // event: the "current" user, ts and text live under `event.message` (and
  // `event.previous_message` for edits). The parser consumes `raw_event`
  // directly for those, so we carry it through without re-shaping here.
  final subtype = event['subtype'];
  final text = event['text'];
  return SlackGateDecision(
    SlackGateOutcome.trigger,
    'event "$type"',
    message: {
      'event': type == 'app_mention' ? 'slack_mention' : 'slack_message',
      'team': teamId,
      'channel': channel,
      'thread_ts': anchor,
      'user': user is String ? user : null,
      'text': text is String ? text : null,
      'event_ts': ts is String ? ts : null,
      'subtype': subtype is String ? subtype : null,
      'raw_thread_ts': threadTs is String && threadTs.isNotEmpty ? threadTs : null,
      'raw_event': event.cast<String, dynamic>(),
    },
    digest: digest,
  );
}

SlackGateDecision _command(
  SlackSourceSpec spec,
  Map<String, dynamic> payload,
  String teamId,
  String digest,
) {
  final command = payload['command'];
  if (command is! String || !spec.wakeCommands.contains(command)) {
    return SlackGateDecision(
      SlackGateOutcome.ignore,
      'quiet command "$command"',
      digest: digest,
    );
  }
  final channel = payload['channel_id'];
  final user = payload['user_id'];
  if (channel is! String || channel.isEmpty || user is! String) {
    return SlackGateDecision(
      SlackGateOutcome.reject,
      'command missing channel_id or user_id',
      digest: digest,
    );
  }
  // thread_ts is present on slash commands only when Slack passes it; absent
  // for a top-level command. The receiver's model-selection scope depends on
  // this (per-thread vs channel default) and treats a missing one explicitly.
  final threadTs = payload['thread_ts'];
  return SlackGateDecision(
    SlackGateOutcome.trigger,
    'command "$command"',
    message: {
      'event': 'slack_command',
      'team': teamId,
      'channel': channel,
      'thread_ts': threadTs is String && threadTs.isNotEmpty ? threadTs : null,
      'user': user,
      'command': command,
      'text': payload['text'] is String ? payload['text'] : '',
      'trigger_id':
          payload['trigger_id'] is String ? payload['trigger_id'] : null,
      'response_url':
          payload['response_url'] is String ? payload['response_url'] : null,
    },
    digest: digest,
  );
}
