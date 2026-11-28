/// One reply drawn for Slack, as the requests that would post it, for a
/// loop to propose to the airlock; and, after they ran, the messages they
/// posted. It sends and proposes nothing itself.
///
///     slack-reply-drawing --reply-endpoint JSON --sign-in NAME \
///         --trajectory HEX < text
///
/// reads the reply's text, UTF-8, on stdin, and prints the requests as one
/// JSON array of is_effects' encodeProposedRequest, in posting order, on
/// stdout: [SlackReplyRequests]' with the sign-in set, each keeping its
/// answer's text so the message's `ts` is in the airlock's result. The
/// reply endpoint is the one the logbook recorded for the conversation, as
/// is_conversation_vocabulary's encodeReplyEndpoint writes it, and must be
/// one of Slack's. No footer is added.
///
///     slack-reply-drawing posted --reply-endpoint JSON < responses
///
/// reads the airlock's result for those requests on stdin, the JSON array
/// of is_effects' encodeWebResponse, one per request in order, and prints
/// what they posted as is_effects' encodeOutcome of the messages' ids, the
/// same ids a reaction on one of them is later said to be on.
///
/// Exit: 0 printed; 64 usage; 65 stdin not usable. On a nonzero exit
/// nothing is printed on stdout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart'
    show decodeJsonRefusingDuplicateKeysAndUnsafeIntegers;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show
        RepliesWithPinnedBodyFields,
        ReplyContent,
        ReplyText,
        decodeReplyEndpoint;
import 'package:is_effects/is_effects.dart'
    show
        ProposedRequest,
        WebResponse,
        decodeWebResponse,
        encodeOutcome,
        encodeProposedRequest;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_slack_module/is_slack_module.dart' show SlackReplyRequests;

const usage =
    'usage: slack-reply-drawing --reply-endpoint JSON --sign-in NAME '
    '--trajectory HEX < text\n'
    '       slack-reply-drawing posted --reply-endpoint JSON < responses';

Future<void> main(List<String> args) async =>
    exit(await run(args, input: stdin, out: stdout, err: stderr));

/// What the program is asked for: the requests for a reply, or, given
/// their responses, what they posted.
enum _Mode {
  draw(null),
  posted('posted');

  const _Mode(this.word);

  /// The first argument that asks for it; null for [draw], which has none.
  final String? word;

  /// The mode [args] ask for, and the flags after it.
  static (_Mode, List<String>) of(List<String> args) {
    for (final mode in values) {
      if (mode.word != null && args.firstOrNull == mode.word) {
        return (mode, args.skip(1).toList());
      }
    }
    return (draw, args);
  }
}

/// The program, with its streams given, so a test can stand in for them.
Future<int> run(
  List<String> args, {
  required Stream<List<int>> input,
  required StringSink out,
  required StringSink err,
}) async {
  final (mode, flags) = _Mode.of(args);
  final known = switch (mode) {
    _Mode.posted => const {'--reply-endpoint'},
    _Mode.draw => const {'--reply-endpoint', '--sign-in', '--trajectory'},
  };
  final options = <String, String>{};
  for (var i = 0; i < flags.length; i += 2) {
    // wire-ok: command-line flags, read once here.
    if (!known.contains(flags[i]) || i + 1 >= flags.length) {
      err.writeln(
        'slack-reply-drawing: unknown or valueless ${flags[i]}\n$usage',
      );
      return 64;
    }
    if (options.containsKey(flags[i])) {
      err.writeln('slack-reply-drawing: ${flags[i]} given twice\n$usage');
      return 64;
    }
    options[flags[i]] = flags[i + 1];
  }

  const writer = SlackReplyRequests();
  final RepliesWithPinnedBodyFields to;
  try {
    final endpoint = decodeReplyEndpoint(
      decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(
        options['--reply-endpoint'] ?? '',
      ),
      'reply endpoint',
    );
    if (endpoint is! RepliesWithPinnedBodyFields ||
        !writer.addresses.contains((
          origin: endpoint.origin,
          path: endpoint.path,
        ))) {
      err.writeln(
        'slack-reply-drawing: --reply-endpoint is not a Slack '
        'conversation\n$usage',
      );
      return 64;
    }
    to = endpoint;
  } on FormatException catch (e) {
    err.writeln('slack-reply-drawing: --reply-endpoint: ${e.message}\n$usage');
    return 64;
  }

  final String text;
  try {
    text = await input.transform(const Utf8Decoder()).join();
  } on FormatException {
    err.writeln('slack-reply-drawing: stdin is not UTF-8');
    return 65;
  }

  if (mode == _Mode.posted) {
    final List<WebResponse> responses;
    try {
      responses = switch (decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(
        text,
      )) {
        final List<Object?> list => [
          for (final (i, r) in list.indexed)
            decodeWebResponse(r, 'responses[$i]'),
        ],
        _ => throw const FormatException('not a JSON array'),
      };
    } on FormatException catch (e) {
      err.writeln('slack-reply-drawing: stdin: ${e.message}');
      return 65;
    }
    out.write(
      jsonEncode(
        encodeOutcome(
          writer.postedMessages(to, responses),
          (ids) => [for (final id in ids) id.value],
        ),
      ),
    );
    return 0;
  }

  final signIn = SignIn.parse(options['--sign-in'] ?? '');
  if (signIn == null) {
    err.writeln(
      'slack-reply-drawing: --sign-in is needed and must parse\n$usage',
    );
    return 64;
  }
  final trajectory = TrajectoryId.parse(options['--trajectory'] ?? '');
  if (trajectory == null) {
    err.writeln(
      'slack-reply-drawing: --trajectory is needed, a TrajectoryId in '
      'lower-case hex\n$usage',
    );
    return 64;
  }
  final replyText = ReplyText.parse(text);
  if (replyText == null) {
    err.writeln('slack-reply-drawing: nothing to say on stdin');
    return 65;
  }
  final requests = [
    for (final r in writer.draw(to, trajectory, ReplyContent(text: replyText)))
      ProposedRequest(
        r.origin,
        method: r.method,
        path: r.path,
        signIn: signIn,
        headers: r.headers,
        body: r.body,
        keep: r.keep,
      ),
  ];
  out.write(jsonEncode([for (final r in requests) encodeProposedRequest(r)]));
  return 0;
}
