/// Run behind TLS (a reverse proxy): Slack needs https, and the bot token is
/// read from the environment of this process.
///
///   SLACK_SIGNING_SECRET=...        from Slack app's Basic Information page
///   SLACK_TEAM_ID_ALLOWLIST=T1,T2   workspaces whose events are accepted;
///                                   empty is "any correctly signed workspace"
///                                   and should only be used in tests
///   SLACK_BOT_TOKEN=xoxb-...        required so the handler can call the Slack
///                                   Web API; read but not used until the
///                                   handler lands
///   PORT=8086                       optional; a non-port aborts
///   HOST=127.0.0.1                  optional; the address to bind. The default
///                                   is loopback, for a proxy on the same
///                                   machine. 0.0.0.0 serves plain HTTP on
///                                   every interface.
///
/// Slack: Event Subscriptions + Slash Commands both point at
/// `https://<host>/webhook/slack`. One route, one gate, two body shapes.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:is_shapes/is_shapes.dart';

/// How long a signature digest stays in the replay cache. Slack's 5-minute
/// signing window plus a little slack: once this expires a captured delivery
/// cannot be accepted anyway (the gate's timestamp check refuses it), so this
/// bounds the cache's growth, not its correctness.
const _replayTtl = Duration(minutes: 10);

/// A ceiling so an upstream flood cannot grow the cache without bound. 1000
/// digests is roughly 100 KiB; well under any sensible slack-events burst.
const _replayMax = 1000;

Future<void> main() async {
  final env = Platform.environment;
  final signingSecret = env['SLACK_SIGNING_SECRET'] ?? '';
  if (signingSecret.isEmpty) {
    // Refuse to start rather than serve an endpoint that waves everyone in --
    // the same discipline as webhook_gate.dart's own fail-closed rule.
    stderr.writeln('abort: SLACK_SIGNING_SECRET not set');
    exit(78);
  }
  final allow = {
    for (final e in (env['SLACK_TEAM_ID_ALLOWLIST'] ?? '').split(','))
      if (e.trim().isNotEmpty) e.trim(),
  };
  if (allow.isEmpty) {
    stderr.writeln(
      'warning: SLACK_TEAM_ID_ALLOWLIST is empty; any correctly signed '
      'workspace will be accepted',
    );
  }
  final botToken = env['SLACK_BOT_TOKEN'] ?? '';
  if (botToken.isEmpty) {
    // Read now so a missing one aborts at boot rather than at first reply.
    // The handler is not wired yet, so this is only a warning for now.
    stderr.writeln(
      'warning: SLACK_BOT_TOKEN not set; the bot will accept events but '
      'cannot reply',
    );
  }

  final rawPort = env['PORT'];
  final port = rawPort == null || rawPort.isEmpty ? 8086 : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('abort: PORT "$rawPort" is not a port number');
    exit(78);
  }
  final rawHost = env['HOST'];
  final host = rawHost == null || rawHost.isEmpty ? '127.0.0.1' : rawHost;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    stderr.writeln('abort: HOST "$host" is not an IP address');
    exit(78);
  }

  final spec = SlackSourceSpec(
    signingSecret: signingSecret,
    teamIdAllowlist: allow,
  );
  // Default wiring: in-memory mirror, placeholder self-actor (no real
  // bot-user-id yet — SLACK_BOT_TOKEN is read above but not used until the
  // reply handler lands, so wantsTurn ends up always-true until then).
  // onKickoff logs; task 11 replaces it with the agent-host client.
  final bot = SlackBot(
    spec: spec,
    mirror: InMemorySlackMirror(),
    onKickoff: (r) => stderr.writeln(
      'slack bot: kickoff ${r.mirroredAs} path=${r.path.channel}/${r.path.threadTs} '
      'epoch=${r.epoch} wantsTurn=${r.wantsTurn}',
    ),
    onWithdraw: (r) => stderr.writeln(
      'slack bot: withdraw ${r.withdrew} path=${r.path.channel}/${r.path.threadTs} '
      'epoch=${r.epoch} wantsTurn=${r.wantsTurn}',
    ),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('slack bot listening on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    stderr.writeln(
      'warning: bound to ${address.address}, which serves plain HTTP; '
      'put TLS in front or Slack signatures travel in clear',
    );
  }
  await for (final req in server) {
    unawaited(bot.handle(req));
  }
}

