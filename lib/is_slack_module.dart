/// A Slack adapter for intersyntactic.
///
/// The public surface is small on purpose: verifying and parsing inbound
/// Slack deliveries, the HTTP front end and the replay dedupe live in
/// `is_slack_relay`, re-exported here so a consumer of this package never
/// needs that import directly. The Slack Web API client, the credential
/// store and the agent-loop glue are added as separate files under
/// `lib/src/` and re-exported here as they land.
library;

export 'package:is_slack_relay/is_slack_relay.dart';

export 'src/gate_parser.dart';
export 'src/slack_thread.dart';
export 'src/outbound_metadata.dart';
export 'src/shapes.dart';
export 'src/slack_actor_id.dart';
export 'src/slack_client.dart';
export 'src/slack_mirror.dart';
export 'src/slack_receiver.dart';
export 'src/slack_reply.dart';
export 'src/turn_event.dart';
