import 'dart:typed_data';

import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, VerdictOnShownMessage;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId, UserSaid;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_slack_relay/is_slack_relay.dart' as relay;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin;

import 'slack_actor_id.dart';

/// Where every Slack reply is sent: one site for every workspace, since the
/// bot's sign-in names the workspace.
final slackReplyOrigin = Origin.parse('https://slack.com')!;

/// The Slack module's translator, for the docking station: what each event
/// the Slack relay recorded is, in the docking station's terms, in the
/// logbook's order. It describes and decides nothing.
///
/// - A message from a person, or from a bot that isn't ours, such as CI
///   posting a deploy, is [MessageSaid]. A mention delivered both as
///   `app_mention` and as `message` shares one key, `message:<ts>`, so the
///   docking station decides it once.
/// - A message from our own bot, the user Slack delivered the event for, is
///   [NothingToAdmit], but remembered as something shown, so a reaction on
///   it can be a verdict. A bot's message when Slack named no user it was
///   delivered for is [NothingToAdmit] too: it may be ours, and admitting
///   our own replies would feed the agent its own words.
/// - ✅ or ✔️ on our bot's message, from anyone but our bot, is
///   [ShownMessageJudged] approved; ❌ is held off. Our bot's own reaction,
///   such as one it seeds for people to click, is no verdict. Any other
///   reaction, a reaction removed, an edit, a delete and a slash command are
///   [NothingToAdmit] for now.
///
/// Addresses: in a channel or a group DM each thread is its own address,
/// `slack:<channel>/<thread ts>`, sitting inside the channel's,
/// `slack:<channel>`. A DM with one person is one address, `slack:<channel>`,
/// inside none. Channel ids are global in Slack, so no workspace is in an
/// address.
///
/// Replies go to [RepliesInSlackConversation] at [slackReplyOrigin]: the
/// event's channel, and its thread, which for a top-level post is the post
/// itself. A DM with one person has no thread. A channel id Slack's reply
/// can't name leaves the event with no reply endpoint.
final class SlackEventTranslator
    implements TranslatesRelayedEvents<SlackEventTranslatorState> {
  const SlackEventTranslator({this.parse = relay.slackRecordedEvent});

  /// The relay's parse of one recorded delivery's bytes, the same one its
  /// gate runs after checking the signature.
  final relay.SlackEvent? Function(Uint8List bytes) parse;

  @override
  RelayedEventSource get source => relay.slackEventSource;

  @override
  SlackEventTranslatorState get start => SlackEventTranslatorState.empty;

  @override
  (SlackEventTranslatorState, TranslatedEvent) step(
    SlackEventTranslatorState state,
    RelayedEvent recorded,
  ) {
    final event = parse(recorded.bytes);
    if (event == null) return (state, const NothingToAdmit());
    final next = state.learnt(event);
    return (next, _translate(event, next) ?? const NothingToAdmit());
  }

  static TranslatedEvent? _translate(
    relay.SlackEvent event,
    SlackEventTranslatorState state,
  ) {
    final addressedTo = switch (event.deliveredForUser) {
      final bot? => _actor(event, bot),
      null => null,
    };
    switch (event) {
      case relay.SlackMessage():
        if (_SlackSender.of(event) case _OtherSender(:final id)) {
          final place = _SlackPlace.of(event);
          final ts = event.eventTs;
          if (place == null || ts == null || !_isSaid(event.subtype)) {
            return null;
          }
          final source = SourceMessageId.parse('${event.channel}|$ts');
          final key = EventKey.parse('message:$ts');
          final text = _withoutMentionOf(
            event.deliveredForUser,
            event.text ?? '',
          );
          if (source == null || key == null || text.isEmpty) return null;
          return MessageSaid(
            addressInExternalSystem: place.address,
            containingAddress: place.containing,
            addressedTo: addressedTo,
            replyEndpoint: place.reply,
            key: key,
            node: UserSaid(
              author: _actor(event, id),
              source: source,
              text: text,
            ),
          );
        }
        return null;
      case relay.SlackReactionAdded():
        final shown = state._shown[(event.channel, event.targetTs)];
        final verdict = SlackVerdictReaction.parse(event.reaction)?.verdict;
        final to = SourceMessageId.parse('${event.channel}|${event.targetTs}');
        final key = EventKey.parse(
          'reaction:${event.targetTs}:${event.user}:${event.eventTs}',
        );
        final byOurBot = switch (event.deliveredForUser) {
          final bot? => event.user == bot,
          // No one named the delivery's recipient, so it may be ours.
          null => true,
        };
        if (byOurBot ||
            shown == null ||
            verdict == null ||
            to == null ||
            key == null) {
          return null;
        }
        return ShownMessageJudged(
          addressInExternalSystem: shown.address,
          containingAddress: shown.containing,
          addressedTo: addressedTo,
          replyEndpoint: shown.reply,
          from: _actor(event, event.user),
          key: key,
          to: to,
          verdict: verdict,
        );
      case relay.SlackReactionRemoved() || relay.SlackCommand():
        return null;
    }
  }

  /// A plain message, a `/me`, a thread reply also sent to the channel, a
  /// message with a file, or a bot's post: something said. An edit, a
  /// delete, a join and the rest are not. Every case is named, so a subtype
  /// the relay adds fails to compile here rather than go quietly unsaid.
  static bool _isSaid(relay.SlackMessageSubtype? subtype) => switch (subtype) {
    null ||
    relay.SlackMessageSubtype.meMessage ||
    relay.SlackMessageSubtype.threadBroadcast ||
    relay.SlackMessageSubtype.fileShare ||
    relay.SlackMessageSubtype.botMessage => true,
    relay.SlackMessageSubtype.messageChanged ||
    relay.SlackMessageSubtype.messageDeleted ||
    relay.SlackMessageSubtype.messageReplied ||
    relay.SlackMessageSubtype.channelJoin ||
    relay.SlackMessageSubtype.channelLeave ||
    relay.SlackMessageSubtype.channelTopic ||
    relay.SlackMessageSubtype.channelPurpose ||
    relay.SlackMessageSubtype.channelName ||
    relay.SlackMessageSubtype.channelArchive ||
    relay.SlackMessageSubtype.channelUnarchive ||
    relay.SlackMessageSubtype.channelConvertToPrivate ||
    relay.SlackMessageSubtype.channelConvertToPublic ||
    relay.SlackMessageSubtype.channelPostingPermissions ||
    relay.SlackMessageSubtype.groupJoin ||
    relay.SlackMessageSubtype.groupLeave ||
    relay.SlackMessageSubtype.groupTopic ||
    relay.SlackMessageSubtype.groupPurpose ||
    relay.SlackMessageSubtype.groupName ||
    relay.SlackMessageSubtype.groupArchive ||
    relay.SlackMessageSubtype.groupUnarchive ||
    relay.SlackMessageSubtype.pinnedItem ||
    relay.SlackMessageSubtype.unpinnedItem ||
    relay.SlackMessageSubtype.reminderAdd ||
    relay.SlackMessageSubtype.ekmAccessDenied ||
    relay.SlackMessageSubtype.assistantAppThread ||
    relay.SlackMessageSubtype.huddleThread ||
    relay.SlackMessageSubtype.unnamed => false,
  };

  /// [id] in [event]'s workspace, or its Enterprise Grid org when it has one.
  static ActorId _actor(relay.SlackEvent event, String id) =>
      switch (event.enterprise) {
        final org? => SlackActorId.forGrid(enterpriseId: org, userId: id),
        null => SlackActorId.forWorkspace(
          workspaceId: event.workspace,
          userId: id,
        ),
      };

  /// [text] without [bot]'s mention at its start, `<@U…>` or `<@U…|name>`.
  /// Anyone else's mention stays: it says who the message is for.
  static String _withoutMentionOf(String? bot, String text) => switch (bot) {
    final bot? => text.replaceFirst(
      RegExp('^\\s*<@${RegExp.escape(bot)}(\\|[^>]*)?>\\s*'),
      '',
    ),
    null => text,
  }.trim();
}

