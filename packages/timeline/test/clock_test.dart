import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('valid clock times', () {
    const cases = {
      '00:00': (hour: 0, minute: 0),
      '07:05': (hour: 7, minute: 5),
      '12:00': (hour: 12, minute: 0),
      '19:30': (hour: 19, minute: 30),
      '23:59': (hour: 23, minute: 59),
    };
    cases.forEach((text, expected) {
      test(text, () => expect(parseClockTime(text), expected));
    });
  });

  group('rejected clock times', () {
    const bad = [
      '', // nothing in it
      '24:00', '17:60', // out of range
      '7:00', '17:0', // not two digits each
      '17:00:00', '5 PM', // other formats
      ' 17:00', '17:00 ', '17:00\n', // whitespace
    ];
    for (final text in bad) {
      test('"$text"', () {
        expect(() => parseClockTime(text), throwsFormatException);
      });
    }
  });

  test('inClockRange takes a zoned time, never a plain DateTime, whose clock '
      'is UTC or the machine zone rather than the protocol zone', () {
    expect(inClockRange, isA<bool Function(QuietHours, tz.TZDateTime)>());
    expect(inClockRange, isNot(isA<bool Function(QuietHours, DateTime)>()));
  });
}
