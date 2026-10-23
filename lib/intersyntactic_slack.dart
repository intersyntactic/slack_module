/// A Slack adapter for intersyntactic.
///
/// The public surface is small on purpose: a pure [slackGate] for verifying
/// and parsing inbound Slack deliveries, so the gate's decisions can be tested
/// without a socket, a clock or Slack. The HTTP handler, the Slack Web API
/// client, the credential store and the agent-loop glue are added as separate
/// files under `lib/src/` and re-exported here as they land.
library;

export 'src/slack_gate.dart';