/// The HTTP front end. Pulled out of `main` so a test can drive it with a
/// synthesised [HttpRequest] without opening a port.
///
/// On a gate `trigger` outcome whose doorbell `parseDoorbellToSlackNode` can
/// handle (`slack_mention`, `slack_message`), the bot runs the full pipe:
/// parse → `SlackReceiver.receive` (writes to the mirror, mints a
/// [KickoffRecord]) → [onKickoff]. `slack_command` doorbells skip the mirror
/// entirely — slash commands are consumed by the model-selection surface,
/// not the thread mirror. Without a [mirror] the bot still ACKs correctly
/// signed events but does no mirror work; useful for tests that only care
/// about the HTTP front end.
class SlackBot {
  SlackBot({
    required this.spec,
    this.mirror,
    ActorId? selfActor,
    this.onKickoff,
    this.onWithdraw,
    this.onCommand,
    DateTime Function()? now,
    this.bodyTimeout = const Duration(seconds: 10),
    this.log = _stderr,
  })  : _now = now ?? DateTime.now,
        _receiver = mirror == null
            ? null
            : SlackReceiver(
                mirror: mirror,
                selfActor: selfActor ??
                    SlackActorId.forWorkspace(
                      workspaceId: 'unset',
                      userId: 'unset',
                    ),
              );

  final SlackSourceSpec spec;

  /// The thread mirror. If null, the bot ACKs and logs but does not parse
  /// or record. Populated in `main` with an [InMemorySlackMirror].
  final SlackMirror? mirror;

  /// What to do with each [KickoffRecord] the receiver mints. Task 11 wires
  /// this to the agent-host client; in tests it's a list-appender.
  final void Function(KickoffRecord record)? onKickoff;

  /// What to do with each [WithdrawRecord]. Reaction withdrawals (the
  /// is_shapes-doctrine way SlackReactions are taken back) travel this seam
  /// instead of [onKickoff] because a withdrawal is not a new mirror node;
  /// it is a side-table write plus a signal to the turn engine.
  final void Function(WithdrawRecord record)? onWithdraw;

  /// Slash-command sink. Slash commands have no mirror path — they're a
  /// different surface. Defaulting to null drops them with a log line.
  final void Function(Map<String, dynamic> doorbell)? onCommand;

  final SlackReceiver? _receiver;

  final DateTime Function() _now;
  final Duration bodyTimeout;
  final void Function(String line) log;

  /// Replay cache: digest → first-seen time. A LinkedHashMap gives us LRU
  /// semantics by insertion order, and we prune by both age and size at
  /// every insert. In-memory only; a bot restart loses the cache, and the
  /// only consequence is one re-fanout of a very recent event, which the
  /// gate's timestamp window already bounds to five minutes.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  static void _stderr(String line) => stderr.writeln(line);

