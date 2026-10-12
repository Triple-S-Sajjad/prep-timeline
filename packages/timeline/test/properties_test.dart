import 'dart:math';

import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Each zone stresses a different kind of clock change.
const zones = [
  'America/New_York', // northern-hemisphere DST
  'America/Phoenix', // no DST
  'Australia/Sydney', // southern-hemisphere DST
  'America/Santiago', // changes at midnight
  'Australia/Lord_Howe', // 30-minute change
  'Asia/Kolkata', // half-hour offset, no DST
];
const noDst = {'America/Phoenix', 'Asia/Kolkata'};

const minuteMs = Duration.millisecondsPerMinute;
const hourMs = Duration.millisecondsPerHour;
const dayMs = Duration.millisecondsPerDay;

/// In ascending order, so each result must be no earlier than the last.
const offsets = [
  Duration(hours: -336),
  Duration(hours: -168),
  Duration(hours: -25),
  Duration(hours: -24),
  Duration(hours: -6),
  Duration(minutes: -90),
  Duration.zero,
  Duration(minutes: 30),
  Duration(hours: 24),
  Duration(hours: 72),
];

const windowLengths = [
  Duration(minutes: 30),
  Duration(hours: 24),
  Duration(hours: 120),
];

const everyKind = <Timing>[
  OffsetTiming(Duration(hours: -6)),
  DayAtTiming(-1, (hour: 17, minute: 0)),
  DayTiming(-1, Lasts.oneDay),
  WindowTiming(Duration.zero, Duration(hours: 24)),
  DeadlineTiming(Duration(hours: -2)),
];

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final name in zones) {
    group(name, () {
      late tz.Location loc;
      late List<tz.TZDateTime> hourly;
      late List<tz.TZDateTime> daily;

      setUpAll(() {
        loc = tz.getLocation(name);
        hourly = everyLocalHour(loc);
        daily = onePerDate(hourly);
      });

      test('stepTime moves by exactly the offset, in order', () {
        final failures = Failures();
        for (final a in hourly) {
          var previous =
              a.millisecondsSinceEpoch + offsets.first.inMilliseconds;
          for (final offset in offsets) {
            final got = stepTime(a, offset);
            final ms = got.millisecondsSinceEpoch;
            failures.check(
              ms - a.millisecondsSinceEpoch == offset.inMilliseconds &&
                  got.location == loc &&
                  ms >= previous,
              () => 'stepTime($a, $offset) = $got',
            );
            previous = ms;
          }
        }
        failures.expectNone();
      });

      test('dayAtTime keeps the calendar day and clock time', () {
        final failures = Failures();
        var skipped = 0;
        var repeated = 0;
        for (final a in daily) {
          for (var day = -14; day <= 3; day++) {
            // DateTime.utc rolls day overflow into the next month or year.
            final date = DateTime.utc(a.year, a.month, a.day + day);
            for (var hour = 0; hour < 24; hour++) {
              for (final minute in const [0, 30]) {
                final wall =
                    date.millisecondsSinceEpoch +
                    (hour * 60 + minute) * minuteMs;
                final (:expected, :occurrences) = whenLocal(loc, wall);
                if (occurrences == 0) skipped++;
                if (occurrences == 2) repeated++;
                final got = dayAtTime(a, day, hour, minute);
                failures.check(
                  got.millisecondsSinceEpoch == expected && got.location == loc,
                  () =>
                      'dayAtTime($a, $day, $hour:$minute) = $got, expected '
                      '${tz.TZDateTime.fromMillisecondsSinceEpoch(loc, expected)}',
                );
              }
            }
          }
        }
        failures.expectNone();
        // Proves the skipped and repeated cases ran wherever the zone has them.
        final hasDst = !noDst.contains(name);
        expect((skipped > 0, repeated > 0), (hasDst, hasDst));
      });

      test(
        'dayStart is the first instant of each date, 22 to 26 hours apart',
        () {
          final failures = Failures();
          for (final a in daily) {
            int? previous;
            for (var day = -14; day <= 4; day++) {
              final got = dayStart(a, day);
              final ms = got.millisecondsSinceEpoch;
              final date = DateTime.utc(a.year, a.month, a.day + day);
              final dayBefore = DateTime.utc(a.year, a.month, a.day + day - 1);
              failures.check(
                localDate(loc, ms) == date &&
                    localDate(loc, ms - 1) == dayBefore &&
                    got.location == loc &&
                    (previous == null ||
                        (ms - previous >= 22 * hourMs &&
                            ms - previous <= 26 * hourMs)),
                () => 'dayStart($a, $day) = $got',
              );
              previous = ms;
            }
          }
          failures.expectNone();
        },
      );

      test('matches a minute-by-minute scan on every clock-change day', () {
        final days = changeDays(loc);
        expect(days.isNotEmpty, !noDst.contains(name));
        final failures = Failures();
        for (final date in days) {
          final (:start, :minutes) = scan(loc, date);
          // Anchored two days later, so the calendar arithmetic runs too.
          final anchor = tz.TZDateTime.fromMillisecondsSinceEpoch(
            loc,
            start + 60 * hourMs,
          );
          final day = date
              .difference(localDate(loc, start + 60 * hourMs))
              .inDays;
          final got = dayStart(anchor, day);
          failures.check(
            got.millisecondsSinceEpoch == start,
            () =>
                'dayStart($anchor, $day) = $got, expected '
                '${tz.TZDateTime.fromMillisecondsSinceEpoch(loc, start)}',
          );
          for (var m = 0; m < minutes.length; m++) {
            final got = dayAtTime(anchor, day, m ~/ 60, m % 60);
            failures.check(
              got.millisecondsSinceEpoch == minutes[m],
              () =>
                  'dayAtTime($anchor, $day, ${m ~/ 60}:${m % 60}) = $got, '
                  'expected '
                  '${tz.TZDateTime.fromMillisecondsSinceEpoch(loc, minutes[m])}',
            );
          }
        }
        failures.expectNone();
      });

      test('effectOf: offset, deadline and window are exact elapsed times', () {
        final failures = Failures();
        for (final a in hourly) {
          final anchors = (appointment: a, arrival: null, discharge: null);
          final from = a.millisecondsSinceEpoch;
          for (final offset in offsets) {
            for (final timing in [
              OffsetTiming(offset),
              DeadlineTiming(offset),
            ]) {
              final e = effectOf(Anchor.appointment, timing, anchors)!;
              failures.check(
                e.at.millisecondsSinceEpoch - from == offset.inMilliseconds &&
                    e.at.location == loc &&
                    e.until == null,
                () => '${timing.runtimeType}($offset) from $a = $e',
              );
            }
            for (final duration in windowLengths) {
              final e = effectOf(
                Anchor.appointment,
                WindowTiming(offset, duration),
                anchors,
              )!;
              final at = e.at.millisecondsSinceEpoch;
              failures.check(
                at - from == offset.inMilliseconds &&
                    e.until!.millisecondsSinceEpoch - at ==
                        duration.inMilliseconds &&
                    e.until!.location == loc,
                () => 'WindowTiming($offset, $duration) from $a = $e',
              );
            }
          }
        }
        failures.expectNone();
      });

      test('effectOf: day and dayAt land on the anchor date + day', () {
        final failures = Failures();
        for (final a in daily) {
          final anchors = (appointment: a, arrival: null, discharge: null);
          for (var day = -14; day <= 3; day++) {
            final date = DateTime.utc(a.year, a.month, a.day + day);
            final next = DateTime.utc(a.year, a.month, a.day + day + 1);
            final oneDay = effectOf(
              Anchor.appointment,
              DayTiming(day, Lasts.oneDay),
              anchors,
            )!;
            // untilAnchor runs from the day's start to the anchor, and is
            // rejected after the anchor, where it would end before it starts.
            bool untilAnchorHolds() {
              try {
                final e = effectOf(
                  Anchor.appointment,
                  DayTiming(day, Lasts.untilAnchor),
                  anchors,
                )!;
                return day <= 0 && e.at == oneDay.at && e.until == a;
              } on ArgumentError {
                return day >= 1;
              }
            }

            final until = oneDay.until!.millisecondsSinceEpoch;
            failures.check(
              localDate(loc, oneDay.at.millisecondsSinceEpoch) == date &&
                  // oneDay ends at the first instant of the next date.
                  localDate(loc, until) == next &&
                  localDate(loc, until - 1) == date &&
                  untilAnchorHolds(),
              () => 'day $day from $a: oneDay $oneDay, untilAnchor wrong',
            );
            // Times every zone here has on every date.
            for (final hour in const [6, 12, 18]) {
              final timing = DayAtTiming(day, (hour: hour, minute: 30));
              final e = effectOf(Anchor.appointment, timing, anchors)!;
              failures.check(
                localDate(loc, e.at.millisecondsSinceEpoch) == date &&
                    (e.at.hour, e.at.minute) == (hour, 30) &&
                    e.until == null,
                () => 'dayAt $day $hour:30 from $a = $e',
              );
            }
          }
        }
        failures.expectNone();
      });

      test('effectOf is pending exactly when its anchor is unknown', () {
        final failures = Failures();
        for (final a in daily) {
          for (final arrival in [null, a]) {
            for (final discharge in [null, a]) {
              final anchors = (
                appointment: a,
                arrival: arrival,
                discharge: discharge,
              );
              for (final anchor in Anchor.values) {
                final known = switch (anchor) {
                  Anchor.appointment => true,
                  Anchor.arrival => arrival != null,
                  Anchor.discharge => discharge != null,
                };
                for (final timing in everyKind) {
                  final e = effectOf(anchor, timing, anchors);
                  failures.check(
                    (e != null) == known,
                    () => '$anchor ${timing.runtimeType} with $anchors = $e',
                  );
                }
              }
            }
          }
        }
        failures.expectNone();
      });
    });
  }

  group('2026 Canadian changes', () {
    const skip = 'needs timezone 0.11.2 (IANA 2026e)';
    test('America/Vancouver on 2026-11-15 12:00 is UTC-7', () {
      final t = tz.TZDateTime(
        tz.getLocation('America/Vancouver'),
        2026,
        11,
        15,
        12,
      );
      expect(t.timeZoneOffset, const Duration(hours: -7));
    }, skip: skip);
    test('America/Edmonton on 2026-11-15 12:00 is UTC-6', () {
      final t = tz.TZDateTime(
        tz.getLocation('America/Edmonton'),
        2026,
        11,
        15,
        12,
      );
      expect(t.timeZoneOffset, const Duration(hours: -6));
    }, skip: skip);
  });
}

