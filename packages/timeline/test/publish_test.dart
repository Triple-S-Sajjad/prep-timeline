import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:timeline/publish.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

const santiago = 'America/Santiago';

const invalid = '../../fixtures/invalid';

DateTime date(int y, int m, int d) => DateTime.utc(y, m, d);

DateRange range(DateTime from, DateTime through) =>
    (from: from, through: through);

/// A publish date and the fixtures' review date.
final season = range(date(2026, 10, 16), date(2027, 4, 10));

/// The first date of [season]; no step of any fixture crosses a clock change
/// from it, so it is the ordinary date.
final ordinary = date(2026, 10, 16);

/// [first] and the [count] - 1 dates after it.
List<DateTime> datesFrom(DateTime first, int count) => [
  for (var i = 0; i < count; i++) date(first.year, first.month, first.day + i),
];

String hhmm(tz.TZDateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The clock times from minute [from] of the day up to minute [to], 15
/// minutes apart.
List<String> clocks(int from, int to) => [
  for (var m = from; m < to; m += 15)
    '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}',
];

bool onDate(tz.TZDateTime t, DateTime d) =>
    (t.year, t.month, t.day) == (d.year, d.month, d.day);

/// [protocol]'s files, changed as [editedFiles] changes them, checked over
/// [dates].
List<PublishFailure> check(
  String protocol, {
  void Function(Map<String, Object?> json)? manifest,
  Map<String, void Function(Map<String, Object?> json)> modules = const {},
  DateRange? dates,
}) {
  final f = editedFiles(protocol, manifest: manifest, modules: modules);
  return checkFiles(f, dates: dates);
}

List<PublishFailure> checkFiles(Files f, {DateRange? dates}) => publishCheck(
  manifest: f.manifest,
  modules: f.modules,
  dates: dates ?? season,
);

/// A failure's steps as 'module/step', the module without its protocol
/// prefix.
Set<String> stepsOf(String protocol, PublishFailure f) => {
  for (final s in f.steps)
    '${s.moduleId.substring(protocol.length + 1)}/${s.stepId}',
};

List<PublishFailure> withReason(List<PublishFailure> all, PublishReason r) => [
  for (final f in all)
    if (f.reason == r) f,
];

/// A timed npo step at [offset] from [anchor], reminded when it takes effect
/// and allowed at night, so only its cutoff is under test.
Map<String, Object?> npo(String id, String anchor, String offset) => {
  'id': id,
  'type': 'npo',
  'anchor': anchor,
  'timing': {'kind': 'offset', 'offset': offset},
  'remind': {'kind': 'offset', 'offset': offset, 'defaulted': false},
  'allowNight': true,
  'pastDue': 'critical',
  'text': id,
};

/// A module edit that sets its steps to [steps].
void Function(Map<String, Object?>) stepsTo(List<Map<String, Object?>> steps) =>
    (m) => m['steps'] = steps;

/// A module edit that adds [step] to its steps.
void Function(Map<String, Object?>) adding(Map<String, Object?> step) =>
    (m) => m['steps'] = [...(m['steps']! as List<Object?>), step];

/// A module edit that removes step [id].
void Function(Map<String, Object?>) removing(String id) =>
    (m) => m['steps'] = [
      for (final s in m['steps']! as List<Object?>)
        if ((s! as Map<String, Object?>)['id'] != id) s,
    ];

List<PublishFailure> conflicts(List<PublishFailure> all) =>
    withReason(all, PublishReason.conflictingCutoffs);

void main() {
  // Not setUpAll: some groups read zones while declaring their tests.
  tzdata.initializeTimeZones();

  group('allowed sets', () {
    /// The code [b] would carry for [ticked] at [stage], parameters at their
    /// lowest.
    Map<String, Object?> codeFor(
      Bundle b,
      SelectedAt stage,
      Set<String> ticked,
    ) => {
      'protocolId': b.manifest.protocolId,
      'version': b.manifest.version,
      'stage': stage.name,
      'modules': [...ticked],
      'parameters': {
        for (final id in ticked)
          if (b.modules[id]!.parameters.isNotEmpty)
            id: b.modules[id]!.parameters.map((k, p) => MapEntry(k, p.min)),
      },
      'createdAt': '2026-11-01T14:00:00Z',
    };

    String key(Set<String> s) => (s.toList()..sort()).join(',');

    test('1. every fixture, each stage: exactly the sets decodeQr accepts and '
        'whose modules all apply at the appointment', () async {
      for (final dir in protocolDirs()) {
        final protocol = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        final b = await signedBundle(protocol);
        final zone = b.manifest.zone.name;
        final times = protocol == karmanos
            ? [local(zone, 2026, 11, 18, 11, 45), local(zone, 2026, 11, 18, 12)]
            : [local(zone, 2026, 11, 18, 9)];
        for (final stage in SelectedAt.values) {
          final ids = [
            for (final r in b.manifest.optional)
              if (r.selectedAt == stage) r.moduleId,
          ];
          for (final t in times) {
            final expected = <String>{};
            for (var mask = 0; mask < 1 << ids.length; mask++) {
              final ticked = {
                for (var i = 0; i < ids.length; i++)
                  if (mask & (1 << i) != 0) ids[i],
              };
              try {
                decodeQr(codeFor(b, stage, ticked), b);
              } on ArgumentError {
                continue;
              }
              if (ticked.every(
                (id) => appliesAt(b.modules[id]!.appliesWhen, t),
              )) {
                expected.add(key(ticked));
              }
            }
            final got = allowedSets(b.manifest, b.modules, stage, t);
            final why = '$protocol ${stage.name} at $t';
            expect(got.map(key).toSet(), expected, reason: why);
            expect(got, hasLength(expected.length), reason: '$why: no repeats');
          }
        }
      }
    });

    test('2. Karmanos: am-schedule alone at 11:45, pm-schedule alone at '
        '12:00, 8 sets each', () async {
      final b = await signedBundle(karmanos);
      for (final (hour, minute, ticked, other) in const [
        (11, 45, 'am-schedule', 'pm-schedule'),
        (12, 0, 'pm-schedule', 'am-schedule'),
      ]) {
        final sets = allowedSets(
          b.manifest,
          b.modules,
          SelectedAt.scheduling,
          local(detroit, 2026, 11, 18, hour, minute),
        );
        expect(sets, hasLength(8));
        expect(sets.every((s) => s.contains('$karmanos-$ticked')), isTrue);
        expect(sets.any((s) => s.contains('$karmanos-$other')), isFalse);
      }
    });

    test('3. set counts at 09:00 (UW 10:00): UMMC 2, BMC 8192, CCF 8, MSK 4; '
        'UW 1 scheduling set and 8 discharge sets, each with exactly one '
        'insertion site', () async {
      for (final (protocol, count) in const [
        (umms, 2),
        (bmc, 8192),
        (ccf, 8),
        (msk, 4),
      ]) {
        final b = await signedBundle(protocol);
        final t = local(b.manifest.zone.name, 2026, 11, 18, 9);
        expect(
          allowedSets(b.manifest, b.modules, SelectedAt.scheduling, t),
          hasLength(count),
          reason: protocol,
        );
      }
      final b = await signedBundle(uw);
      final t = local(la, 2026, 11, 18, 10);
      expect(allowedSets(b.manifest, b.modules, SelectedAt.scheduling, t), [
        <String>{},
      ]);
      final discharge = allowedSets(
        b.manifest,
        b.modules,
        SelectedAt.discharge,
        t,
      );
      expect(discharge, hasLength(8));
      for (final s in discharge) {
        expect(
          [
            s.contains('$uw-groin-site'),
            s.contains('$uw-arm-site'),
          ].where((x) => x).length,
          1,
          reason: '$s',
        );
      }
    });
  });

  group('dates', () {
    final twoYears = range(date(2026, 1, 1), date(2027, 12, 31));

    test("4. New York's clock changes in 2026-2027", () {
      expect(clockChangeDates(tz.getLocation(ny), twoYears), [
        date(2026, 3, 8),
        date(2026, 11, 1),
        date(2027, 3, 14),
        date(2027, 11, 7),
      ]);
    });

    test("5. London's clock changes; Phoenix has none", () {
      expect(clockChangeDates(tz.getLocation('Europe/London'), twoYears), [
        date(2026, 3, 29),
        date(2026, 10, 25),
        date(2027, 3, 28),
        date(2027, 10, 31),
      ]);
      expect(
        clockChangeDates(tz.getLocation('America/Phoenix'), twoYears),
        isEmpty,
      );
    });

    test("6. Santiago's dates that aren't 24 hours long: the fall-back "
        'Saturdays (25 h) and the spring-forward Sundays (23 h)', () {
      expect(clockChangeDates(tz.getLocation(santiago), twoYears), [
        date(2026, 4, 4),
        date(2026, 9, 6),
        date(2027, 4, 3),
        date(2027, 9, 5),
      ]);
    });

    test('7. only changes inside the range count, both ends included', () {
      final zone = tz.getLocation(ny);
      expect(
        clockChangeDates(zone, range(date(2026, 11, 2), date(2027, 3, 13))),
        isEmpty,
      );
      expect(
        clockChangeDates(zone, range(date(2026, 11, 1), date(2026, 11, 1))),
        [date(2026, 11, 1)],
      );
    });

    Future<({List<DateTime> appointment, List<DateTime> discharge})> datesOf(
      String protocol, {
      void Function(Map<String, Object?> json)? manifest,
      Map<String, void Function(Map<String, Object?> json)> modules = const {},
      DateRange? dates,
    }) async {
      final b = await signedBundle(
        protocol,
        manifest: manifest,
        modules: modules,
      );
      return sampleDates(b.manifest, b.modules, dates ?? season);
    }

    test('8. BMC (steps up to 14 days before, Ticlid at 2 weeks): the '
        'ordinary date, then 15 appointment dates from each change', () async {
      final d = await datesOf(bmc);
      expect(d.appointment, [
        ordinary,
        ...datesFrom(date(2026, 11, 1), 15),
        ...datesFrom(date(2027, 3, 14), 15),
      ]);
      expect(d.discharge, [ordinary]);
    });

    // UW's longest discharge step is groin-site first-week, a 168-hour
    // window. Los Angeles changes at 09:00Z on 2026-11-01 and at 10:00Z on
    // 2027-03-14: a 23:45 discharge on 10-25 (06:45Z 10-26) ends its window
    // at 06:45Z 11-02, on 10-24 at 06:45Z 11-01; on 03-07 (07:45Z 03-08) at
    // 07:45Z 03-15, on 03-06 at 07:45Z 03-14.
    test('9. UW (steps up to 3 days before; first-week 168 hours after '
        'discharge): appointments from each change for 4 days, discharges '
        'from 7 days before each change through it', () async {
      final d = await datesOf(uw);
      expect(d.appointment, [
        ordinary,
        ...datesFrom(date(2026, 11, 1), 4),
        ...datesFrom(date(2027, 3, 14), 4),
      ]);
      expect(d.discharge, [
        ordinary,
        ...datesFrom(date(2026, 10, 25), 8),
        ...datesFrom(date(2027, 3, 7), 8),
      ]);
    });

    group('35. a span runs from its earliest instant to its latest', () {
      // New York changes at 06:00Z on 2026-11-01 and at 07:00Z on
      // 2027-03-14.
      test('BMC with a 12-hour window from the appointment: 10-31 and '
          '03-13 from their last bookable samples (16:45 + 12 h ends after '
          'the change), never their first (07:00)', () async {
        final d = await datesOf(
          bmc,
          modules: {
            'iron-hold': stepsTo([
              {
                ...npo('window', 'appointment', 'PT0H'),
                'type': 'restriction',
                'timing': {
                  'kind': 'window',
                  'start': 'PT0H',
                  'duration': 'PT12H',
                },
              },
            ]),
          },
        );
        expect(d.appointment, [
          ordinary,
          date(2026, 10, 31),
          ...datesFrom(date(2026, 11, 1), 15),
          date(2027, 3, 13),
          ...datesFrom(date(2027, 3, 14), 15),
        ]);
      });

      // UMMC with every step replaced by [step], in both modules.
      Future<List<DateTime>> ummsOnly(Map<String, Object?> step) async =>
          (await datesOf(
            umms,
            modules: {
              'base': stepsTo([step]),
              'iron-hold': stepsTo([step]),
            },
          )).appointment;
      final dayAfter = [
        ordinary,
        date(2026, 11, 1),
        date(2026, 11, 2),
        date(2027, 3, 14),
        date(2027, 3, 15),
      ];

      test(
        'UMMC with one step 24 h before the arrival: the day after each '
        'change, from the arrival at 00:00, not at the appointment',
        () async {
          expect(
            await ummsOnly({
              ...npo('call', 'arrival', '-PT24H'),
              'type': 'checklist',
            }),
            dayAfter,
          );
        },
      );

      test('UMMC with one step 1 h before the appointment, reminded 31 h '
          'before: the day after each change, from the reminder', () async {
        expect(
          await ummsOnly({
            ...npo('call', 'appointment', '-PT1H'),
            'type': 'checklist',
            'remind': {
              'kind': 'offset',
              'offset': '-PT31H',
              'defaulted': false,
            },
          }),
          dayAfter,
        );
      });

      test("Santiago's spring-forward date 2026-09-06, whose steps cross "
          'nothing, is sampled as a clock-change date; 09-07 is the ordinary '
          'date', () async {
        final step = {
          ...npo('call', 'appointment', '-PT1H'),
          'type': 'checklist',
        };
        final d = await datesOf(
          umms,
          manifest: (m) => m['timezone'] = santiago,
          modules: {
            'base': stepsTo([step]),
            'iron-hold': stepsTo([step]),
          },
          dates: range(date(2026, 9, 6), date(2026, 9, 8)),
        );
        expect(d.appointment, [date(2026, 9, 6), date(2026, 9, 7)]);
        expect(d.discharge, [date(2026, 9, 7)]);
      });
    });
  });

  group('sample instants', () {
    final zone = tz.getLocation(ny);
    final plain = date(2026, 11, 18);
    final spring = date(2026, 3, 8);
    final fall = date(2026, 11, 1);

    /// [samples] are 15 minutes of elapsed time apart.
    void expectEvenlySpaced(List<tz.TZDateTime> samples, String why) {
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i].difference(samples[i - 1]),
          const Duration(minutes: 15),
          reason: '$why, sample $i',
        );
      }
    }

    group('10. bookable hours: the instants on the date whose clock time is '
        'in the range', () {
      final london = date(2027, 3, 28);
      for (final (label, zone, from, to, cases) in [
        (
          'UMMC 07:00 to 12:00',
          ny,
          (hour: 7, minute: 0),
          (hour: 12, minute: 0),
          [
            (plain, clocks(7 * 60, 12 * 60)),
            (spring, clocks(7 * 60, 12 * 60)),
            (fall, clocks(7 * 60, 12 * 60)),
          ],
        ),
        (
          '00:00 to 04:00, across the change',
          ny,
          (hour: 0, minute: 0),
          (hour: 4, minute: 0),
          [
            (plain, clocks(0, 4 * 60)),
            (spring, [...clocks(0, 2 * 60), ...clocks(3 * 60, 4 * 60)]),
            (fall, [...clocks(0, 2 * 60), ...clocks(60, 4 * 60)]),
          ],
        ),
        (
          '22:00 to 02:00, wrapping midnight: the start and end of the date',
          ny,
          (hour: 22, minute: 0),
          (hour: 2, minute: 0),
          [
            (plain, [...clocks(0, 2 * 60), ...clocks(22 * 60, 24 * 60)]),
          ],
        ),
        (
          '22:00 to 02:00 in London on its spring-forward date',
          'Europe/London',
          (hour: 22, minute: 0),
          (hour: 2, minute: 0),
          [
            (london, [...clocks(0, 60), ...clocks(22 * 60, 24 * 60)]),
          ],
        ),
      ]) {
        for (final (d, expected) in cases) {
          final day = d.toIso8601String().substring(0, 10);
          test('$label, $zone $day: ${expected.length}', () {
            final s = bookableSamples(tz.getLocation(zone), d, (
              from: from,
              to: to,
            ));
            expect(s.map(hhmm).toList(), expected);
            for (final t in s) {
              expect(onDate(t, d), isTrue, reason: '$t');
            }
            // Every gap is 15 minutes, except the one a wrapping range skips
            // to its start.
            for (var i = 1; i < s.length; i++) {
              final gap = s[i].difference(s[i - 1]);
              final toStart =
                  (s[i].hour, s[i].minute) == (from.hour, from.minute);
              expect(
                gap == const Duration(minutes: 15) ||
                    (toStart && from.hour > to.hour),
                isTrue,
                reason: '$label, sample $i: $gap',
              );
            }
          });
        }
      }
    });

    group('11. arrivals for a 09:00 appointment run from 00:00 to 09:00', () {
      for (final (d, count) in [(plain, 37), (spring, 33), (fall, 41)]) {
        test('${d.toIso8601String().substring(0, 10)}: $count', () {
          final appointment = local(ny, d.year, d.month, d.day, 9);
          final s = arrivalSamples(appointment);
          expect(s, hasLength(count));
          expect(s.first, local(ny, d.year, d.month, d.day, 0));
          expect(s.last, appointment);
          for (final t in s) {
            expect(onDate(t, d), isTrue, reason: '$t');
          }
          expectEvenlySpaced(s, '$d');
        });
      }
    });

    group('12. discharges run across the whole local day', () {
      for (final (d, count) in [(plain, 96), (spring, 92), (fall, 100)]) {
        test('${d.toIso8601String().substring(0, 10)}: $count', () {
          final s = daySamples(zone, d);
          expect(s, hasLength(count));
          expect(s.first, local(ny, d.year, d.month, d.day, 0));
          expect(
            s.last.add(const Duration(minutes: 15)),
            local(ny, d.year, d.month, d.day + 1, 0),
          );
          expectEvenlySpaced(s, '$d');
        });
      }
    });
  });

  group('reminders, judged before any move', () {
    test('13. UW groin-site first-day: quietHours exactly for discharges '
        'from 23:00 to 04:45; not at 05:00 or 22:45', () {
      final first = [
        for (final f in withReason(check(uw), PublishReason.quietHours))
          if (stepsOf(uw, f).single == 'groin-site/first-day') f,
      ];
      final clocks = {
        for (final f in first)
          if (onDate(f.sample.discharge!, ordinary)) hhmm(f.sample.discharge!),
      };
      expect(clocks, {
        for (var m = 0; m < 5 * 60; m += 15)
          hhmm(local(la, 2026, 1, 1, m ~/ 60, m % 60)),
        '23:00',
        '23:15',
        '23:30',
        '23:45',
      });
      // On other dates a clock change between discharge and reminder shifts
      // which discharges fail, so judge the reminder's own clock time.
      for (final f in first) {
        final h = f.sample.discharge!.add(const Duration(hours: 24)).hour;
        expect(h >= 23 || h < 5, isTrue, reason: '${f.sample}');
      }
    });

    test('14. a remind 1 hour after its effect: afterEffect at every '
        'appointment sample', () {
      final all = check(
        bmc,
        modules: {
          'iron-hold': stepsTo([
            {
              ...npo('late', 'appointment', '-PT6H'),
              'type': 'checklist',
              'remind': {
                'kind': 'offset',
                'offset': '-PT5H',
                'defaulted': false,
              },
            },
          ]),
        },
      );
      final late = withReason(all, PublishReason.afterEffect);
      expect({for (final f in late) ...stepsOf(bmc, f)}, {'iron-hold/late'});
      expect({
        for (final f in late)
          if (onDate(f.sample.appointment, ordinary))
            hhmm(f.sample.appointment),
      }, hasLength(40));
    });

    group('15. 1-minute moves fail; the stored time is judged, never rounded '
        'or moved first', () {
      Map<String, Object?> dayAtStep(
        String effect,
        String remind,
        bool night,
      ) => {
        'id': 'evening',
        'type': 'checklist',
        'anchor': 'appointment',
        'timing': {'kind': 'dayAt', 'day': -1, 'time': effect},
        'remind': {
          'kind': 'dayAt',
          'day': -1,
          'time': remind,
          'defaulted': false,
        },
        'allowNight': night,
        'pastDue': 'doNow',
        'text': 'evening',
      };
      Map<String, Object?> offsetStep(String effect, String remind) => {
        ...npo('cutoff', 'appointment', effect),
        'type': 'checklist',
        'remind': {'kind': 'offset', 'offset': remind, 'defaulted': false},
      };

      for (final (label, step, reason) in [
        (
          'reminded 23:00, the quiet start, for 23:30 (the phone moves it to '
              '22:59): quietHours',
          dayAtStep('23:30', '23:00', false),
          PublishReason.quietHours,
        ),
        (
          'reminded 22:59 for 23:30: passes',
          dayAtStep('23:30', '22:59', false),
          null,
        ),
        (
          '3 hours before, reminded 2 h 59 min before (the phone moves it 1 '
              'minute earlier): afterEffect',
          offsetStep('-PT3H', '-PT2H59M'),
          PublishReason.afterEffect,
        ),
        (
          '3 hours before, reminded at the effect itself: passes',
          offsetStep('-PT3H', '-PT3H'),
          null,
        ),
      ]) {
        test(label, () {
          final all = check(
            bmc,
            modules: {
              'iron-hold': stepsTo([step]),
            },
          );
          final named = [
            for (final f in all)
              if (stepsOf(bmc, f).any((s) => s.startsWith('iron-hold/'))) f,
          ];
          if (reason == null) {
            expect(named, isEmpty);
          } else {
            expect(named.map((f) => f.reason).toSet(), {reason});
            expect({
              for (final f in named)
                if (onDate(f.sample.appointment, ordinary))
                  f.sample.appointment,
            }, hasLength(40));
          }
        });
      }
    });

    test('16. BMC clear-liquids, a day -1 step reminded 07:00 on its own day: '
        'not after its effect', () {
      expect(
        check(bmc).where((f) => stepsOf(bmc, f).contains('base/clear-liquids')),
        isEmpty,
      );
    });

    test('17. UW steps reminded at the discharge instant (PT0H) pass at every '
        'discharge, quiet hours included', () {
      const atDischarge = {
        'base/no-nsaids',
        'groin-site/first-week',
        'sedation/after-sedation',
        'arm-site/first-48h',
        'arm-site/first-5-days',
      };
      expect(
        check(uw).where((f) => stepsOf(uw, f).any(atDischarge.contains)),
        isEmpty,
      );
    });

    test('18. an allowNight step reminded at 03:00 passes', () {
      final all = check(
        bmc,
        modules: {
          'iron-hold': stepsTo([
            {
              'id': 'night-dose',
              'type': 'prep_dose',
              'anchor': 'appointment',
              'timing': {'kind': 'dayAt', 'day': 0, 'time': '03:30'},
              'remind': {
                'kind': 'dayAt',
                'day': 0,
                'time': '03:00',
                'defaulted': false,
              },
              'allowNight': true,
              'pastDue': 'critical',
              'text': 'night dose',
            },
          ]),
        },
      );
      expect(
        all.where((f) => stepsOf(bmc, f).contains('iron-hold/night-dose')),
        isEmpty,
      );
    });

    test('19. every parameter value is checked: P2Y12 reminded at 23:00 '
        'fails for holdDays 5, 6 and 7', () {
      final all = check(
        bmc,
        modules: {
          'p2y12-hold': (m) {
            final step = (m['steps']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .singleWhere((s) => s['id'] == 'p2y12');
            (step['remind']! as Map<String, Object?>)['time'] = '23:00';
          },
        },
      );
      final p2y12 = [
        for (final f in withReason(all, PublishReason.quietHours))
          if (stepsOf(bmc, f).contains('p2y12-hold/p2y12')) f,
      ];
      expect(
        {for (final f in p2y12) f.steps.single.chosen['holdDays']},
        {5, 6, 7},
      );
    });

    /// A checklist step at [anchor], taking effect per [timing] and reminded
    /// per [remind], without allowNight.
    Map<String, Object?> checklist(
      String id,
      String anchor,
      Map<String, Object?> timing,
      Map<String, Object?> remind,
    ) => {
      'id': id,
      'type': 'checklist',
      'anchor': anchor,
      'timing': timing,
      'remind': {...remind, 'defaulted': false},
      'allowNight': false,
      'pastDue': 'doNow',
      'text': id,
    };

    test('36. Karmanos with am/pm split at 11:30 and a pm-schedule step '
        'reminded at 23:30 the day before: quietHours exactly at the 11:30 to '
        '16:45 samples, where a code can tick pm-schedule', () {
      void applies(Map<String, Object?> m, String from, String to) =>
          m['appliesWhen'] = {
            'appointmentTime': {'fromInclusive': from, 'toExclusive': to},
          };
      final all = check(
        karmanos,
        modules: {
          'am-schedule': (m) => applies(m, '00:00', '11:30'),
          'pm-schedule': (m) {
            applies(m, '11:30', '24:00');
            adding(
              checklist(
                'late-call',
                'appointment',
                {'kind': 'dayAt', 'day': -1, 'time': '23:45'},
                {'kind': 'dayAt', 'day': -1, 'time': '23:30'},
              ),
            )(m);
          },
        },
      );
      final quiet = withReason(all, PublishReason.quietHours);
      expect(
        {for (final f in quiet) ...stepsOf(karmanos, f)},
        {'pm-schedule/late-call'},
      );
      expect({
        for (final f in quiet)
          if (onDate(f.sample.appointment, ordinary))
            hhmm(f.sample.appointment),
      }, clocks(11 * 60 + 30, 17 * 60).toSet());
    });

    test('37. a step 2 h before the arrival, without allowNight: quietHours '
        'for a 09:00 appointment exactly at the arrivals 01:00 to 06:45', () {
      final all = check(
        umms,
        modules: {
          'iron-hold': stepsTo([
            checklist(
              'call',
              'arrival',
              {'kind': 'offset', 'offset': '-PT2H'},
              {'kind': 'offset', 'offset': '-PT2H'},
            ),
          ]),
        },
      );
      final quiet = withReason(all, PublishReason.quietHours);
      expect({for (final f in quiet) ...stepsOf(umms, f)}, {'iron-hold/call'});
      final at9 = local(ny, 2026, 10, 16, 9);
      expect({
        for (final f in quiet)
          if (f.sample.appointment == at9) hhmm(f.sample.arrival!),
      }, clocks(60, 7 * 60).toSet());
    });

    test('38. a day 0 step reminded at 07:00 on day 0: afterEffect at every '
        'appointment sample, since day 0 starts at midnight', () {
      final all = check(
        umms,
        modules: {
          'iron-hold': stepsTo([
            checklist(
              'day0',
              'appointment',
              {'kind': 'day', 'day': 0, 'lasts': 'untilAnchor'},
              {'kind': 'dayAt', 'day': 0, 'time': '07:00'},
            ),
          ]),
        },
      );
      final late = withReason(all, PublishReason.afterEffect);
      expect({for (final f in late) ...stepsOf(umms, f)}, {'iron-hold/day0'});
      expect({
        for (final f in late)
          if (onDate(f.sample.appointment, ordinary))
            hhmm(f.sample.appointment),
      }, clocks(7 * 60, 12 * 60).toSet());
    });

    test('39. UW bookable to 23:30: base arrive, reminded at the appointment '
        'itself (PT0H), fails quietHours at 23:00 and 23:15; only the '
        'discharge instant is exempt', () {
      final all = check(
        uw,
        manifest: (m) => m['bookableHours'] = {'from': '07:00', 'to': '23:30'},
      );
      expect(
        {
          for (final f in withReason(all, PublishReason.quietHours))
            if (stepsOf(uw, f).contains('base/arrive') &&
                onDate(f.sample.appointment, ordinary))
              hhmm(f.sample.appointment),
        },
        {'23:00', '23:15'},
      );
    });

    test('47. a day step is exempt only while its stored reminder is on its '
        'own date: day -3, day -2 at the next day start and untilAnchor day '
        '-1 reminded on day 0 fail afterEffect at every sample; day -1 at '
        '07:00 and day -2 at 23:59 on day -2 pass', () {
      Map<String, Object?> dayStep(
        String id,
        int day,
        String lasts,
        int remindDay,
        String time,
      ) => {
        ...checklist(
          id,
          'appointment',
          {'kind': 'day', 'day': day, 'lasts': lasts},
          {'kind': 'dayAt', 'day': remindDay, 'time': time},
        ),
        'allowNight': true,
      };
      final all = check(
        umms,
        modules: {
          'iron-hold': stepsTo([
            dayStep('day-3', -3, 'oneDay', -1, '07:00'),
            dayStep('day-1', -1, 'oneDay', -1, '07:00'),
            dayStep('day-2-last-minute', -2, 'oneDay', -2, '23:59'),
            dayStep('day-2-next-start', -2, 'oneDay', -1, '00:00'),
            dayStep('until-anchor-day-0', -1, 'untilAnchor', 0, '05:00'),
          ]),
        },
      );
      final late = withReason(all, PublishReason.afterEffect);
      expect(
        {for (final f in all) ...stepsOf(umms, f)},
        {
          'iron-hold/day-3',
          'iron-hold/day-2-next-start',
          'iron-hold/until-anchor-day-0',
        },
      );
      // UMMC has no npo step, so noStopDrinking, naming no step, fails too.
      expect(
        {
          for (final f in all)
            if (f.steps.isNotEmpty) f.reason,
        },
        {PublishReason.afterEffect},
      );
      for (final id in ['day-3', 'day-2-next-start', 'until-anchor-day-0']) {
        expect(
          {
            for (final f in late)
              if (stepsOf(umms, f).single == 'iron-hold/$id' &&
                  onDate(f.sample.appointment, ordinary))
                hhmm(f.sample.appointment),
          },
          clocks(7 * 60, 12 * 60).toSet(),
          reason: id,
        );
      }
    });
  });

  group('conflicting cutoffs', () {
    test('20. invalid/conflicting-cutoffs-karmanos: base npo (4 h before) and '
        'regular-pills last-sips (3 h before), at every bookable sample', () {
      const p = 'conflicting-cutoffs-karmanos';
      final all = conflicts(checkFiles(filesIn('$invalid/$p')));
      expect(
        {for (final f in all) stepsOf(p, f).join(' & ')},
        {'base/npo & regular-pills/last-sips'},
      );
      final zone = tz.getLocation(detroit);
      for (final d in [ordinary, ...clockChangeDates(zone, season)]) {
        expect(
          {
            for (final f in all)
              if (onDate(f.sample.appointment, d)) f.sample.appointment,
          },
          bookableSamples(zone, d, (
            from: (hour: 7, minute: 0),
            to: (hour: 17, minute: 0),
          )).toSet(),
          reason: '$d',
        );
      }
    });

    test('21. two optional modules with npo at the base time: no conflict', () {
      final same = npo('sips', 'appointment', '-PT2H');
      expect(
        conflicts(
          check(
            bmc,
            modules: {
              'iron-hold': stepsTo([same]),
              'warfarin-hold': stepsTo([same]),
            },
          ),
        ),
        isEmpty,
      );
    });

    test('22. Karmanos am-schedule npo 4 h before, pm-schedule 3 h before, no '
        'base npo: never selected together, so no conflict', () {
      final all = check(
        karmanos,
        modules: {
          'base': removing('npo'),
          'am-schedule': adding(npo('am-npo', 'appointment', '-PT4H')),
          'pm-schedule': adding(npo('pm-npo', 'appointment', '-PT3H')),
        },
      );
      expect(conflicts(all), isEmpty);
      expect(withReason(all, PublishReason.noStopDrinking), isEmpty);
    });

    test('23. npo 1 h before arrival against base npo 2 h before the '
        'appointment: a conflict at every arrival but 08:00 for 09:00', () {
      final all = conflicts(
        check(
          bmc,
          modules: {
            'iron-hold': stepsTo([npo('late-sips', 'arrival', '-PT1H')]),
          },
        ),
      );
      expect(
        {for (final f in all) stepsOf(bmc, f).join(' & ')},
        {'base/npo & iron-hold/late-sips'},
      );
      final at9 = local(ny, 2026, 10, 16, 9);
      final arrivals = {
        for (final f in all)
          if (f.sample.appointment == at9) hhmm(f.sample.arrival!),
      };
      expect(arrivals, {
        for (final a in arrivalSamples(at9))
          if (hhmm(a) != '08:00') hhmm(a),
      });
    });

    // On 2026-09-06 Santiago skips 00:00 to 01:00 (-04:00 to -03:00). By the
    // spec's skipped-time rule dayAt 0 00:00 is the earlier instant, 03:00Z
    // (23:00 on 09-05 at -04:00); day 0 starts when the day actually begins,
    // 04:00Z (01:00 at -03:00). They differ by an hour; on every other date
    // both are local midnight.
    test('24. Santiago: npo from the start of day 0 against npo at dayAt 0 '
        '00:00 differ only on the day midnight is skipped (2026-09-06)', () {
      final nine = local(santiago, 2026, 9, 6, 9);
      expect(
        dayAtTime(nine, 0, 0, 0).millisecondsSinceEpoch,
        DateTime.utc(2026, 9, 6, 3).millisecondsSinceEpoch,
      );
      expect(
        dayStart(nine, 0).millisecondsSinceEpoch,
        DateTime.utc(2026, 9, 6, 4).millisecondsSinceEpoch,
      );
      Map<String, Object?> dayZero(String id, Map<String, Object?> timing) => {
        ...npo(id, 'appointment', '-PT1H'),
        'timing': timing,
        'remind': {
          'kind': 'dayAt',
          'day': -1,
          'time': '20:00',
          'defaulted': false,
        },
      };
      final all = conflicts(
        check(
          bmc,
          manifest: (m) => m['timezone'] = santiago,
          modules: {
            'base': (m) {
              removing('npo')(m);
              adding(
                dayZero('npo', {
                  'kind': 'day',
                  'day': 0,
                  'lasts': 'untilAnchor',
                }),
              )(m);
            },
            'iron-hold': stepsTo([
              dayZero('midnight', {'kind': 'dayAt', 'day': 0, 'time': '00:00'}),
            ]),
          },
          dates: range(date(2026, 8, 1), date(2026, 10, 1)),
        ),
      );
      expect(all, isNotEmpty);
      expect(
        {for (final f in all) stepsOf(bmc, f).join(' & ')},
        {'base/npo & iron-hold/midnight'},
      );
      expect(
        {
          for (final f in all)
            (f.sample.appointment.month, f.sample.appointment.day),
        },
        {(9, 6)},
      );
    });

    test(
      '25. one module with two npo steps at different times: a conflict',
      () {
        final all = conflicts(
          check(
            bmc,
            modules: {'base': adding(npo('npo-early', 'appointment', '-PT3H'))},
          ),
        );
        expect(
          {for (final f in all) stepsOf(bmc, f).join(' & ')},
          {'base/npo & base/npo-early'},
        );
      },
    );

    Set<String> pairs(String protocol, List<PublishFailure> all) => {
      for (final f in conflicts(all)) stepsOf(protocol, f).join(' & '),
    };

    test('40. UW with stent ticked at scheduling: a scheduling and a '
        'discharge module are selected together, so their npo steps are '
        'compared', () {
      final all = check(
        uw,
        manifest: (m) {
          for (final r
              in (m['optionalModules']! as List<Object?>)
                  .cast<Map<String, Object?>>()) {
            if (r['moduleId'] == '$uw-stent') r['selectedAt'] = 'scheduling';
          }
        },
        modules: {
          'stent': adding(npo('npo', 'appointment', '-PT6H')),
          'sedation': adding(npo('late', 'appointment', '-PT3H')),
        },
      );
      expect(pairs(uw, all), {
        'base/npo & sedation/late',
        'sedation/late & stent/npo',
      });
    });

    test('41. UW groin-site and arm-site, one exactlyOneOf group, with npo at '
        'different times: never compared with each other, each compared '
        'with sedation', () {
      final all = check(
        uw,
        modules: {
          'base': removing('npo'),
          'groin-site': adding(npo('npo', 'appointment', '-PT6H')),
          'arm-site': adding(npo('npo', 'appointment', '-PT5H')),
          'sedation': adding(npo('npo', 'appointment', '-PT4H')),
        },
      );
      expect(pairs(uw, all), {
        'sedation/npo & groin-site/npo',
        'sedation/npo & arm-site/npo',
      });
    });

    test("42. an npo step whose day is a parameter: one module's own choices "
        'are never compared, each is compared with the base npo', () {
      final all = check(
        umms,
        modules: {
          'base': adding(npo('npo', 'appointment', '-PT2H')),
          'iron-hold': (m) {
            m['parameters'] = {
              'holdDays': {'min': 1, 'max': 2, 'unit': 'days'},
            };
            const day = {'param': 'holdDays', 'before': true};
            stepsTo([
              {
                ...npo('iron', 'appointment', '-PT2H'),
                'timing': {'kind': 'day', 'day': day, 'lasts': 'untilAnchor'},
                'remind': {
                  'kind': 'dayAt',
                  'day': day,
                  'time': '07:00',
                  'defaulted': false,
                },
              },
            ])(m);
          },
        },
      );
      expect(pairs(umms, all), {'base/npo & iron-hold/iron'});
      expect(
        {for (final f in conflicts(all)) f.steps.last.chosen['holdDays']},
        {1, 2},
      );
    });

    test('43. discharge-anchored npo steps selected together are compared at '
        'each discharge sample: sedation (1 h) against arm-site (2 h) fails, '
        'against groin-site (1 h) passes, and the two sites are never '
        'selected together', () {
      final all = check(
        uw,
        modules: {
          'sedation': adding(npo('sips', 'discharge', 'PT1H')),
          'groin-site': adding(npo('sips', 'discharge', 'PT1H')),
          'arm-site': adding(npo('sips', 'discharge', 'PT2H')),
        },
      );
      expect(pairs(uw, all), {'sedation/sips & arm-site/sips'});
      for (final f in conflicts(all)) {
        expect(f.sample.discharge, isNotNull);
        expect(f.sample.arrival, isNull);
      }
      expect({
        for (final f in conflicts(all))
          if (onDate(f.sample.discharge!, ordinary)) f.sample.discharge,
      }, hasLength(96));
      expect(withReason(all, PublishReason.noStopDrinking), isEmpty);
    });
  });

  group('noStopDrinking, one failure per sample', () {
    /// [protocol]'s noStopDrinking failures: one per appointment sample, each
    /// naming [npoFree] (without the protocol prefix) and [sets] failing
    /// sets, with no steps and the arrival at the appointment; [perDay] of
    /// them on the ordinary date.
    void expectGrouped(
      String protocol,
      List<PublishFailure> all,
      String npoFree,
      int sets,
      int perDay,
    ) {
      final grouped = withReason(all, PublishReason.noStopDrinking);
      expect(
        {
          for (final f in grouped)
            [for (final m in f.selection) m.substring(protocol.length + 1)]
                .join(','),
        },
        {npoFree},
      );
      expect({for (final f in grouped) f.failingSets}, {sets});
      expect(
        {for (final f in grouped) f.sample.appointment},
        hasLength(grouped.length),
        reason: 'one failure per sample',
      );
      expect([
        for (final f in grouped)
          if (onDate(f.sample.appointment, ordinary)) f,
      ], hasLength(perDay));
      for (final f in grouped) {
        expect(f.steps, isEmpty);
        expect(f.sample.arrival, f.sample.appointment);
        expect(f.sample.discharge, isNull);
      }
    }

    test('26. UMMC has no npo step: base and iron-hold are npo-free, both '
        'sets fail, one failure at each of the 20 bookable samples', () {
      expectGrouped(umms, check(umms), 'base,iron-hold', 2, 20);
    });

    test('27. MSK with npo only in nsaid-hold: base and supplements-hold are '
        'npo-free, 2 sets fail at each of the 40 samples', () {
      final all = check(
        msk,
        modules: {
          'base': removing('npo'),
          'nsaid-hold': adding(npo('npo', 'arrival', '-PT2H')),
        },
      );
      expectGrouped(msk, all, 'base,supplements-hold', 2, 40);
    });

    test('28. UW with its base npo removed and npo added to sedation, a '
        'discharge module: the base alone is npo-free, 1 set fails at each '
        'of the 40 samples, never a discharge set', () {
      final all = check(
        uw,
        modules: {
          'base': removing('npo'),
          'sedation': adding(npo('sips', 'discharge', 'PT1H')),
        },
      );
      expectGrouped(uw, all, 'base', 1, 40);
    });

    test('29. UW as it is: its discharge modules have no npo step and never '
        'fail', () {
      expect(withReason(check(uw), PublishReason.noStopDrinking), isEmpty);
    });

    test('44. UMMC with a discharge-anchored npo step in its base: it never '
        'stops drinking, so both sets still fail', () {
      final all = check(
        umms,
        modules: {'base': adding(npo('sips', 'discharge', 'PT1H'))},
      );
      expectGrouped(umms, all, 'base,iron-hold', 2, 20);
    });

    test('45a. invalid/param-min-zero-bmc, a range starting at 0, is a '
        'FormatException, never judged', () {
      expect(
        () => checkFiles(filesIn('$invalid/param-min-zero-bmc')),
        throwsFormatException,
      );
    });

    test('45c. invalid/param-range-bmc, a range whose min is above its max, '
        'is a FormatException, never passed with its steps unjudged', () {
      expect(
        () => checkFiles(filesIn('$invalid/param-range-bmc')),
        throwsFormatException,
      );
    });

    test('45b. npo at 18:00 on day -holdDays, holdDays 1 or 2: every choice '
        'stops drinking, so only the base is npo-free and 1 set fails', () {
      // With a range starting at 1, every choice lands on the same side of
      // the appointment, so "every choice" and "any choice" can't differ:
      // see MUTATION.md.
      const day = {'param': 'holdDays', 'before': true};
      final all = check(
        umms,
        modules: {
          'iron-hold': (m) {
            m['parameters'] = {
              'holdDays': {'min': 1, 'max': 2, 'unit': 'days'},
            };
            stepsTo([
              {
                ...npo('iron', 'appointment', '-PT2H'),
                'timing': {'kind': 'dayAt', 'day': day, 'time': '18:00'},
                'remind': {
                  'kind': 'dayAt',
                  'day': day,
                  'time': '18:00',
                  'defaulted': false,
                },
              },
            ])(m);
          },
        },
      );
      expectGrouped(umms, all, 'base', 1, 20);
    });

    test('46. Karmanos without its base npo: only modules that apply are '
        'named, am-schedule before 12:00 and pm-schedule from 12:00', () {
      final all = withReason(
        check(karmanos, modules: {'base': removing('npo')}),
        PublishReason.noStopDrinking,
      );
      expect(all, isNotEmpty);
      for (final f in all) {
        final schedule = f.sample.appointment.hour < 12 ? 'am' : 'pm';
        expect(
          [for (final m in f.selection) m.substring(karmanos.length + 1)],
          [
            'base',
            '$schedule-schedule',
            'iron-hold',
            'nsaid-hold',
            'aspirin-limit',
          ],
          reason: '${f.sample.appointment}',
        );
        expect(f.failingSets, 8);
      }
    });
  });

  test('30. invalid/bookable-outside-base-umms: appointment samples from '
      '12:00 to 16:45 are outside the base appliesWhen', () {
    const p = 'bookable-outside-base-umms';
    final every = checkFiles(filesIn('$invalid/$p'));
    final all = withReason(every, PublishReason.outsideBaseAppliesWhen);
    for (final f in all) {
      expect(f.selection, ['$p-base']);
      expect(f.steps, isEmpty);
      expect(f.failingSets, isNull);
    }
    // The app refuses those times, so nothing else is judged there.
    final outside = [for (final f in all) f.sample.appointment];
    expect(outside.toSet(), hasLength(outside.length));
    expect(
      every.where(
        (f) =>
            f.reason != PublishReason.outsideBaseAppliesWhen &&
            outside.contains(f.sample.appointment),
      ),
      isEmpty,
    );
    expect(
      {
        for (final f in all)
          if (onDate(f.sample.appointment, ordinary))
            hhmm(f.sample.appointment),
      },
      {
        for (var m = 12 * 60; m < 17 * 60; m += 15)
          hhmm(local(ny, 2026, 1, 1, m ~/ 60, m % 60)),
      },
    );
  });

  group('48. noAllowedSet names the stage with no allowed set at a sample', () {
    void applies(Map<String, Object?> m, String to) => m['appliesWhen'] = {
      'appointmentTime': {'fromInclusive': '00:00', 'toExclusive': to},
    };
    for (final (name, protocol, modules, stage, from, to) in [
      (
        'Karmanos with am-schedule ending at 11:00: no am/pm module applies '
            'from 11:00 to 11:45',
        karmanos,
        {'am-schedule': (Map<String, Object?> m) => applies(m, '11:00')},
        SelectedAt.scheduling,
        11 * 60,
        12 * 60,
      ),
      (
        'UW with groin-site and arm-site ending at 16:00: no site module '
            'applies from 16:00 to 16:45',
        uw,
        {
          'groin-site': (Map<String, Object?> m) => applies(m, '16:00'),
          'arm-site': (Map<String, Object?> m) => applies(m, '16:00'),
        },
        SelectedAt.discharge,
        16 * 60,
        17 * 60,
      ),
    ]) {
      test(name, () {
        final all = check(protocol, modules: modules);
        final none = withReason(all, PublishReason.noAllowedSet);
        for (final f in none) {
          expect(f.stage, stage);
          expect(f.steps, isEmpty);
          expect(f.selection, isEmpty);
          expect(f.failingSets, isNull);
          expect(f.sample.arrival, isNull);
          expect(f.sample.discharge, isNull);
        }
        final at = [for (final f in none) f.sample.appointment];
        expect(at.toSet(), hasLength(at.length), reason: 'one per sample');
        expect({
          for (final t in at)
            if (onDate(t, ordinary)) hhmm(t),
        }, clocks(from, to).toSet());
        // Only noAllowedSet names a stage.
        expect(
          all.where((f) => f.reason != PublishReason.noAllowedSet),
          everyElement(
            isA<PublishFailure>().having((f) => f.stage, 'stage', isNull),
          ),
        );
      });

      test('49. $name: the rest of each such sample is still judged, so a '
          'base reminder at 23:30 the day before fails there too', () {
        final all = check(
          protocol,
          modules: {
            ...modules,
            'base': adding({
              'id': 'late',
              'type': 'diet',
              'anchor': 'appointment',
              'timing': {'kind': 'dayAt', 'day': -1, 'time': '23:30'},
              'remind': {
                'kind': 'dayAt',
                'day': -1,
                'time': '23:30',
                'defaulted': false,
              },
              'allowNight': false,
              'pastDue': 'ignore',
              'text': 'late',
            }),
          },
        );
        final none = withReason(all, PublishReason.noAllowedSet);
        expect(none, isNotEmpty);
        final quiet = {
          for (final f in withReason(all, PublishReason.quietHours))
            if (stepsOf(protocol, f).single == 'base/late')
              f.sample.appointment,
        };
        for (final f in none) {
          expect(quiet, contains(f.sample.appointment));
        }
      });
    }
  });

  test('31. every fixture over the season fails only where expected: UW '
      'first-day (quiet hours) and UMMC (no npo step)', () {
    final got = <String, Set<String>>{};
    for (final dir in protocolDirs()) {
      final protocol = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      got[protocol] = {
        for (final f in check(protocol))
          '${f.reason.name} ${stepsOf(protocol, f).join(' & ')}'.trim(),
      };
    }
    expect(got, {
      umms: {'noStopDrinking'},
      bmc: <String>{},
      karmanos: <String>{},
      uw: {'quietHours groin-site/first-day'},
      msk: <String>{},
      ccf: <String>{},
    });
  });

  test('32. a range with no clock change samples only its own dates', () {
    final dates = range(date(2026, 11, 20), date(2026, 11, 25));
    final all = check(uw, dates: dates);
    expect(all, isNotEmpty);
    for (final f in all) {
      final t = f.sample.discharge ?? f.sample.appointment;
      final d = date(t.year, t.month, t.day);
      expect(
        !d.isBefore(dates.from) && !d.isAfter(dates.through),
        isTrue,
        reason: '$t',
      );
    }
  });

  group('33. unsigned content is matched like a bundle', () {
    final f = filesIn('$protocols/$umms');
    String idOf(List<int> bytes) =>
        (jsonDecode(utf8.decode(bytes)) as Map<String, Object?>)['moduleId']!
            as String;
    // A hash mismatch returns nothing: publishCheck throws the BundleRefused
    // verifyBundle throws, naming the listed module it couldn't match.
    for (final (name, modules, reason, moduleId) in [
      (
        'a listed module missing',
        f.modules.where((m) => idOf(m) != '$umms-iron-hold').toList(),
        BundleRefusal.moduleNotMatched,
        '$umms-iron-hold',
      ),
      (
        'a module byte changed',
        [
          for (final m in f.modules)
            idOf(m) == '$umms-iron-hold' ? ([...m]..[m.length ~/ 2] ^= 1) : m,
        ],
        BundleRefusal.moduleNotMatched,
        '$umms-iron-hold',
      ),
      (
        'an unlisted file',
        [...f.modules, filesIn('$protocols/$bmc').modules.first],
        BundleRefusal.unlistedFile,
        null,
      ),
    ]) {
      test(name, () {
        expect(
          () => publishCheck(
            manifest: f.manifest,
            modules: modules,
            dates: season,
          ),
          throwsA(
            isA<BundleRefused>()
                .having((e) => e.reason, 'reason', reason)
                .having((e) => e.moduleId, 'moduleId', moduleId),
          ),
        );
      });
    }
  });

  test('34. the publish library never reaches selection or names Bundle, and '
      "the patient app's library doesn't export it", () {
    final lines = File('lib/src/publish.dart').readAsLinesSync();
    final imports = lines.where((l) => l.startsWith('import '));
    expect(imports.where((l) => l.contains('selection.dart')), isEmpty);
    // Content reaches the check as bytes, never as a verified Bundle.
    expect(
      lines.where(
        (l) =>
            !l.trimLeft().startsWith('//') && RegExp(r'\bBundle\b').hasMatch(l),
      ),
      isEmpty,
    );
    final timeline = File('lib/timeline.dart').readAsStringSync();
    expect(timeline, isNot(contains('publish')));
    // What publish reuses stays out of the patient app's library: each name
    // is hidden on the export of the source that declares it.
    final exports = {
      for (final m in RegExp(
        r"^export 'src/(\w+)\.dart'(?: hide ([\w, ]+))?;$",
        multiLine: true,
      ).allMatches(timeline))
        m[1]!: {...?m[2]?.split(', ')},
    };
    expect(exports, contains('bundle'));
    expect(exports, contains('reminder'));
    for (final name in [
      'manifestOf',
      'matchModules',
      'storedRemind',
      'reminderExemptions',
    ]) {
      final declared = [
        for (final f in Directory('lib/src').listSync().whereType<File>())
          if (RegExp(
            '^\\S.*\\b$name\\(',
            multiLine: true,
          ).hasMatch(f.readAsStringSync()))
            f.uri.pathSegments.last.replaceAll('.dart', ''),
      ];
      expect(declared, hasLength(1), reason: name);
      expect(exports[declared.single] ?? {name}, contains(name), reason: name);
    }
  });

  test('50. the two reminder exemptions are written once, in reminder.dart, '
      'and the phone and the publish check both call them', () {
    final sources = {
      for (final f in Directory('lib/src').listSync().whereType<File>())
        f.uri.pathSegments.last: f.readAsStringSync(),
    };
    List<String> having(String text) => [
      for (final MapEntry(:key, :value) in sources.entries)
        if (value.contains(text)) key,
    ];
    // The day-step exemption and the discharge-instant exemption.
    expect(having('day != 0'), ['reminder.dart']);
    expect(having('OffsetRemind(offset: Duration.zero)'), ['reminder.dart']);
    // reminder.dart declares it once and calls it from _placed.
    for (final (file, uses) in [('publish.dart', 1), ('reminder.dart', 2)]) {
      expect(
        RegExp(r'\breminderExemptions\(').allMatches(sources[file]!),
        hasLength(uses),
        reason: file,
      );
    }
  });
}
