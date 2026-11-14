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
import 'dart:io';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:is_shapes/is_shapes.dart';

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

/// The domain front end. Pulled out of `main` so a test can drive it with a
/// synthesised [HttpRequest] without opening a port.
///
/// Wraps a [SlackRelay], which owns everything generic — signature
/// verification, replay dedupe, the HTTP bind, ACK timing — and knows
/// nothing of mirrors, node shapes or kickoff records. [SlackBot] is what
/// turns the relay's typed [SlackEvent] into those: a [SlackMessage] or
/// [SlackReactionAdded] runs parse → `SlackReceiver.receive` (writes to the
/// mirror, mints a [KickoffRecord]) → [onKickoff]. A [SlackCommand] skips
/// the mirror entirely — slash commands are consumed by the model-selection
/// surface, not the thread mirror. Without a [mirror] the bot still ACKs
/// correctly signed events but does no mirror work; useful for tests that
/// only care about the HTTP front end.
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
  }) : _receiver = mirror == null
            ? null
            : SlackReceiver(
                mirror: mirror,
                selfActor: selfActor ??
                    SlackActorId.forWorkspace(
                      workspaceId: 'unset',
                      userId: 'unset',
                    ),
              ) {
    _relay = relay.SlackRelay(
      spec: spec,
      onEvent: _dispatch,
      now: now,
      bodyTimeout: bodyTimeout,
      log: log,
    );
  }

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
  final void Function(relay.SlackCommand command)? onCommand;

  final SlackReceiver? _receiver;

  final Duration bodyTimeout;
  final void Function(String line) log;

  /// Owns signature verification, replay dedupe, the HTTP bind and ACK
  /// timing. Built in the constructor body so it can tear off [_dispatch]
  /// as its [SlackRelay.onEvent].
  late final relay.SlackRelay _relay;

  static void _stderr(String line) => stderr.writeln(line);

  Future<void> handle(HttpRequest req) => _relay.handle(req);

  Future<void> _dispatch(relay.SlackEvent event) async {
    try {
      switch (event) {
        case relay.SlackCommand():
          final sink = onCommand;
          if (sink == null) {
            log('slack bot: slash command dropped (no onCommand): '
                '${event.command} by ${event.user}');
          } else {
            sink(event);
          }
        case relay.SlackReactionRemoved():
          final receiver = _receiver;
          if (receiver == null) return;
          // Withdrawals don't produce a SlackNode, so they travel their own
          // parser + receiver seam. A null return means the mirror has no
          // record of the reaction being undone — log and drop; nothing is
          // dropped silently because the relay's log line already said we
          // woke on it.
          final out = parseReactionRemovedToWithdraw(
            event,
            locate: mirror!.locate,
            findReaction: mirror!.findReaction,
          );
          if (out == null) {
            log('slack bot: reaction_removed with no mirror target — dropped');
          } else {
            onWithdraw?.call(receiver.withdraw(out.$1, out.$2));
          }
        case relay.SlackMessage():
          final receiver = _receiver;
          if (receiver == null) return;
          final (path, node) = parseMessageToSlackNode(
            event,
            lookup: mirror!.find,
          );
          onKickoff?.call(receiver.receive(path, node));
        case relay.SlackReactionAdded():
          final receiver = _receiver;
          if (receiver == null) return;
          final (path, node) = parseReactionAddedToSlackNode(
            event,
            locate: mirror!.locate,
          );
          onKickoff?.call(receiver.receive(path, node));
      }
    } catch (e, s) {
      log('slack bot: handler error: $e\n$s');
    }
  }
}