int offsetAt(tz.Location loc, int utc) =>
    loc.timeZone(utc).offset.inMilliseconds;

DateTime localDate(tz.Location loc, int utc) {
  final t = tz.TZDateTime.fromMillisecondsSinceEpoch(loc, utc);
  return DateTime.utc(t.year, t.month, t.day);
}

/// Every instant in 2026 and 2027 whose local time is on the hour, so a
/// repeated hour appears twice and a skipped one not at all. Steps by 30
/// minutes because Kolkata and Lord Howe sit a half hour off UTC.
List<tz.TZDateTime> everyLocalHour(tz.Location loc) => [
  for (
    var utc = DateTime.utc(2025, 12, 31).millisecondsSinceEpoch;
    utc < DateTime.utc(2028, 1, 2).millisecondsSinceEpoch;
    utc += 30 * minuteMs
  )
    if (tz.TZDateTime.fromMillisecondsSinceEpoch(loc, utc) case final t
        when t.minute == 0 && (t.year == 2026 || t.year == 2027))
      t,
];

/// One anchor per local date: the calendar functions depend only on the
/// anchor's date. The hour rotates from date to date so the anchor's own
/// clock time still varies.
List<tz.TZDateTime> onePerDate(List<tz.TZDateTime> hourly) {
  final byDate = <DateTime, List<tz.TZDateTime>>{};
  for (final a in hourly) {
    (byDate[DateTime.utc(a.year, a.month, a.day)] ??= []).add(a);
  }
  return [
    for (final (i, hours) in byDate.values.indexed) hours[i % hours.length],
  ];
}

