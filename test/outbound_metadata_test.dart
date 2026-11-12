import 'package:is_slack_module/is_slack_module.dart';
import 'package:test/test.dart';

final _path = SlackThread(
  workspace: 'T01ABC',
  channel: 'C01',
  threadTs: '1730000000.000100',
);

Map<String, dynamic> _stamped({
  String workspace = 'T01ABC',
  String channel = 'C01',
  String threadTs = '1730000000.000100',
  int epoch = 1,
  String? eventType,
}) =>
    {
      'metadata': {
        'event_type': eventType ?? intersyntacticSlackReplyEventType,
        'event_payload': {
          'workspace': workspace,
          'channel': channel,
          'thread_ts': threadTs,
          'epoch': epoch,
        },
      },
    };

void main() {
  group('extractIntersyntacticStamp', () {
    test('returns null for a message with no metadata', () {
      expect(extractIntersyntacticStamp({'text': 'hello'}), isNull);
    });

    test('returns null for metadata with a different event_type', () {
      expect(
        extractIntersyntacticStamp(_stamped(eventType: 'some.other.app')),
        isNull,
      );
    });

    test('returns null when the payload is missing fields', () {
      final raw = {
        'metadata': {
          'event_type': intersyntacticSlackReplyEventType,
          'event_payload': {'workspace': 'T01ABC'},
        },
      };
      expect(extractIntersyntacticStamp(raw), isNull);
    });

    test('returns null when epoch is not an int', () {
      final raw = {
        'metadata': {
          'event_type': intersyntacticSlackReplyEventType,
          'event_payload': {
            'workspace': 'T01ABC',
            'channel': 'C01',
            'thread_ts': '1730000000.000100',
            'epoch': '1', // string, not int
          },
        },
      };
      expect(extractIntersyntacticStamp(raw), isNull);
    });

    test('extracts a well-formed stamp', () {
      final stamp = extractIntersyntacticStamp(_stamped(epoch: 3))!;
      expect(stamp.path, equals(_path));
      expect(stamp.epoch, 3);
    });
  });

  group('IntersyntacticStamp.isForeign', () {
    test('older epoch than local → foreign (zombie wrote this)', () {
      final stamp = IntersyntacticStamp(path: _path, epoch: 1);
      expect(stamp.isForeign(localEpoch: 2), isTrue);
    });

    test('same epoch as local → not foreign (we wrote this)', () {
      final stamp = IntersyntacticStamp(path: _path, epoch: 2);
      expect(stamp.isForeign(localEpoch: 2), isFalse);
    });

    test('newer epoch than local → not foreign (we are the zombie here)', () {
      final stamp = IntersyntacticStamp(path: _path, epoch: 3);
      expect(stamp.isForeign(localEpoch: 2), isFalse,
          reason:
              'A newer stamp means another receiver has taken over; this '
              'receiver is itself stale. The right response is NOT to drop '
              'the message as foreign — the message is correct, we are '
              'behind. The foreign-drop logic is one-way on purpose.');
    });
  });
}