/// Who sent a message: our own bot, a bot that may be ours, or someone
/// else, a person or another bot, by the id they're named by.
sealed class _SlackSender {
  const _SlackSender();

  static _SlackSender? of(relay.SlackMessage m) {
    final (user, bot, ours) = (m.user, m.botId, m.deliveredForUser);
    // Before the bot id: our bot's post is ours whether Slack sent one.
    if (ours != null && user == ours) return const _OurBot();
    if (bot == null) return user == null ? null : _OtherSender(user);
    if (ours == null) return const _MaybeOurBot();
    // A webhook post names no user; its bot id is all there is.
    return _OtherSender(user ?? bot);
  }
}

final class _OurBot extends _SlackSender {
  const _OurBot();
}

final class _MaybeOurBot extends _SlackSender {
  const _MaybeOurBot();
}

final class _OtherSender extends _SlackSender {
  const _OtherSender(this.id);
  final String id;
}

/// The reactions read as a verdict on something our bot showed.
enum SlackVerdictReaction {
  whiteCheckMark('white_check_mark', ApprovedVerdict()),
  heavyCheckMark('heavy_check_mark', ApprovedVerdict()),
  x('x', HeldOffVerdict());

  const SlackVerdictReaction(this.emoji, this.verdict);

  /// The emoji's name as Slack sends it, without colons.
  final String emoji;