/// When local wall-clock time [wall] (milliseconds, read as if UTC) happens,
/// worked out from UTC-to-local offsets alone, never from the local-to-UTC
/// conversion under test. Each zone here changes offset at most once in any
/// four days, so the offsets two days either side are the only two [wall]
/// can be read with.
({int expected, int occurrences}) whenLocal(tz.Location loc, int wall) {
  final readings = {
    wall - offsetAt(loc, wall - 2 * dayMs),
    wall - offsetAt(loc, wall + 2 * dayMs),
  };
  final real = [
    for (final utc in readings)
      if (utc + offsetAt(loc, utc) == wall) utc,
  ];
  // Skipped (none) or repeated (two): the earlier instant, per docs/spec.md.
  return (
    expected: real.length == 1 ? real.single : readings.reduce(min),
    occurrences: real.length,
  );
}

/// Local dates in 2026 and 2027 with a clock change. Both sides of each change
/// count, since a fall-back at midnight repeats the evening before.
Set<DateTime> changeDays(tz.Location loc) => {
  for (
    var utc = DateTime.utc(2025, 12, 30).millisecondsSinceEpoch;
    utc < DateTime.utc(2028, 1, 2).millisecondsSinceEpoch;
    utc += 30 * minuteMs
  )
    if (offsetAt(loc, utc) != offsetAt(loc, utc - 30 * minuteMs))
      for (final d in [
        localDate(loc, utc - 30 * minuteMs),
        localDate(loc, utc),
      ])
        if (d.year == 2026 || d.year == 2027) d,
};

