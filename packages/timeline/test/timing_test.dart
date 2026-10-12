import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const fixtures = '../../fixtures/protocols';

Map<String, Object?> load(String path) =>
    jsonDecode(File('$fixtures/$path').readAsStringSync())
        as Map<String, Object?>;

List<Map<String, Object?>> stepsOf(Map<String, Object?> module) =>
    (module['steps']! as List<Object?>).cast<Map<String, Object?>>();

Map<String, Object?> parametersOf(Map<String, Object?> module) =>
    (module['parameters'] ?? <String, Object?>{}) as Map<String, Object?>;

/// Parses fixture step [id] in [path] and computes its effect.
Effect? effect(
  String path,
  String id,
  Anchors anchors, [
  Map<String, int> chosen = const {},
]) {
  final module = load(path);
  final step = stepsOf(module).singleWhere((s) => s['id'] == id);
  final timing = parseTiming(
    step['timing']! as Map<String, Object?>,
    (day) => resolveDay(day, parametersOf(module), chosen),
  );
  return effectOf(
    Anchor.values.byName(step['anchor']! as String),
    timing,
    anchors,
  );
}

// Expected instants written in UTC, so they can't come from the code under
// test.
int utc(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch;

int? ms(tz.TZDateTime? t) => t?.millisecondsSinceEpoch;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  tz.TZDateTime local(String zone, int y, int mo, int d, int h, [int mi = 0]) =>
      tz.TZDateTime(tz.getLocation(zone), y, mo, d, h, mi);

  Anchors appointment(tz.TZDateTime a) =>
      (appointment: a, arrival: null, discharge: null);

  const ny = 'America/New_York';
  const la = 'America/Los_Angeles';

  group('effects of fixture steps', () {
    test('UMMC dose2, offset -PT4H, 07:00 appointment', () {
      final e = effect(
        'colo-golytely-split-am-umms/base.json',
        'dose2',
        appointment(local(ny, 2026, 11, 18, 7)),
      )!;
      expect((ms(e.at), e.until), (utc(2026, 11, 18, 8), null));
    });
    test('BMC dose2, deadline -PT2H, 08:00 appointment', () {
      final e = effect(
        'colo-golytely-split-bmc/base.json',
        'dose2',
        appointment(local(ny, 2026, 11, 18, 8)),
      )!;
      expect((ms(e.at), e.until), (utc(2026, 11, 18, 11), null));
    });
    test('UMMC dose1, dayAt -1 17:00', () {
      final e = effect(
        'colo-golytely-split-am-umms/base.json',
        'dose1',
        appointment(local(ny, 2026, 11, 18, 7)),
      )!;
      expect(ms(e.at), utc(2026, 11, 17, 22));
    });
    test('CCF stop-pills, dayAt 0 00:00', () {
      final e = effect(
        'colo-sutab-low-volume-ccf/diabetes-pills.json',
        'stop-pills',
        appointment(local(ny, 2026, 11, 18, 8)),
      )!;
      expect(ms(e.at), utc(2026, 11, 18, 5));
    });
    test('BMC iron, day -7 until the appointment, across spring-forward', () {
      final e = effect(
        'colo-golytely-split-bmc/iron-hold.json',
        'iron',
        appointment(local(ny, 2027, 3, 15, 9)),
      )!;
      expect(
        (ms(e.at), ms(e.until)),
        (utc(2027, 3, 8, 5), utc(2027, 3, 15, 13)),
      );
    });
    test('Karmanos clear liquids, day -1 for one 25-hour day', () {
      final e = effect(
        'colo-miralax-split-karmanos/base.json',
        'clear-liquids',
        appointment(local('America/Detroit', 2026, 11, 2, 9)),
      )!;
      expect(
        (ms(e.at), ms(e.until)),
        (utc(2026, 11, 1, 4), utc(2026, 11, 2, 5)),
      );
    });
    test('BMC P2Y12 hold uses the chosen holdDays', () {
      Effect? hold(int days) => effect(
        'colo-golytely-split-bmc/p2y12-hold.json',
        'p2y12',
        appointment(local(ny, 2026, 11, 18, 9)),
        {'holdDays': days},
      );
      expect(ms(hold(7)!.at), utc(2026, 11, 11, 5));
      expect(ms(hold(5)!.at), utc(2026, 11, 13, 5));
      expect(() => hold(8), throwsArgumentError);
    });
    test('BMC Ticlid hold: 2 weeks is 14 calendar days', () {
      final e = effect(
        'colo-golytely-split-bmc/ticlid-hold.json',
        'ticlid',
        appointment(local(ny, 2026, 11, 18, 9)),
        {'holdWeeks': 2},
      )!;
      expect(ms(e.at), utc(2026, 11, 4, 5));
    });
    test('UW no caffeine, a 24-hour window ending at the appointment', () {
      final e = effect(
        'cardiac-cath-uw/base.json',
        'no-caffeine',
        appointment(local(la, 2026, 11, 18, 7)),
      )!;
      expect(
        (ms(e.at), ms(e.until)),
        (utc(2026, 11, 17, 15), utc(2026, 11, 18, 15)),
      );
    });
    test('UW after sedation: 24 elapsed hours across fall-back', () {
      Effect? sedation(tz.TZDateTime? discharge) =>
          effect('cardiac-cath-uw/sedation.json', 'after-sedation', (
            appointment: local(la, 2026, 10, 31, 9),
            arrival: null,
            discharge: discharge,
          ));
      expect(sedation(null), isNull);
      final e = sedation(local(la, 2026, 10, 31, 15))!;
      expect(
        (ms(e.at), ms(e.until)),
        (utc(2026, 10, 31, 22), utc(2026, 11, 1, 22)),
      );
      expect(e.until!.hour, 14);
    });
    test('MSK npo counts from arrival, pending until it is entered', () {
      Effect? npo(tz.TZDateTime? arrival) =>
          effect('surgery-anesthesia-msk/base.json', 'npo', (
            appointment: local(ny, 2026, 11, 18, 7, 30),
            arrival: arrival,
            discharge: null,
          ));
      expect(npo(null), isNull);
      expect(
        ms(npo(local(ny, 2026, 11, 18, 5, 30))!.at),
        utc(2026, 11, 18, 8, 30),
      );
    });
    test('an anchor in another time zone is rejected', () {
      final anchors = (
        appointment: local(ny, 2026, 11, 18, 9),
        arrival: null,
        discharge: tz.TZDateTime.utc(2026, 11, 18, 18),
      );
      expect(
        () => effectOf(
          Anchor.discharge,
          const OffsetTiming(Duration.zero),
          anchors,
        ),
        throwsArgumentError,
      );
    });
  });

  group('effectOf checks', () {
    test('untilAnchor on day 1 is rejected: it would end before it starts', () {
      expect(
        () => effectOf(
          Anchor.appointment,
          const DayTiming(1, Lasts.untilAnchor),
          appointment(local(ny, 2026, 11, 18, 9)),
        ),
        throwsArgumentError,
      );
    });
    test('untilAnchor on day 0 and day -3 still runs to the anchor', () {
      final anchor = local(ny, 2026, 11, 18, 9);
      final expected = {0: utc(2026, 11, 18, 5), -3: utc(2026, 11, 15, 5)};
      expected.forEach((day, start) {
        final e = effectOf(
          Anchor.appointment,
          DayTiming(day, Lasts.untilAnchor),
          appointment(anchor),
        )!;
        expect((ms(e.at), ms(e.until)), (start, utc(2026, 11, 18, 14)));
      });
    });
    test('a separately built Location with the same name is the same zone', () {
      final loaded = tz.getLocation(ny);
      final copy = tz.Location(
        loaded.name,
        loaded.transitionAt,
        loaded.transitionZone,
        loaded.zones,
      );
      expect(identical(copy, loaded), isFalse);
      final anchors = (
        appointment: tz.TZDateTime(loaded, 2026, 11, 18, 9),
        arrival: tz.TZDateTime(copy, 2026, 11, 18, 7),
        discharge: null,
      );
      final e = effectOf(
        Anchor.arrival,
        const OffsetTiming(Duration.zero),
        anchors,
      )!;
      expect(ms(e.at), utc(2026, 11, 18, 12));
    });
    test('an arrival in a different zone is still rejected', () {
      final anchors = (
        appointment: local(ny, 2026, 11, 18, 9),
        arrival: local('America/Chicago', 2026, 11, 18, 7),
        discharge: null,
      );
      expect(
        () => effectOf(
          Anchor.arrival,
          const OffsetTiming(Duration.zero),
          anchors,
        ),
        throwsArgumentError,
      );
    });
  });

  group('parseTiming', () {
    int noParams(Object? day) => resolveDay(day, const {}, const {});
    const bad = <Map<String, Object?>>[
      {'kind': 'window', 'start': 'PT0H', 'duration': 'PT0H'},
      {'kind': 'window', 'start': 'PT0H', 'duration': '-PT1H'},
      {'kind': 'day', 'day': -1},
      {'kind': 'day', 'day': -1, 'lasts': 'forever'},
      {'kind': 'offset', 'offset': 'P7D'},
      {'kind': 'dayAt', 'day': -1, 'time': '24:00'},
      {'kind': 'later', 'offset': 'PT1H'},
    ];
    for (final json in bad) {
      test('rejects $json', () {
        expect(() => parseTiming(json, noParams), throwsFormatException);
      });
    }

    test('parses every timed step in fixtures/protocols', () {
      var parsed = 0;
      for (final file in Directory(fixtures).listSync(recursive: true)) {
        if (file is! File || file.path.endsWith('protocol.json')) continue;
        final module =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final parameters = parametersOf(module);
        // Every declared parameter at its lowest and highest value.
        for (final pick in ['min', 'max']) {
          final chosen = {
            for (final MapEntry(:key, :value) in parameters.entries)
              key: (value! as Map<String, Object?>)[pick]! as int,
          };
          for (final step in stepsOf(module)) {
            if (step['timing'] case final Map<String, Object?> timing) {
              parseTiming(timing, (day) => resolveDay(day, parameters, chosen));
              Anchor.values.byName(step['anchor']! as String);
              if (pick == 'min') parsed++;
            }
          }
        }
      }
      expect(parsed, 69);
    });
  });

  group('resolveDay', () {
    test('a plain day number is used as written', () {
      expect(resolveDay(-3, const {}, const {}), -3);
    });
    test('every value from min - 1 to max + 1 of every fixture parameter', () {
      final declared = {
        'colo-golytely-split-bmc/p2y12-hold.json': ('holdDays', 5, 7, 1),
        'colo-golytely-split-bmc/sglt2-hold.json': ('holdDays', 3, 4, 1),
        'colo-golytely-split-bmc/ticlid-hold.json': ('holdWeeks', 1, 2, 7),
      };
      declared.forEach((path, p) {
        final (name, min, max, daysPerUnit) = p;
        final parameters = parametersOf(load(path));
        for (final before in [true, false]) {
          final ref = {'param': name, 'before': before};
          for (var v = min - 1; v <= max + 1; v++) {
            int resolve() => resolveDay(ref, parameters, {name: v});
            if (v < min || v > max) {
              expect(resolve, throwsArgumentError, reason: '$path $v');
            } else {
              expect(resolve(), (before ? -1 : 1) * v * daysPerUnit);
            }
          }
        }
      });
    });
    test('a parameter the clinician did not choose is rejected', () {
      final parameters = parametersOf(
        load('colo-golytely-split-bmc/p2y12-hold.json'),
      );
      expect(
        () => resolveDay(
          {'param': 'holdDays', 'before': true},
          parameters,
          const {},
        ),
        throwsArgumentError,
      );
    });
    test('an undeclared parameter is rejected', () {
      expect(
        () => resolveDay(
          {'param': 'holdDays', 'before': true},
          const {},
          {'holdDays': 5},
        ),
        throwsFormatException,
      );
    });
  });
}
