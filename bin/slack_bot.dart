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
  final bot = SlackBot(spec: spec);
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
class SlackBot {
  SlackBot({
    required this.spec,
    this.handleTrigger = _logTrigger,
    DateTime Function()? now,
    this.bodyTimeout = const Duration(seconds: 10),
    this.log = _stderr,
  }) : _now = now ?? DateTime.now;

  final SlackSourceSpec spec;

  /// What to do when the gate says this delivery is a wake. Defaulted to a
  /// logger so the first drop runs end-to-end without the agent-loop glue;
  /// the real handler is injected here as it lands.
  final Future<void> Function(Map<String, dynamic> message) handleTrigger;

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

  static Future<void> _logTrigger(Map<String, dynamic> message) async {
    stderr.writeln('slack bot: trigger ${message['event']} '
        '${message['channel']} ${message['thread_ts']}');
  }

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

  Future<void> _dispatch(Map<String, dynamic> message) async {
    try {
      await handleTrigger(message);
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