/// Brute force, independent of how the calculator resolves local times:
/// visits every UTC minute that could fall on local [date] and records the
/// first instant of the date and, for each minute of it, the first instant
/// the clock shows that minute. A minute a spring-forward jump skips gets the
/// earlier instant per docs/spec.md: the jump, less how far the minute falls
/// short of where the clock lands.
({int start, List<int> minutes}) scan(tz.Location loc, DateTime date) {
  final midnight = date.millisecondsSinceEpoch;
  final first = List<int?>.filled(24 * 60, null);
  final jumps = <({int at, int from, int to})>[];
  int? start;
  int? previousLocal;
  for (
    var utc = midnight - 15 * hourMs;
    utc < midnight + dayMs + 15 * hourMs;
    utc += minuteMs
  ) {
    final local = utc + offsetAt(loc, utc);
    if (previousLocal != null && local - previousLocal > minuteMs) {
      jumps.add((at: utc, from: previousLocal, to: local));
    }
    previousLocal = local;
    if (local >= midnight && local < midnight + dayMs) {
      start ??= utc;
      first[(local - midnight) ~/ minuteMs] ??= utc;
    }
  }
  final minutes = [
    for (var m = 0; m < first.length; m++)
      first[m] ??
          [
            for (final j in jumps)
              if (j.from < midnight + m * minuteMs &&
                  midnight + m * minuteMs < j.to)
                j.at - (j.to - (midnight + m * minuteMs)),
          ].single,
  ];
  return (start: start!, minutes: minutes);
}

/// Counts failing cases and keeps the first, so a broken property reports one
/// readable counterexample instead of millions of failures.
final class Failures {
  var count = 0;
  String? first;

  void check(bool ok, String Function() describe) {
    if (ok) return;
    count++;
    first ??= describe();
  }

  void expectNone() => expect(count, 0, reason: 'first counterexample: $first');
}
