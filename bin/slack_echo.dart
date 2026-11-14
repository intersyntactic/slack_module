/// A TEST bot: the relay, with an onEvent handler that answers through the
/// Slack Web API. It proves the round trip against real Slack traffic
/// before the mirror, receiver or turn engine land, and it is not the
/// module's shape: in the module the mirror/receiver side does the work and
/// a driver (not this binary) holds the bot token, per the drivers ruling.
///
///   SLACK_SIGNING_SECRET=...        from Slack app's Basic Information page
///   SLACK_BOT_TOKEN=xoxb-...        required — without it there is nothing
///                                   to echo with
///   SLACK_TEAM_ID_ALLOWLIST=T1,T2   workspaces whose events are accepted;
///                                   empty is "any correctly signed workspace"
///                                   and should only be used in tests
///   PORT=8088                       optional; 8087 is teams_echo's. A
///                                   non-port aborts.
///   HOST=127.0.0.1                  optional; as for slack_bot.dart.
///
/// In Slack: say anything (a plain message, or an @-mention) in a channel
/// the bot is in, and it echoes; react to a message and it's logged, not
/// replied to (there's no sensible "reply" to a reaction from a bare echo
/// bot); run a configured slash command and it acks with a post to the
/// invoking channel.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_slack_module/is_slack_module.dart';
import 'package:is_slack_relay/is_slack_relay.dart' as relay;

Future<void> main() async {
  final env = Platform.environment;
  String need(String name) {
    final v = env[name] ?? '';
    if (v.isEmpty) {
      stderr.writeln('abort: $name not set');
      exit(78);
    }
    return v;
  }

  final signingSecret = need('SLACK_SIGNING_SECRET');
  final botToken = need('SLACK_BOT_TOKEN');
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

  final rawPort = env['PORT'];
  final port = rawPort == null || rawPort.isEmpty ? 8088 : int.tryParse(rawPort);
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

  final client = SlackClient(token: botToken, sender: _dartIoSend);
  final relayServer = relay.SlackRelay(
    spec: relay.SlackSourceSpec(
      signingSecret: signingSecret,
      teamIdAllowlist: allow,
    ),
    onEvent: (event) => _answer(client, event),
  );

  final server = await HttpServer.bind(address, port);
  stdout.writeln('slack echo listening on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    stderr.writeln(
      'warning: bound to ${address.address}, which serves plain HTTP; '
      'put TLS in front or Slack signatures travel in clear',
    );
  }
  await for (final req in server) {
    unawaited(relayServer.handle(req));
  }
}

Future<void> _answer(SlackClient client, relay.SlackEvent event) async {
  try {
    switch (event) {
      case relay.SlackMessage(:final text, :final mention) when text != null:
        stderr.writeln(
          'echo: ${mention ? 'mention' : 'message'} in ${event.channel}: $text',
        );
        await client.chatPostMessage(
          channel: event.channel,
          threadTs: event.threadTs,
          text: 'echo: $text',
        );
      case relay.SlackMessage():
        // No text (e.g. an edit/delete subtype, or a content-free event) —
        // nothing to echo.
        stderr.writeln('echo: message in ${event.channel} with no text — skipped');
      case relay.SlackReactionAdded(:final reaction, :final user):
        stderr.writeln('echo: reaction_added $reaction by $user — logged, no reply');
      case relay.SlackReactionRemoved(:final reaction, :final user):
        stderr.writeln('echo: reaction_removed $reaction by $user — logged, no reply');
      case relay.SlackCommand(:final command, :final text, :final user):
        stderr.writeln('echo: command $command "$text" by $user');
        await client.chatPostMessage(
          channel: event.channel,
          threadTs: event.threadTs,
          text: 'echo: $command $text',
        );
    }
  } on SlackApiError catch (e) {
    stderr.writeln('echo: $e');
  }
}

/// A real [SlackSend] over `dart:io`, with a ten-second limit on each step.
/// Nothing else in this package needed one yet — [SlackClient] takes its
/// sender injected so tests never open a socket.
Future<SlackHttpResponse> _dartIoSend(SlackHttpRequest req) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final httpReq = await client.openUrl(req.method, req.url);
    req.headers.forEach(httpReq.headers.set);
    httpReq.add(req.body);
    final res = await httpReq.close().timeout(const Duration(seconds: 10));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 10));
    final headers = <String, String>{};
    res.headers.forEach((name, values) => headers[name] = values.first);
    return SlackHttpResponse(
      statusCode: res.statusCode,
      headers: headers,
      body: body,
    );
  } finally {
    client.close();
  }
}
