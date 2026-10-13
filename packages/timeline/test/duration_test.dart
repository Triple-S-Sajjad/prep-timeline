import 'package:test/test.dart';
import 'package:timeline/timeline.dart';

void main() {
  group('valid durations', () {
    final cases = {
      '-PT4H': const Duration(hours: -4),
      'PT2H30M': const Duration(hours: 2, minutes: 30),
      '-PT2H30M': -const Duration(hours: 2, minutes: 30),
      'PT45M': const Duration(minutes: 45),
      'PT120H': const Duration(hours: 120),
      'PT0H': Duration.zero,
    };
    cases.forEach((text, expected) {
      test(text, () => expect(parseElapsed(text), expected));
    });
  });

  group('rejected durations', () {
    const bad = [
      '', 'PT', '-PT', // nothing in it
      'P7D', '-P7D', 'P1DT2H', // calendar days are not allowed
      'PT2S', 'PT1.5H', // seconds and fractions
      'pt2h', ' PT2H', 'PT2H ', 'PT2H\n', // case and whitespace
      'PT-2H', '+PT2H', 'PT30M2H', // sign or order in the wrong place
      'PT99999H', 'PT99999M', // more than 4 digits
      'P2H', // no T
    ];
    for (final text in bad) {
      test('"$text"', () {
        expect(() => parseElapsed(text), throwsFormatException);
      });
    }
  });
}
