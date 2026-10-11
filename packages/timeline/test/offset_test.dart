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

  test('2 hours before a 09:00 appointment is 07:00 the same day', () {
    final appointment = tz.TZDateTime(ny, 2026, 11, 18, 9);
    expect(
      stepTime(appointment, const Duration(hours: -2)),
      tz.TZDateTime(ny, 2026, 11, 18, 7),
    );
  });

  test('3 hours before a 01:00 appointment is 22:00 the previous day', () {
    final appointment = tz.TZDateTime(ny, 2026, 11, 18, 1);
    expect(
      stepTime(appointment, const Duration(hours: -3)),
      tz.TZDateTime(ny, 2026, 11, 17, 22),
    );
  });

  test(
    '168 hours before is one week earlier when no clock change falls between',
    () {
      final appointment = tz.TZDateTime(ny, 2026, 11, 25, 9);
      expect(
        stepTime(appointment, const Duration(hours: -168)),
        tz.TZDateTime(ny, 2026, 11, 18, 9),
      );
    },
  );

  test('a positive offset moves forward (after-procedure steps)', () {
    final discharge = tz.TZDateTime(ny, 2026, 11, 18, 9);
    expect(
      stepTime(discharge, const Duration(hours: 24)),
      tz.TZDateTime(ny, 2026, 11, 19, 9),
    );
  });

  test('zero offset returns the appointment time', () {
    final appointment = tz.TZDateTime(ny, 2026, 11, 18, 9);
    expect(stepTime(appointment, Duration.zero), appointment);
  });

  test('the last hour of 2037 is accepted', () {
    final appointment = tz.TZDateTime(ny, 2037, 12, 31, 23);
    expect(
      stepTime(appointment, const Duration(hours: -1)),
      tz.TZDateTime(ny, 2037, 12, 31, 22),
    );
  });

  test('rejected when only the result is after 2037', () {
    final appointment = tz.TZDateTime(ny, 2037, 12, 31, 23);
    expect(
      () => stepTime(appointment, const Duration(hours: 2)),
      throwsArgumentError,
    );
  });

  test('rejected when only the appointment is after 2037', () {
    final appointment = tz.TZDateTime(ny, 2038, 1, 1, 0, 30);
    expect(
      () => stepTime(appointment, const Duration(hours: -1)),
      throwsArgumentError,
    );
  });
}