  final VerdictOnShownMessage verdict;

  /// [name] as Slack sent it, skin tone and all; null for any other emoji.
  static SlackVerdictReaction? parse(String name) {
    final base = name.split('::').first;
    for (final r in values) {
      if (r.emoji == base) return r;
    }
    return null;
  }
}

/// Where a message sits: its address, the one that address sits in, and
/// where a reply to it goes.
final class _SlackPlace {
  const _SlackPlace(this.address, this.containing, this.reply);

  final AddressInExternalSystem address;
  final AddressInExternalSystem? containing;
  final RepliesInSlackConversation? reply;

  /// A DM with one person is one address; anywhere else, a group DM
  /// included, each thread is one, inside its channel. An `app_mention`
  /// names no channel type, and is never in a DM with one person, so it is
  /// placed as its `message` copy is, wherever else it was sent.
  static _SlackPlace? of(relay.SlackMessage m) {
    final channel = AddressInExternalSystem.parse('slack:${m.channel}');
    if (channel == null) return null;
    if (m.channelType == relay.SlackChannelType.im) {
      return _SlackPlace(channel, null, _replyIn(m.channel, null));
    }
    final thread = AddressInExternalSystem.parse(
      'slack:${m.channel}/${m.threadTs}',
    );
    if (thread == null) return null;
    return _SlackPlace(thread, channel, _replyIn(m.channel, m.threadTs));
  }

  /// A reply in [channel], in [thread] unless that's null; null when Slack's
  /// reply can't name either.
  static RepliesInSlackConversation? _replyIn(String channel, String? thread) {
    final id = SlackChannelId.parse(channel);
    if (id == null) return null;
    if (thread == null) {
      return RepliesInSlackConversation(origin: slackReplyOrigin, channel: id);
    }
    return switch (SlackMessageTimestamp.parse(thread)) {
      final ts? => RepliesInSlackConversation(
        origin: slackReplyOrigin,
        channel: id,
        thread: ts,
      ),
      null => null,
    };
  }
}

/// What the Slack translator carries from one event to the next: our bot's
/// messages, by channel and ts, with where each sits.
///
/// Never changed: [learnt] gives a new one when there is something new.
final class SlackEventTranslatorState {
  const SlackEventTranslatorState._(this._shown);

  /// Before any event.
  static const empty = SlackEventTranslatorState._({});

  final Map<(String, String), _SlackPlace> _shown;

  /// This, with [event] remembered when it is our bot's message.
  SlackEventTranslatorState learnt(relay.SlackEvent event) {
    if (event case relay.SlackMessage(:final eventTs?)
        when _SlackSender.of(event) is _OurBot) {
      final place = _SlackPlace.of(event);
      if (place == null) return this;
      return SlackEventTranslatorState._(
        Map.unmodifiable({..._shown, (event.channel, eventTs): place}),
      );
    }
    return this;
  }
}