  Future<void> handle(HttpRequest req) async {
    try {
      if (req.method == 'POST' && req.uri.path == '/webhook/slack') {
        await _webhook(req);
      } else {
        await _end(req, HttpStatus.notFound);
      }
    } catch (e) {
      log('slack bot: $e');
      try {
        await _end(req, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _webhook(HttpRequest req) async {
    const cap = 1024 * 1024;
    if (req.contentLength > cap) {
      await _end(req, HttpStatus.requestEntityTooLarge);
      return;
    }
    final body = <int>[];
    var tooLarge = false;
    try {
      await () async {
        await for (final chunk in req) {
          if (body.length + chunk.length > cap) {
            await _end(req, HttpStatus.requestEntityTooLarge);
            tooLarge = true;
            return;
          }
          body.addAll(chunk);
        }
      }().timeout(bodyTimeout);
    } on TimeoutException {
      log('slack bot: webhook body too slow');
      await _end(req, HttpStatus.requestTimeout);
      return;
    }
    if (tooLarge) return;

    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.first);
    final contentType = req.headers.contentType?.toString() ?? '';
    final now = _now();

    final d = slackGate(
      spec: spec,
      headers: headers,
      body: body,
      contentType: contentType,
      now: now,
      hasSeen: _hasSeen,
    );
    log('slack bot: ${d.outcome.name}: ${d.reason}');
    if (d.digest != null) _markSeen(d.digest!, now);

    switch (d.outcome) {
      case SlackGateOutcome.urlVerification:
        // Slack expects the challenge in the body with 200. No signature on
        // the response.
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.text;
        req.response.write(d.challenge ?? '');
        await req.response.close();
      case SlackGateOutcome.trigger:
        // ACK first, run the handler in the background. Slack times out
        // after 3s and retries up to 3x; the handler often needs longer than
        // that, and the replay cache guards against the retries that fire
        // if we are mid-run.
        await _end(req, HttpStatus.ok);
        unawaited(_dispatch(d.message!));
      case SlackGateOutcome.ignore:
        await _end(req, HttpStatus.ok);
      case SlackGateOutcome.reject:
        // No reason in the response body: it would be a hint to whoever is
        // guessing. The log holds the reason.
        await _end(req, HttpStatus.unauthorized);
    }
  }

  Future<void> _dispatch(Map<String, dynamic> doorbell) async {
    try {
      final event = doorbell['event'];
      if (event == 'slack_command') {
        final sink = onCommand;
        if (sink == null) {
          log('slack bot: slash command dropped (no onCommand): '
              '${doorbell['command']} by ${doorbell['user']}');
        } else {
          sink(doorbell);
        }
        return;
      }
      final receiver = _receiver;
      if (receiver == null) {
        // No mirror wired — ACK path still works; the parse+write pipeline
        // just isn't engaged. Tests that skip the mirror land here.
        return;
      }
      if (event == 'slack_reaction_removed') {
        // Withdrawals don't produce a SlackNode, so they travel their own
        // parser + receiver seam. A null return means the mirror has no
        // record of the reaction being undone — log and drop; nothing is
        // dropped silently because the gate's log line already said we
        // woke on it.
        final out = parseDoorbellToWithdraw(
          doorbell,
          locate: mirror!.locate,
          findReaction: mirror!.findReaction,
        );
        if (out == null) {
          log('slack bot: reaction_removed with no mirror target — dropped');
          return;
        }
        final record = receiver.withdraw(out.$1, out.$2);
        onWithdraw?.call(record);
        return;
      }
      final (path, node) = parseDoorbellToSlackNode(
        doorbell,
        lookup: mirror!.find,
        locate: mirror!.locate,
      );
      final record = receiver.receive(path, node);
      onKickoff?.call(record);
    } catch (e, s) {
      log('slack bot: handler error: $e\n$s');
    }
  }

  bool _hasSeen(String digest) {
    final at = _seen[digest];
    if (at == null) return false;
    if (_now().difference(at) > _replayTtl) {
      _seen.remove(digest);
      return false;
    }
    return true;
  }

  void _markSeen(String digest, DateTime at) {
    // Move-to-front for LRU.
    _seen.remove(digest);
    _seen[digest] = at;
    while (_seen.length > _replayMax) {
      _seen.remove(_seen.keys.first);
    }
    // Opportunistic age-prune so the cache doesn't carry dead entries across
    // quiet periods: we only visit this path on inserts, which is fine.
    final cutoff = at.subtract(_replayTtl);
    while (_seen.isNotEmpty && _seen.values.first.isBefore(cutoff)) {
      _seen.remove(_seen.keys.first);
    }
  }

  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }
}
