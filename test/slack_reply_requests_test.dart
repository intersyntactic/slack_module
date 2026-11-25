import 'dart:typed_data';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_effects/is_effects.dart';
import 'package:is_reply_vocabulary/is_reply_vocabulary.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_slack_module/is_slack_module.dart' show SlackReplyRequests;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart';
import 'package:test/test.dart';

/// The wire contract with Slack's `chat.postMessage`: what is sent, and
/// how each answer is read.
void main() {
  const writer = SlackReplyRequests();
  final slack = Origin.parse('https://slack.com')!;
  final trajectory = TrajectoryId.of(Uint8List.fromList([1]));
  final inThread = RepliesInSlackConversation(
    origin: slack,
    channel: SlackChannelId.parse('C0DEPLOYS')!,
    thread: SlackMessageTimestamp.parse('1800000001.000100'),
  );

  List<ProposedRequest> draw(
    String text, {
    String? footer,
    ReplyEndpoint? to,
  }) => writer.draw(
    (to ?? inThread) as RepliesInSlackConversation,
    trajectory,
    ReplyContent(
      text: ReplyText.parse(text)!,
      footer: footer == null ? null : ReplyText.parse(footer),
    ),
  );

  JsonObject sent(ProposedRequest r) => JsonObject.decode(r.body!);

  test('a reply is one POST the endpoint admits, with no sign-in', () {
    final [r] = draw('staging passed step 1');
    expect(inThread.admitsAddress(r.origin, r.path), isTrue);
    expect(r.method, Method.post);
    expect(r.path.value, '/api/chat.postMessage');
    expect(r.signIn, isNull);
    expect(r.keep, BodyToKeep.text);
    expect(sent(r).asUncheckedMap(), {
      'channel': 'C0DEPLOYS',
      'thread_ts': '1800000001.000100',
      'text': 'staging passed step 1',
    });
  });

  test('a DM names no thread', () {
    final [r] = draw(
      'hi',
      to: RepliesInSlackConversation(
        origin: slack,
        channel: SlackChannelId.parse('D0ADA')!,
      ),
    );
    expect(sent(r).has('thread_ts'), isFalse);
  });

  test('mentions in the text are shown as written, never pinging', () {
    final [r] = draw('<!channel> & <@U0BEA> a<b>c');
    expect(
      sent(r).string('text'),
      '&lt;!channel&gt; &amp; &lt;@U0BEA&gt; a&lt;b&gt;c',
    );
  });

  test('a long reply splits at line breaks, in order, every piece fits', () {
    final line = '${'x' * 99}\n';
    final text = line * 100; // 10,000 code units
    final rs = draw(text);
    expect(rs.length, 3);
    final texts = [for (final r in rs) sent(r).string('text')];
    expect(texts.every((t) => t.length <= SlackReplyRequests.piece), isTrue);
    expect(texts.join('\n'), text);
  });

  test('a split never cuts an escape or a character', () {
    final text = '${'y' * 3998}&😀${'z' * 10}';
    final texts = [for (final r in draw(text)) sent(r).string('text')];
    expect(texts.first.endsWith('y'), isTrue);
    expect(texts.join(), '${'y' * 3998}&amp;😀${'z' * 10}');
  });

  test('the footer ends the last message, or follows it when too long', () {
    final [r] = draw('done', footer: 'model: x');
    expect(sent(r).string('text'), 'done\n\nmodel: x');
    final rs = draw('w' * 3999, footer: 'model: x');
    expect(rs.length, 2);
    expect(sent(rs.last).string('text'), 'model: x');
  });

  test('the footer is escaped too, wherever it goes', () {
    final [r] = draw('done', footer: '<!here>');
    expect(sent(r).string('text'), 'done\n\n&lt;!here&gt;');
    final rs = draw('w' * 3999, footer: '<!here>');
    expect(sent(rs.last).string('text'), '&lt;!here&gt;');
  });

  group('posted', () {
    WebResponse ok(String body) =>
        WebResponse(status: 200, body: TextBody(body));

    test('ok with a ts ran', () {
      final o = writer.posted(ok('{"ok":true,"ts":"1800000002.000200"}'));
      expect(
        (o as Ran<SlackMessageTimestamp>).output.value,
        '1800000002.000200',
      );
    });

    test('ok:false is Slack saying nothing posted', () {
      final o = writer.posted(ok('{"ok":false,"error":"channel_not_found"}'));
      expect((o as NothingRan).why, contains('channel_not_found'));
    });

    test('a rate limit refused it', () {
      expect(writer.posted(const WebResponse(status: 429)), isA<NothingRan>());
    });

    test('anything it cannot read may have posted', () {
      for (final r in [
        const WebResponse(status: 500),
        const WebResponse(status: 200),
        ok('not json'),
        ok('{"ok":true}'),
        ok('{"ok":true,"ts":"soon"}'),
        ok('{"ts":"1800000002.000200"}'),
      ]) {
        final o = writer.posted(r);
        expect(o, isA<StoppedPartway<SlackMessageTimestamp>>());
        expect((o as StoppedPartway<SlackMessageTimestamp>).done, isNull);
      }
    });
  });
}
