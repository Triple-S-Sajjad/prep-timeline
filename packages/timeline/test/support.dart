import 'dart:convert';
import 'dart:io';

import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Loads the time zone database and returns New York; shared by the tests.
tz.Location loadNewYork() {
  tzdata.initializeTimeZones();
  return tz.getLocation('America/New_York');
}

/// A local time in [zone].
tz.TZDateTime local(
  String zone,
  int y,
  int mo,
  int d,
  int h, [
  int mi = 0,
  int s = 0,
]) => tz.TZDateTime(tz.getLocation(zone), y, mo, d, h, mi, s);

/// Anchors with only the appointment known.
Anchors appointment(tz.TZDateTime a) =>
    (appointment: a, arrival: null, discharge: null);

/// Fixture module [path] and its step [id], as JSON.
({Map<String, Object?> module, Map<String, Object?> step}) fixtureJson(
  String path,
  String id,
) {
  final module = jsonDecode(
    File('../../fixtures/protocols/$path').readAsStringSync(),
  ) as Map<String, Object?>;
  final step = (module['steps']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((s) => s['id'] == id);
  return (module: module, step: step);
}

/// One step's JSON as a timed step; [day] turns a day number into days.
TimedStep stepFrom(Map<String, Object?> s, int Function(Object? d) day) => (
  id: s['id']! as String,
  anchor: Anchor.values.byName(s['anchor']! as String),
  timing: parseTiming(s['timing']! as Map<String, Object?>, day),
  remind: parseRemind(s['remind']! as Map<String, Object?>, day),
  allowNight: s['allowNight']! as bool,
  pastDue: PastDue.values.byName(s['pastDue']! as String),
);

/// A timed step from a fixture module, parsed the way the app will parse it,
/// with [chosen] parameter values.
TimedStep fixtureStep(
  String path,
  String id, [
  Map<String, int> chosen = const {},
]) {
  final (:module, :step) = fixtureJson(path, id);
  final params =
      (module['parameters'] ?? <String, Object?>{}) as Map<String, Object?>;
  return stepFrom(step, (d) => resolveDay(d, params, chosen));
}

bool inRange(({int hour, int minute}) clock, QuietHours range) {
  final c = clock.hour * 60 + clock.minute;
  final from = range.from.hour * 60 + range.from.minute;
  final to = range.to.hour * 60 + range.to.minute;
  return from <= to ? from <= c && c < to : c >= from || c < to;
}

typedef SampledStep = ({
  String name,
  TimedStep step,
  tz.Location zone,
  QuietHours bookable,
});

/// Every timed step in fixtures/protocols, each parameter at its lowest and
/// highest value, with its protocol's zone and bookable hours.
Iterable<SampledStep> everyFixtureStep() sync* {
  Map<String, Object?> read(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  final protocols = Directory('../../fixtures/protocols').listSync();
  for (final dir in protocols.whereType<Directory>()) {
    final manifest = read('${dir.path}/protocol.json');
    final hours = manifest['bookableHours']! as Map<String, Object?>;
    final zone = tz.getLocation(manifest['timezone']! as String);
    final bookable = (
      from: parseClockTime(hours['from']! as String),
      to: parseClockTime(hours['to']! as String),
    );
    for (final file in dir.listSync().whereType<File>()) {
      if (file.path.endsWith('protocol.json')) continue;
      final module = read(file.path);
      final params =
          (module['parameters'] ?? <String, Object?>{}) as Map<String, Object?>;
      for (final end in const ['min', 'max']) {
        final picked = params.map(
          (name, range) =>
              MapEntry(name, (range! as Map<String, Object?>)[end]! as int),
        );
        int day(Object? d) => resolveDay(d, params, picked);
        final steps = module['steps']! as List<Object?>;
        for (final s in steps.cast<Map<String, Object?>>()) {
          if (s.containsKey('timing')) {
            yield (
              name: '${module['moduleId']}/${s['id']}',
              step: stepFrom(s, day),
              zone: zone,
              bookable: bookable,
            );
          }
        }
      }
    }
  }
}

/// The publish check's samples (docs/spec.md, Conflict check at publish):
/// every 15 minutes inside bookable hours, with arrival at the appointment,
/// or across the whole day for discharge; on an ordinary date and on each
/// 2026-2027 clock-change date of the fixtures' US zones.
void forEverySample(
  void Function(SampledStep f, Anchors anchors, tz.TZDateTime sample) check,
) {
  const dates = [
    (2026, 11, 18),
    (2026, 3, 8),
    (2026, 11, 1),
    (2027, 3, 14),
    (2027, 11, 7),
  ];
  for (final f in everyFixtureStep()) {
    for (final (y, m, d) in dates) {
      for (var minute = 0; minute < 24 * 60; minute += 15) {
        final clock = (hour: minute ~/ 60, minute: minute % 60);
        final discharge = f.step.anchor == Anchor.discharge;
        if (!discharge && !inRange(clock, f.bookable)) continue;
        final t = localTime(f.zone, y, m, d, clock.hour, clock.minute);
        final Anchors anchors = switch (f.step.anchor) {
          Anchor.appointment => (
            appointment: t,
            arrival: null,
            discharge: null,
          ),
          Anchor.arrival => (appointment: t, arrival: t, discharge: null),
          Anchor.discharge => (
            appointment: localTime(f.zone, y, m, d, 0, 0),
            arrival: null,
            discharge: t,
          ),
        };
        check(f, anchors, t);
      }
    }
  }
}
