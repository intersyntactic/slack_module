/// A Slack adapter for intersyntactic.
///
/// The public surface is small on purpose: a pure [slackGate] for verifying
/// and parsing inbound Slack deliveries, so the gate's decisions can be tested
/// without a socket, a clock or Slack. The HTTP handler, the Slack Web API
/// client, the credential store and the agent-loop glue are added as separate
/// files under `lib/src/` and re-exported here as they land.
library;

export 'src/gate_parser.dart';
export 'src/journey_path_id.dart';
export 'src/outbound_metadata.dart';
export 'src/shapes.dart';
export 'src/slack_actor_id.dart';
export 'src/slack_client.dart';
export 'src/slack_gate.dart';
export 'src/slack_mirror.dart';
export 'src/slack_receiver.dart';
export 'src/slack_reply.dart';
export 'src/turn_event.dart';
