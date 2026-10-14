import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

// Expected instants written in UTC, so they can't come from the code under
// test.
tz.TZDateTime utc(int y, int mo, int d, int h, [int mi = 0]) =>
    tz.TZDateTime.utc(y, mo, d, h, mi);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  const ny = 'America/New_York';
  const la = 'America/Los_Angeles';
  PastDue? pastDue(
    TimedStep step,
    tz.TZDateTime appointment,
    tz.TZDateTime createdAt,
  ) => pastDueOf(step, appointment, createdAt: createdAt);

  group('parsePastDue', () {
    test('1. reads every level', () {
      expect(parsePastDue('critical'), PastDue.critical);
      expect(parsePastDue('doNow'), PastDue.doNow);
      expect(parsePastDue('ignore'), PastDue.ignore);
    });
    for (final bad in const [null, 'none', 'Critical', '', 1]) {
      test('2. rejects $bad: there is no default', () {
        expect(() => parsePastDue(bad), throwsFormatException);
      });
    }
  });

  group('pastDueOf', () {
    // Day -5 until the appointment: takes effect 2026-11-13 00:00 EST.
    TimedStep warfarin() =>
        fixtureStep('colo-golytely-split-bmc/warfarin-hold.json', 'warfarin');
    tz.TZDateTime bmc() => local(ny, 2026, 11, 18, 9);

    test('3. BMC warfarin hold, created after it took effect: critical', () {
      expect(
        pastDue(warfarin(), bmc(), utc(2026, 11, 14, 15)),
        PastDue.critical,
      );
    });

    test('4. the same hold, created before it takes effect: null', () {
      expect(pastDue(warfarin(), bmc(), utc(2026, 11, 12, 15)), isNull);
    });

    test('5. created exactly at its effect: past due', () {
      expect(
        pastDue(warfarin(), bmc(), utc(2026, 11, 13, 5)),
        PastDue.critical,
      );
    });

    test('6. BMC iron hold (day -7), created on day -6: doNow', () {
      final iron = fixtureStep(
        'colo-golytely-split-bmc/iron-hold.json',
        'iron',
      );
      expect(pastDue(iron, bmc(), utc(2026, 11, 12, 15)), PastDue.doNow);
    });

    test('7. an ignore step past due returns ignore, not null', () {
      const step = (
        id: 'step',
        anchor: Anchor.appointment,
        timing: OffsetTiming(Duration(hours: -2)),
        remind: OffsetRemind(Duration(hours: -2)),
        allowNight: false,
        pastDue: PastDue.ignore,
      );
      expect(pastDue(step, bmc(), utc(2026, 11, 18, 13)), PastDue.ignore);
    });

    test('8. BMC P2Y12 hold, created on day -6: past due with 7 hold days, '
        'not with 5', () {
      TimedStep p2y12(int days) => fixtureStep(
        'colo-golytely-split-bmc/p2y12-hold.json',
        'p2y12',
        {'holdDays': days},
      );
      final created = utc(2026, 11, 12, 15);
      expect(pastDue(p2y12(7), bmc(), created), PastDue.critical);
      expect(pastDue(p2y12(5), bmc(), created), isNull);
    });

    test('9. a day step created at noon on its own day is past due: judged '
        'on its start, not its end', () {
      final liquids = fixtureStep(
        'colo-golytely-split-bmc/base.json',
        'clear-liquids',
      );
      expect(pastDue(liquids, bmc(), utc(2026, 11, 17, 17)), PastDue.doNow);
    });

    test('10. a window created while it is still running is past due', () {
      // 24 hours before a 09:00 appointment: from 09:00 the day before.
      final noCaffeine = fixtureStep(
        'cardiac-cath-uw/base.json',
        'no-caffeine',
      );
      expect(
        pastDue(noCaffeine, local(la, 2026, 11, 18, 9), utc(2026, 11, 18, 4)),
        PastDue.doNow,
      );
    });

    test('11. a deadline is judged at its by time', () {
      // By 06:00 for an 08:00 appointment.
      final dose2 = fixtureStep('colo-golytely-split-bmc/base.json', 'dose2');
      final appointment = local(ny, 2026, 11, 18, 8);
      expect(pastDue(dose2, appointment, utc(2026, 11, 18, 10, 59)), isNull);
      expect(
        pastDue(dose2, appointment, utc(2026, 11, 18, 11)),
        PastDue.critical,
      );
    });

    group('12. only the appointment is known at QR creation', () {
      // 2 hours before arrival; with arrival at the 07:30 appointment, 05:30.
      TimedStep npo() => fixtureStep('surgery-anesthesia-msk/base.json', 'npo');
      tz.TZDateTime msk() => local(ny, 2026, 11, 18, 7, 30);
      test('(a) MSK npo, created 06:00 the same day, arrival unknown: '
          'critical', () {
        expect(pastDue(npo(), msk(), utc(2026, 11, 18, 11)), PastDue.critical);
      });
      test('(b) the same, created the day before: null', () {
        expect(pastDue(npo(), msk(), utc(2026, 11, 17, 11)), isNull);
      });
      test('(c) a discharge-anchored step is never past due', () {
        final afterSedation = fixtureStep(
          'cardiac-cath-uw/sedation.json',
          'after-sedation',
        );
        expect(
          pastDue(
            afterSedation,
            local(la, 2026, 11, 18, 9),
            utc(2026, 11, 25, 12),
          ),
          isNull,
        );
      });
    });

    test('13. a day step on a date whose midnight is skipped starts at the '
        'clock change (01:00 in Santiago), not the evening before', () {
      const day0 = (
        id: 'day0',
        anchor: Anchor.appointment,
        timing: DayTiming(0, Lasts.oneDay),
        remind: DayAtRemind(-1, (hour: 20, minute: 0)),
        allowNight: false,
        pastDue: PastDue.doNow,
      );
      final appointment = local('America/Santiago', 2026, 9, 6, 9);
      // 23:30 -04 on 09-05: after midnight read at -03 (23:00 -04), the
      // evening before, but not yet the day's start.
      expect(pastDue(day0, appointment, utc(2026, 9, 6, 3, 30)), isNull);
      // 01:00 -03, the change itself.
      expect(pastDue(day0, appointment, utc(2026, 9, 6, 4)), PastDue.doNow);
    });

    group('over the publish sample space', () {
      test('14. past due from the effect on, 1 ms either side; arrival steps '
          'with arrival unknown; discharge steps never', () {
        const ms = Duration(milliseconds: 1);
        forEverySample((f, anchors, t) {
          // Arrival samples put arrival at the appointment, the latest it
          // can be, so this effect is the bound the spec uses.
          final effect = effectOf(f.step.anchor, f.step.timing, anchors)!.at;
          PastDue? created(Duration d) =>
              pastDueOf(f.step, anchors.appointment, createdAt: effect.add(d));
          final expected = f.step.anchor == Anchor.discharge
              ? null
              : f.step.pastDue;
          final why = '${f.name} at $t, effect $effect';
          expect(created(-ms), isNull, reason: why);
          expect(created(Duration.zero), expected, reason: why);
          expect(created(ms), expected, reason: why);
        });
      });

      test('15. created in 2020, before every sample: never past due, so the '
          'result comes from createdAt, not the clock', () {
        final created = tz.TZDateTime.utc(2020);
        forEverySample((f, anchors, t) {
          final result = pastDueOf(
            f.step,
            anchors.appointment,
            createdAt: created,
          );
          expect(result, isNull, reason: '${f.name} at $t');
        });
      });
    });
  });
}
