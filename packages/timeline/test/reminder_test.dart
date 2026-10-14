import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

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

  const evening = (hour: 20, minute: 0);
  // The main reminder remindersOf schedules, or null if it schedules none.
  Reminder? remind(
    TimedStep step,
    Anchors anchors, {
    QuietHours hours = quiet,
    tz.TZDateTime? at,
  }) => switch (remindersOf(
    step,
    anchors,
    quiet: hours,
    evening: evening,
    now: at ?? now,
  )) {
    Scheduled(:final main) => main,
    _ => null,
  };

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

  group('main reminder', () {
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
      final r = remindersOf(
        fixtureStep('surgery-anesthesia-msk/base.json', 'npo'),
        appointment(local(ny, 2026, 11, 18, 7, 30)),
        quiet: quiet,
        evening: evening,
        now: now,
      );
      expect(r, isA<Pending>());
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
        id: 'step',
        allowNight: true,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: true,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
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
          id: 'step',
          allowNight: false,
          pastDue: PastDue.critical,
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
          id: 'step',
          allowNight: false,
          pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
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
        id: 'step',
        allowNight: false,
        pastDue: PastDue.critical,
      );
      test('a 03:00 reminder moves to 00:29', () {
        final r = remind(
          atEffect,
          appointment(local(ny, 2026, 11, 18, 3)),
          hours: afterMidnight,
        );
        expectReminder(
          r,
          at: utc(2026, 11, 18, 5, 29),
          effect: utc(2026, 11, 18, 8),
          moves: {MoveReason.quietHours},
        );
      });
      test('a 20:00 reminder stays', () {
        final r = remind(
          atEffect,
          appointment(local(ny, 2026, 11, 18, 20)),
          hours: afterMidnight,
        );
        expectReminder(
          r,
          at: utc(2026, 11, 19, 1),
          effect: utc(2026, 11, 19, 1),
        );
      });
    });
  });

  group('lateness', () {
    test(
      '23. a reminder whose time has passed fires at now, to the second',
      () {
        final r = remind(
          (
            anchor: Anchor.appointment,
            timing: const OffsetTiming(Duration(hours: -1)),
            remind: const OffsetRemind(Duration(hours: -2)),
            id: 'step',
            allowNight: false,
            pastDue: PastDue.critical,
          ),
          appointment(local(ny, 2026, 11, 18, 12)),
          at: local(ny, 2026, 11, 18, 10, 30, 20),
        );
        expectReminder(
          r,
          at: utc(2026, 11, 18, 15, 30, 20),
          effect: utc(2026, 11, 18, 16),
        );
      },
    );

    test('24. a move to 22:59 that is already past fires at now, even in '
        'quiet hours', () {
      final r = remind(
        fixtureStep('colo-golytely-split-am-umms/base.json', 'arrive'),
        appointment(local(ny, 2026, 11, 18, 5, 30)),
        at: local(ny, 2026, 11, 18, 1),
      );
      expectReminder(
        r,
        at: utc(2026, 11, 18, 6),
        effect: utc(2026, 11, 18, 9, 30),
        moves: {MoveReason.quietHours},
      );
    });
  });

  group('remindersOf', () {
    StepReminders plan(
      TimedStep step,
      Anchors anchors, {
      QuietHours hours = quiet,
      ({int hour, int minute}) eveningAt = evening,
      tz.TZDateTime? at,
    }) => remindersOf(
      step,
      anchors,
      quiet: hours,
      evening: eveningAt,
      now: at ?? now,
    );
    Scheduled scheduled(StepReminders r) {
      expect(r, isA<Scheduled>());
      return r as Scheduled;
    }

    const nightStep = (
      anchor: Anchor.appointment,
      timing: OffsetTiming(Duration.zero),
      remind: OffsetRemind(Duration.zero),
      id: 'step',
      allowNight: true,
      pastDue: PastDue.critical,
    );
    TimedStep dose2() =>
        fixtureStep('colo-golytely-split-bmc/base.json', 'dose2');

    group('25. in effect and pending', () {
      test('effect already reached: in effect, no reminder', () {
        final dose1 = fixtureStep(
          'colo-golytely-split-am-umms/base.json',
          'dose1',
        );
        final anchors = appointment(local(ny, 2026, 11, 18, 7));
        expect(
          plan(dose1, anchors, at: local(ny, 2026, 11, 17, 18)),
          isA<InEffect>(),
        );
        // At the effect itself, the effect is no longer ahead.
        expect(
          plan(dose1, anchors, at: local(ny, 2026, 11, 17, 17)),
          isA<InEffect>(),
        );
      });
      test('anchor unknown: pending', () {
        final npo = fixtureStep('surgery-anesthesia-msk/base.json', 'npo');
        expect(
          plan(npo, appointment(local(ny, 2026, 11, 18, 7, 30))),
          isA<Pending>(),
        );
      });
    });

    test(
      '26. BMC dose2, 07:00 appointment: heads-up at 20:00 the day before',
      () {
        final s = scheduled(
          plan(dose2(), appointment(local(ny, 2026, 11, 18, 7))),
        );
        expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 8));
        expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 11, 18, 1));
      },
    );

    test(
      '27. BMC dose2, 13:00 appointment: 09:00 is not quiet, no heads-up',
      () {
        final s = scheduled(
          plan(dose2(), appointment(local(ny, 2026, 11, 18, 13))),
        );
        expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 14));
        expect(s.headsUp, isNull);
      },
    );

    test('28. a 23:30 reminder: heads-up at 20:00 the same date', () {
      final s = scheduled(
        plan(nightStep, appointment(local(ny, 2026, 11, 17, 23, 30))),
      );
      expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 4, 30));
      expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 11, 18, 1));
    });

    test('29. a 00:30 reminder: heads-up at 20:00 the date before', () {
      final s = scheduled(
        plan(nightStep, appointment(local(ny, 2026, 11, 18, 0, 30))),
      );
      expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 5, 30));
      expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 11, 18, 1));
    });

    test('30. quiet hours 00:30-06:00, a 03:00 reminder: heads-up at 20:00 '
        'the date before, not after the reminder', () {
      final s = scheduled(
        plan(
          nightStep,
          appointment(local(ny, 2026, 11, 18, 3)),
          hours: (from: (hour: 0, minute: 30), to: (hour: 6, minute: 0)),
        ),
      );
      expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 8));
      expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 11, 18, 1));
    });

    test('31. a step without allowNight is moved, never given a heads-up', () {
      final s = scheduled(
        plan(
          fixtureStep('colo-golytely-split-am-umms/base.json', 'arrive'),
          appointment(local(ny, 2026, 11, 18, 5, 30)),
        ),
      );
      expect(s.main.moves, {MoveReason.quietHours});
      expect(s.headsUp, isNull);
    });

    test('32. a heads-up whose time has passed fires at now, even in quiet '
        'hours, while the main reminder stays', () {
      final s = scheduled(
        plan(
          dose2(),
          appointment(local(ny, 2026, 11, 18, 7)),
          at: local(ny, 2026, 11, 17, 23, 15, 10),
        ),
      );
      expect(s.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 8));
      expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 11, 18, 4, 15, 10));
    });

    test(
      '40. a late main reminder gets no heads-up, nor one exactly at now',
      () {
        // Main reminder 04:30 (quiet hours, allowNight), effect 06:30.
        final anchors = appointment(local(ny, 2026, 11, 18, 8, 30));
        final late = scheduled(
          plan(dose2(), anchors, at: local(ny, 2026, 11, 18, 5, 10)),
        );
        expect(late.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 10, 10));
        expect(late.headsUp, isNull);
        final onTime = scheduled(
          plan(dose2(), anchors, at: local(ny, 2026, 11, 18, 4, 30)),
        );
        expect(onTime.main.at.millisecondsSinceEpoch, utc(2026, 11, 18, 9, 30));
        expect(onTime.headsUp, isNull);
      },
    );

    test('41. a heads-up comes strictly before the quiet start, even where a '
        'skipped midnight resolves it to the evening time', () {
      // 00:30 doesn't exist on 2026-09-06 in Santiago, so the quiet period
      // starts at 23:30 -04 on 09-05, the evening reminder time itself.
      final s = scheduled(
        plan(
          nightStep,
          appointment(local('America/Santiago', 2026, 9, 6, 3)),
          hours: (from: (hour: 0, minute: 30), to: (hour: 6, minute: 0)),
          eveningAt: (hour: 23, minute: 30),
        ),
      );
      expect(s.main.at.millisecondsSinceEpoch, utc(2026, 9, 6, 6));
      expect(s.headsUp?.millisecondsSinceEpoch, utc(2026, 9, 5, 3, 30));
    });

    group('arrivalPrompt', () {
      List<TimedStep> steps(String path, List<String> ids) => [
        for (final id in ids) fixtureStep(path, id),
      ];
      test('33. arrival still unknown: prompt at 20:00 the day before', () {
        final prompt = arrivalPrompt(
          steps('surgery-anesthesia-msk/base.json', ['stop-eating', 'npo']),
          appointment(local(ny, 2026, 11, 18, 7, 30)),
          evening: evening,
          now: now,
        );
        expect(prompt?.millisecondsSinceEpoch, utc(2026, 11, 18, 1));
      });
      test(
        '34. no prompt once arrival is entered, or with no arrival steps',
        () {
          final entered = arrivalPrompt(
            steps('surgery-anesthesia-msk/base.json', ['stop-eating', 'npo']),
            (
              appointment: local(ny, 2026, 11, 18, 7, 30),
              arrival: local(ny, 2026, 11, 18, 5, 30),
              discharge: null,
            ),
            evening: evening,
            now: now,
          );
          expect(entered, isNull);
          final noArrivalSteps = arrivalPrompt(
            steps('colo-golytely-split-bmc/base.json', ['dose2', 'npo']),
            appointment(local(ny, 2026, 11, 18, 7, 30)),
            evening: evening,
            now: now,
          );
          expect(noArrivalSteps, isNull);
        },
      );
      tz.TZDateTime? mskPrompt(tz.TZDateTime at) => arrivalPrompt(
        steps('surgery-anesthesia-msk/base.json', ['stop-eating', 'npo']),
        appointment(local(ny, 2026, 11, 18, 7, 30)),
        evening: evening,
        now: at,
      );
      test('38. past 20:00 but before the appointment: the prompt fires at '
          'now, even in quiet hours', () {
        final prompt = mskPrompt(local(ny, 2026, 11, 18, 2, 10, 5));
        expect(prompt?.millisecondsSinceEpoch, utc(2026, 11, 18, 7, 10, 5));
      });
      test('39. at or after the appointment: no prompt', () {
        expect(mskPrompt(local(ny, 2026, 11, 18, 7, 30)), isNull);
        expect(mskPrompt(local(ny, 2026, 11, 18, 8)), isNull);
      });
    });

    group('over the publish sample space', () {
      bool quietAt(tz.TZDateTime t) =>
          inRange((hour: t.hour, minute: t.minute), quiet);

      test('35. safety invariants', () {
        var headsUps = 0;
        forEverySample((f, anchors, t) {
          final step = f.step;
          final s = scheduled(plan(step, anchors));
          final main = s.main;
          final headsUp = s.headsUp;
          final why = '${f.name} at $t: $main, heads-up $headsUp';
          final morningOfItsDay = switch (step.timing) {
            DayTiming(:final day) => day != 0,
            _ => false,
          };
          final atDischarge =
              step.anchor == Anchor.discharge &&
              switch (step.remind) {
                OffsetRemind(offset: Duration.zero) => true,
                _ => false,
              };
          expect(main.at.millisecondsSinceEpoch % 60000, 0, reason: why);
          expect(
            morningOfItsDay || !main.at.isAfter(main.effect),
            isTrue,
            reason: why,
          );
          expect(
            step.allowNight || atDischarge || !quietAt(main.at),
            isTrue,
            reason: why,
          );
          expect(
            headsUp != null,
            step.allowNight && quietAt(main.at),
            reason: why,
          );
          if (headsUp != null) {
            headsUps++;
            expect(
              headsUp.isBefore(main.at) &&
                  !quietAt(headsUp) &&
                  (headsUp.hour, headsUp.minute) == (20, 0),
              isTrue,
              reason: why,
            );
          }
        });
        // Proves the heads-up checks ran.
        expect(headsUps, greaterThan(0));
      });

      test('36. a move ends at the latest allowed minute; a late reminder '
          'keeps now exactly', () {
        forEverySample((f, anchors, t) {
          final main = scheduled(plan(f.step, anchors)).main;
          final why = '${f.name} at $t: $main';
          expect(
            main.effect,
            effectOf(f.step.anchor, f.step.timing, anchors)!.at,
            reason: why,
          );
          if (main.moves.isNotEmpty) {
            final next = main.at.add(const Duration(minutes: 1));
            expect(
              main.moves.contains(MoveReason.quietHours)
                  ? quietAt(next)
                  : next.isAfter(main.effect),
              isTrue,
              reason: why,
            );
          }
          final later = main.at.add(const Duration(minutes: 1, seconds: 7));
          final again = plan(f.step, anchors, at: later);
          if (main.effect.isAfter(later)) {
            expect(
              again is Scheduled && again.main.at == later,
              isTrue,
              reason: '$why; computed at $later: $again',
            );
          } else {
            expect(again, isA<InEffect>(), reason: '$why; computed at $later');
          }
        });
      });

      test('37. publishing would fail only on UW first-day, for discharges '
          'from 23:00 to 05:00', () {
        // Changes when the UW first-day entry under "Reminders that may fail
        // the publish check" in fixtures/open-questions.md is settled.
        const firstDay = 'cardiac-cath-uw-groin-site/first-day';
        final moved = <String>{};
        forEverySample((f, anchors, t) {
          final main = scheduled(plan(f.step, anchors)).main;
          if (main.moves.isNotEmpty) moved.add(f.name);
          if (f.name == firstDay && (t.month, t.day) == (11, 18)) {
            expect(
              main.moves.isNotEmpty,
              quietAt(t),
              reason: 'discharge $t: $main',
            );
          }
        });
        expect(moved, {firstDay});
      });
    });
  });
}
