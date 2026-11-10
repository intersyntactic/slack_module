import 'package:intersyntactic_slack/intersyntactic_slack.dart';
import 'package:test/test.dart';

/// A compile-time check that the family is sealed and exhaustive: adding a
/// seventh variant without updating this switch would make the file fail
/// analysis, which is the point (teams-module-e2 and this module diff their
/// families by comparing exactly this switch set).
String _describe(TurnEvent e) => switch (e) {
      TurnBegan(:final echoedText) => 'began:$echoedText',
      TurnWorking(:final status) => 'working:$status',
      TurnWriting(:final textSoFar) => 'writing:${textSoFar.length}',
      StepEnded() => 'step_ended',
      TurnAsked(:final prompt) => 'asked:$prompt',
      TurnEnded(:final kind, :final detail) => 'ended:${kind.name}:$detail',
    };

void main() {
  final t = DateTime.utc(2026, 11, 10, 22, 0, 0);

  test('each variant describes itself through the sealed switch', () {
    expect(_describe(TurnBegan(at: t, echoedText: 'hi')), 'began:hi');
    expect(_describe(TurnWorking(at: t, status: 'thinking')),
        'working:thinking');
    expect(_describe(TurnWriting(at: t, textSoFar: 'abc')), 'writing:3');
    expect(_describe(StepEnded(at: t)), 'step_ended');
    expect(_describe(TurnAsked(at: t, prompt: 'ok?')), 'asked:ok?');
    expect(
      _describe(TurnEnded(at: t, kind: TurnEndedKind.idle, detail: '')),
      'ended:idle:',
    );
    expect(
      _describe(TurnEnded(
        at: t,
        kind: TurnEndedKind.failed,
        detail: 'boom',
      )),
      'ended:failed:boom',
    );
  });

  test('every variant carries its own host-side timestamp', () {
    final events = <TurnEvent>[
      TurnBegan(at: t, echoedText: 'x'),
      TurnWorking(at: t, status: 's'),
      TurnWriting(at: t, textSoFar: 't'),
      StepEnded(at: t),
      TurnAsked(at: t, prompt: 'q'),
      TurnEnded(at: t, kind: TurnEndedKind.idle, detail: ''),
    ];
    for (final e in events) {
      expect(e.at, t, reason: '${e.runtimeType} must carry `at`');
    }
  });

  test('TurnEndedKind is closed to idle and failed only', () {
    // A third kind would mean the host grew a new terminal state we have not
    // modelled. The switch below pins the set.
    final kinds = TurnEndedKind.values;
    expect(kinds, [TurnEndedKind.idle, TurnEndedKind.failed]);
  });
}
