import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.Location ny;

  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  tz.TZDateTime at(int y, int mo, int d, [int h = 0, int mi = 0]) =>
      tz.TZDateTime(ny, y, mo, d, h, mi);

  // Expected instants written in UTC, so they can't come from the same
  // constructor the code under test uses.
  int utc(int y, int mo, int d, int h, [int mi = 0]) =>
      DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch;

  group('dayAtTime', () {
    test('day -1 at 17:00 is 17:00 the previous day', () {
      expect(dayAtTime(at(2026, 11, 18, 9), -1, 17, 0), at(2026, 11, 17, 17));
    });
    test('day 0 at 06:00 is the same morning', () {
      expect(dayAtTime(at(2026, 11, 18, 9), 0, 6, 0), at(2026, 11, 18, 6));
    });
    test('a positive day counts forward (after-procedure steps)', () {
      expect(dayAtTime(at(2026, 11, 18, 9), 2, 8, 0), at(2026, 11, 20, 8));
    });
    test('crosses a month boundary', () {
      expect(dayAtTime(at(2026, 12, 1, 8), -1, 18, 0), at(2026, 11, 30, 18));
    });
    test('crosses a year boundary', () {
      expect(dayAtTime(at(2027, 1, 1, 10), -1, 20, 0), at(2026, 12, 31, 20));
    });
    test('handles a leap day', () {
      expect(dayAtTime(at(2028, 3, 1, 9), -1, 9, 0), at(2028, 2, 29, 9));
    });
    test("ignores the anchor's own clock time", () {
      expect(
        dayAtTime(at(2026, 11, 18, 0, 30), -1, 17, 0),
        at(2026, 11, 17, 17),
      );
      expect(
        dayAtTime(at(2026, 11, 18, 23, 30), -1, 17, 0),
        at(2026, 11, 17, 17),
      );
    });
  });

  group('dayStart', () {
    test('day -1 starts at midnight the previous day', () {
      expect(dayStart(at(2026, 11, 18, 14), -1), at(2026, 11, 17));
    });
    test('day 0 starts at midnight the same day', () {
      expect(dayStart(at(2026, 11, 18, 14), 0), at(2026, 11, 18));
    });
    test('day -7 starts at midnight a week earlier', () {
      expect(dayStart(at(2026, 11, 18, 14), -7), at(2026, 11, 11));
    });
  });

  group('across daylight-saving changes (New York)', () {
    test('day -7 across spring-forward keeps 09:00 (167 elapsed hours)', () {
      final result = dayAtTime(at(2027, 3, 15, 9), -7, 9, 0);
      expect(result.millisecondsSinceEpoch, utc(2027, 3, 8, 14));
    });
    test('day -7 across fall-back keeps 09:00 (169 elapsed hours)', () {
      final result = dayAtTime(at(2026, 11, 2, 9), -7, 9, 0);
      expect(result.millisecondsSinceEpoch, utc(2026, 10, 26, 13));
    });
    test('dayStart across spring-forward is local midnight', () {
      final result = dayStart(at(2027, 3, 15, 14), -7);
      expect(result.millisecondsSinceEpoch, utc(2027, 3, 8, 5));
    });
    test(
      'a skipped time (02:30 on 2027-03-14) resolves to the earlier instant',
      () {
        final result = dayAtTime(at(2027, 3, 15, 9), -1, 2, 30);
        expect(result.millisecondsSinceEpoch, utc(2027, 3, 14, 6, 30));
      },
    );
    test(
      'a repeated time (01:30 on 2026-11-01) resolves to its first occurrence',
      () {
        final result = dayAtTime(at(2026, 11, 2, 9), -1, 1, 30);
        expect(result.millisecondsSinceEpoch, utc(2026, 11, 1, 5, 30));
      },
    );
  });

  group('limits', () {
    test('23:59 on the last day of 2037 is accepted', () {
      expect(
        dayAtTime(at(2037, 12, 31, 9), 0, 23, 59),
        at(2037, 12, 31, 23, 59),
      );
    });
    test('hour 24 is rejected', () {
      expect(
        () => dayAtTime(at(2026, 11, 18, 9), -1, 24, 0),
        throwsArgumentError,
      );
    });
    test('minute 60 is rejected', () {
      expect(
        () => dayAtTime(at(2026, 11, 18, 9), -1, 17, 60),
        throwsArgumentError,
      );
    });
    test('negative hour is rejected', () {
      expect(
        () => dayAtTime(at(2026, 11, 18, 9), -1, -1, 0),
        throwsArgumentError,
      );
    });
    test('negative minute is rejected', () {
      expect(
        () => dayAtTime(at(2026, 11, 18, 9), -1, 17, -1),
        throwsArgumentError,
      );
    });
    test('result after 2037 is rejected', () {
      expect(
        () => dayAtTime(at(2037, 12, 31, 9), 1, 8, 0),
        throwsArgumentError,
      );
    });
    test('anchor after 2037 is rejected', () {
      expect(() => dayAtTime(at(2038, 1, 1, 9), -1, 8, 0), throwsArgumentError);
    });
  });
}
