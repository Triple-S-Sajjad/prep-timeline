import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// A timed step from a fixture module, parsed the way the app will parse it.
({Anchor anchor, Timing timing, Remind remind, bool allowNight}) fixtureStep(
  String path,
  String id,
) {
  final module = jsonDecode(
    File('../../fixtures/protocols/$path').readAsStringSync(),
  ) as Map<String, Object?>;
  final step = (module['steps']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((s) => s['id'] == id);
  int day(Object? dayNumber) => resolveDay(dayNumber, const {}, const {});
  return (
    anchor: Anchor.values.byName(step['anchor']! as String),
    timing: parseTiming(step['timing']! as Map<String, Object?>, day),
    remind: parseRemind(step['remind']! as Map<String, Object?>, day),
    allowNight: step['allowNight']! as bool,
  );
}

// Expected instants written in UTC, so they can't come from the code under
// test.
int utc(int y, int mo, int d, int h, [int mi = 0, int s = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch;

void expectReminder(
  Reminder? r, {
  required int at,
  required int effect,
  Set<MoveReason> moves = const {},
}) {
  expect(r, isNotNull);
  expect(r!.at.millisecondsSinceEpoch, at, reason: 'at ${r.at}');
  expect(r.effect.millisecondsSinceEpoch, effect, reason: 'effect ${r.effect}');
  expect(r.moves, unorderedEquals(moves));
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  const quiet = (from: (hour: 23, minute: 0), to: (hour: 5, minute: 0));
  // Long before every appointment here, so no reminder is late (4b-2).
  final now = tz.TZDateTime.utc(2020);

  tz.TZDateTime local(
    String zone,
    int y,
    int mo,
    int d,
    int h, [
    int mi = 0,
    int s = 0,
  ]) => tz.TZDateTime(tz.getLocation(zone), y, mo, d, h, mi, s);
  Anchors appointment(tz.TZDateTime a) =>
      (appointment: a, arrival: null, discharge: null);
  Reminder? remind(
    ({Anchor anchor, Timing timing, Remind remind, bool allowNight}) step,
    Anchors anchors,
  ) => reminderOf(step, anchors, quiet: quiet, now: now);

  const ny = 'America/New_York';
  const la = 'America/Los_Angeles';

  group('parseRemind', () {
    int day(Object? d) => resolveDay(d, const {}, const {});
    test('1a. an offset reminder', () {
      final r = parseRemind({
        'kind': 'offset',
        'offset': '-PT4H',
        'defaulted': false,
      }, day);
      expect(
        r,
        isA<OffsetRemind>().having(
          (r) => r.offset,
          'offset',
          const Duration(hours: -4),
        ),
      );
    });
    test('1b. a dayAt reminder', () {
      final r = parseRemind({
        'kind': 'dayAt',
        'day': -1,
        'time': '17:00',
        'defaulted': true,
      }, day);
      expect(
        r,
        isA<DayAtRemind>().having((r) => r.day, 'day', -1).having(
          (r) => r.time,
          'time',
          (hour: 17, minute: 0),
        ),
      );
    });
    const bad = <Map<String, Object?>>[
      {'kind': 'window', 'offset': 'PT0H', 'defaulted': false},
      {'kind': 'offset', 'offset': '-PT4H'},
      {'kind': 'offset', 'offset': 'P1D', 'defaulted': false},
      {'kind': 'dayAt', 'day': -1, 'time': '24:00', 'defaulted': true},
    ];
    for (final json in bad) {
      test('1c. rejects $json', () {
        expect(() => parseRemind(json, day), throwsFormatException);
      });
    }
  });

  group('reminderOf', () {
    test('2. MSK npo counts from the entered arrival, not the appointment', () {
      final r = remind(fixtureStep('surgery-anesthesia-msk/base.json', 'npo'), (
        appointment: local(ny, 2026, 11, 18, 7, 30),
        arrival: local(ny, 2026, 11, 18, 5, 30),
        discharge: null,
      ));
      // 03:30 local is in quiet hours, but npo allows night.
      expectReminder(
        r,
        at: utc(2026, 11, 18, 8, 30),
        effect: utc(2026, 11, 18, 8, 30),
      );
    });

    test('3. UMMC dose1 is reminded at 17:00 the day before', () {
      final r = remind(
        fixtureStep('colo-golytely-split-am-umms/base.json', 'dose1'),
        appointment(local(ny, 2026, 11, 18, 7)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 17, 22),
        effect: utc(2026, 11, 17, 22),
      );
    });

    test('4. a step whose anchor is unknown has no reminder', () {
      final r = remind(fixtureStep('surgery-anesthesia-msk/base.json', 'npo'), (
        appointment: local(ny, 2026, 11, 18, 7, 30),
        arrival: null,
        discharge: null,
      ));
      expect(r, isNull);
    });

    test('5. BMC dose2: the deadline reminder stays 4 h before', () {
      final r = remind(
        fixtureStep('colo-golytely-split-bmc/base.json', 'dose2'),
        appointment(local(ny, 2026, 11, 18, 8)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 9),
        effect: utc(2026, 11, 18, 11),
      );
    });

    test('6. a deadline reminder after its by moves to the by', () {
      final r = remind((
        anchor: Anchor.appointment,
        timing: const DeadlineTiming(Duration(hours: -4)),
        remind: const OffsetRemind(Duration(hours: -2)),
        allowNight: true,
      ), appointment(local(ny, 2026, 11, 18, 12)));
      expectReminder(
        r,
        at: utc(2026, 11, 18, 13),
        effect: utc(2026, 11, 18, 13),
        moves: {MoveReason.afterEffect},
      );
    });

    test(
      '7. UW after-sedation is reminded at its stored remind, its start',
      () {
        final r = remind(
          fixtureStep('cardiac-cath-uw/sedation.json', 'after-sedation'),
          (
            appointment: local(la, 2026, 11, 18, 9),
            arrival: null,
            discharge: local(la, 2026, 11, 18, 15),
          ),
        );
        expectReminder(
          r,
          at: utc(2026, 11, 18, 23),
          effect: utc(2026, 11, 18, 23),
        );
      },
    );

    test('8. a reminder exactly at its effect is allowed (UW arrive)', () {
      final r = remind(
        fixtureStep('cardiac-cath-uw/base.json', 'arrive'),
        appointment(local(la, 2026, 11, 18, 9)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 17),
        effect: utc(2026, 11, 18, 17),
      );
    });

    test('9. BMC iron (day -7) at 07:00, after its midnight start, stays', () {
      final r = remind(
        fixtureStep('colo-golytely-split-bmc/iron-hold.json', 'iron'),
        appointment(local(ny, 2026, 11, 18, 9)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 11, 12),
        effect: utc(2026, 11, 11, 5),
      );
    });

    test('10. UMMC prep-only (day 0) is reminded at 20:00 the day before', () {
      final r = remind(
        fixtureStep('colo-golytely-split-am-umms/base.json', 'prep-only'),
        appointment(local(ny, 2026, 11, 18, 7)),
      );
      expectReminder(r, at: utc(2026, 11, 18, 1), effect: utc(2026, 11, 18, 5));
    });

    test('11. a 04:30 reminder without allowNight moves to 22:59 the evening '
        'before and still states its 04:30 effect', () {
      final r = remind(
        fixtureStep('colo-golytely-split-am-umms/base.json', 'arrive'),
        appointment(local(ny, 2026, 11, 18, 5, 30)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 3, 59),
        effect: utc(2026, 11, 18, 9, 30),
        moves: {MoveReason.quietHours},
      );
    });

    group('12. quiet-hours edges', () {
      const atEffect = (
        anchor: Anchor.appointment,
        timing: OffsetTiming(Duration.zero),
        remind: OffsetRemind(Duration.zero),
        allowNight: false,
      );
      test('a reminder at exactly 23:00 moves to 22:59', () {
        final r = remind(atEffect, appointment(local(ny, 2026, 11, 17, 23)));
        expectReminder(
          r,
          at: utc(2026, 11, 18, 3, 59),
          effect: utc(2026, 11, 18, 4),
          moves: {MoveReason.quietHours},
        );
      });
      test('a reminder at exactly 05:00 stays', () {
        final r = remind(atEffect, appointment(local(ny, 2026, 11, 18, 5)));
        expectReminder(
          r,
          at: utc(2026, 11, 18, 10),
          effect: utc(2026, 11, 18, 10),
        );
      });
    });

    test('13. BMC dose2 with allowNight stays at 03:00', () {
      final r = remind(
        fixtureStep('colo-golytely-split-bmc/base.json', 'dose2'),
        appointment(local(ny, 2026, 11, 18, 7)),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 8),
        effect: utc(2026, 11, 18, 10),
      );
    });

    test('14. a move to before the effect that lands in quiet hours goes on '
        'to 22:59', () {
      // Effect 00:00, reminder 01:00: after the effect, then in quiet hours.
      final r = remind((
        anchor: Anchor.appointment,
        timing: const DeadlineTiming(Duration(hours: -6)),
        remind: const OffsetRemind(Duration(hours: -5)),
        allowNight: false,
      ), appointment(local(ny, 2026, 11, 18, 6)));
      expectReminder(
        r,
        at: utc(2026, 11, 18, 3, 59),
        effect: utc(2026, 11, 18, 5),
        moves: {MoveReason.afterEffect, MoveReason.quietHours},
      );
    });

    test('15. a reminder at the discharge instant is exempt from quiet '
        'hours', () {
      final r = remind(
        fixtureStep('cardiac-cath-uw/sedation.json', 'after-sedation'),
        (
          appointment: local(la, 2026, 11, 17, 9),
          arrival: null,
          discharge: local(la, 2026, 11, 18, 2),
        ),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 10),
        effect: utc(2026, 11, 18, 10),
      );
    });

    test('16. a dayAt reminder at a skipped time resolves earlier', () {
      // 02:30 doesn't exist on 2027-03-14 in New York: 01:30 EST. That is in
      // quiet hours, but the step allows night, so the reminder stays there.
      final r = remind((
        anchor: Anchor.appointment,
        timing: const DayAtTiming(0, (hour: 3, minute: 30)),
        remind: const DayAtRemind(0, (hour: 2, minute: 30)),
        allowNight: true,
      ), appointment(local(ny, 2027, 3, 14, 9)));
      expectReminder(
        r,
        at: utc(2027, 3, 14, 6, 30),
        effect: utc(2027, 3, 14, 7, 30),
      );
    });

    test('17. 04:30 local is quiet on a clock-change night too', () {
      // Only 4.5 elapsed hours after 22:59, since the clock skips an hour.
      final r = remind((
        anchor: Anchor.appointment,
        timing: const OffsetTiming(Duration.zero),
        remind: const OffsetRemind(Duration.zero),
        allowNight: false,
      ), appointment(local(ny, 2027, 3, 14, 4, 30)));
      expectReminder(
        r,
        at: utc(2027, 3, 14, 3, 59),
        effect: utc(2027, 3, 14, 8, 30),
        moves: {MoveReason.quietHours},
      );
    });

    group('18. reminders are whole minutes (discharge tapped 15:00:30)', () {
      // Built inside each test: zones load in setUpAll, after declaration.
      Anchors discharged() => (
        appointment: local(la, 2026, 11, 18, 9),
        arrival: null,
        discharge: local(la, 2026, 11, 18, 15, 0, 30),
      );
      test('a PT30M reminder lands at 15:30:00, not 15:30:30', () {
        final r = remind((
          anchor: Anchor.discharge,
          timing: const OffsetTiming(Duration(hours: 2)),
          remind: const OffsetRemind(Duration(minutes: 30)),
          allowNight: false,
        ), discharged());
        expectReminder(
          r,
          at: utc(2026, 11, 18, 23, 30),
          effect: utc(2026, 11, 19, 1, 0, 30),
        );
      });
      test('a move to before the effect targets 15:00:00, the effect rounded '
          'down', () {
        final r = remind((
          anchor: Anchor.discharge,
          timing: const OffsetTiming(Duration.zero),
          remind: const OffsetRemind(Duration(hours: 1)),
          allowNight: false,
        ), discharged());
        expectReminder(
          r,
          at: utc(2026, 11, 18, 23),
          effect: utc(2026, 11, 18, 23, 0, 30),
          moves: {MoveReason.afterEffect},
        );
      });
    });

    test('19. a day-0 day step reminded at 07:00 on day 0 is not exempt: it '
        'moves to its 00:00 start, then out of quiet hours to 22:59', () {
      final r = remind((
        anchor: Anchor.appointment,
        timing: const DayTiming(0, Lasts.oneDay),
        remind: const DayAtRemind(0, (hour: 7, minute: 0)),
        allowNight: false,
      ), appointment(local(ny, 2026, 11, 19, 9)));
      expectReminder(
        r,
        at: utc(2026, 11, 19, 3, 59),
        effect: utc(2026, 11, 19, 5),
        moves: {MoveReason.afterEffect, MoveReason.quietHours},
      );
    });

    test('20. a day-2 day step reminded at 07:00 on day 2 is exempt', () {
      final r = remind((
        anchor: Anchor.appointment,
        timing: const DayTiming(2, Lasts.oneDay),
        remind: const DayAtRemind(2, (hour: 7, minute: 0)),
        allowNight: false,
      ), appointment(local(ny, 2026, 11, 18, 9)));
      expectReminder(
        r,
        at: utc(2026, 11, 20, 12),
        effect: utc(2026, 11, 20, 5),
      );
    });

    test('21. UW first-day, 24 h after a 02:00 discharge, is not at the '
        'discharge instant: it moves to 22:59', () {
      final r = remind(
        fixtureStep('cardiac-cath-uw/groin-site.json', 'first-day'),
        (
          appointment: local(la, 2026, 11, 18, 9),
          arrival: null,
          discharge: local(la, 2026, 11, 19, 2),
        ),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 20, 6, 59),
        effect: utc(2026, 11, 20, 10),
        moves: {MoveReason.quietHours},
      );
    });

    group('22. quiet hours that do not wrap midnight (00:30-06:00)', () {
      const afterMidnight = (
        from: (hour: 0, minute: 30),
        to: (hour: 6, minute: 0),
      );
      const atEffect = (
        anchor: Anchor.appointment,
        timing: OffsetTiming(Duration.zero),
        remind: OffsetRemind(Duration.zero),
        allowNight: false,
      );
      test('a 03:00 reminder moves to 00:29', () {
        final r = reminderOf(
          atEffect,
          appointment(local(ny, 2026, 11, 18, 3)),
          quiet: afterMidnight,
          now: now,
        );
        expectReminder(
          r,
          at: utc(2026, 11, 18, 5, 29),
          effect: utc(2026, 11, 18, 8),
          moves: {MoveReason.quietHours},
        );
      });
      test('a 20:00 reminder stays', () {
        final r = reminderOf(
          atEffect,
          appointment(local(ny, 2026, 11, 18, 20)),
          quiet: afterMidnight,
          now: now,
        );
        expectReminder(
          r,
          at: utc(2026, 11, 19, 1),
          effect: utc(2026, 11, 19, 1),
        );
      });
    });
  });
}
