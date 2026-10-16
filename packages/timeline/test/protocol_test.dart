import 'dart:io';

import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Map<String, Object?> stepJson(Map<String, Object?> json, String id) =>
      (json['steps']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .singleWhere((s) => s['id'] == id);

  group('parseManifest', () {
    test('1. UMMC: zone, defaults, base and optional modules', () {
      final m = parseManifest(
        fixture('colo-golytely-split-am-umms/protocol.json'),
      );
      expect(m.protocolId, 'colo-golytely-split-am-umms');
      expect(m.version, 1);
      expect(m.zone.name, 'America/New_York');
      expect(m.defaults, (
        evening: (hour: 20, minute: 0),
        quiet: (from: (hour: 23, minute: 0), to: (hour: 5, minute: 0)),
      ));
      expect(m.bookable, (
        from: (hour: 7, minute: 0),
        to: (hour: 12, minute: 0),
      ));
      expect(m.base, (
        moduleId: 'colo-golytely-split-am-umms-base',
        version: 1,
        sha256:
            '7e4300b6bd62267b290b8110bd43764be18e0a13b6ff6d7158ce5f5efd3e0758',
        selectedAt: null,
      ));
      expect(m.optional, [
        (
          moduleId: 'colo-golytely-split-am-umms-iron-hold',
          version: 1,
          sha256: 'a0ba7ab1f052fc4125ae8745e0e39b54c9a0a32855198b96f1f1d75e6f48f2b9',
          selectedAt: SelectedAt.scheduling,
        ),
      ]);
      expect(m.exactlyOneOf, isEmpty);
    });

    test('2. every fixture manifest parses, in its own zone', () {
      for (final dir in protocolDirs()) {
        final json = readJson('${dir.path}/protocol.json');
        expect(
          parseManifest(json).zone.name,
          json['timezone'],
          reason: dir.path,
        );
      }
    });

    test('3. an optional module without selectedAt is rejected', () {
      final json = fixture('colo-golytely-split-am-umms/protocol.json');
      final optional = json['optionalModules']! as List<Object?>;
      (optional.single! as Map<String, Object?>).remove('selectedAt');
      expect(() => parseManifest(json), throwsFormatException);
    });

    group('4. allowedCombinations', () {
      Map<String, Object?> uw() => fixture('cardiac-cath-uw/protocol.json');
      Map<String, Object?> combinations(Map<String, Object?> json) =>
          json['allowedCombinations']! as Map<String, Object?>;
      Map<String, Object?> group(Map<String, Object?> json) =>
          (combinations(json)['exactlyOneOf']! as List<Object?>).single!
              as Map<String, Object?>;
      test('UW parses its clinician group', () {
        expect(
          parseManifest(uw()).exactlyOneOf.single.selectBy,
          SelectBy.clinician,
        );
      });
      test('a group without selectBy is rejected', () {
        final json = uw();
        group(json).remove('selectBy');
        expect(() => parseManifest(json), throwsFormatException);
      });
      test('an unknown selectBy is rejected', () {
        final json = uw();
        group(json)['selectBy'] = 'patient';
        expect(() => parseManifest(json), throwsFormatException);
      });
      test('a rule other than anySubset is rejected', () {
        final json = uw();
        combinations(json)['rule'] = 'allOf';
        expect(() => parseManifest(json), throwsFormatException);
      });
      test('UW keeps both module IDs, in manifest order', () {
        expect(parseManifest(uw()).exactlyOneOf.single.modules, [
          'cardiac-cath-uw-groin-site',
          'cardiac-cath-uw-arm-site',
        ]);
      });
      test('a module ID that is not a string is rejected', () {
        final json = uw();
        group(json)['modules'] = ['cardiac-cath-uw-groin-site', 1];
        expect(() => parseManifest(json), throwsFormatException);
      });
    });

    test('5. a time zone that is not IANA is rejected', () {
      final json = fixture('colo-golytely-split-am-umms/protocol.json');
      json['timezone'] = 'America/Nowhere';
      expect(() => parseManifest(json), throwsFormatException);
    });

    test('15. a sha256 that is not 64 lowercase hex digits is rejected', () {
      const valid =
          'ba0dd89a121313a49f3896e396769d51f847241e0a241400cc949697bc8be8ca';
      for (final bad in [
        valid.toUpperCase(),
        valid.substring(1),
        '${valid}0',
        'x$valid',
      ]) {
        final json = fixture('colo-golytely-split-am-umms/protocol.json');
        (json['baseModule']! as Map<String, Object?>)['sha256'] = bad;
        expect(() => parseManifest(json), throwsFormatException, reason: bad);
      }
    });
  });

  group('parseModule', () {
    Map<String, Object?> pm() =>
        fixture('colo-miralax-split-karmanos/pm-schedule.json');
    Map<String, Object?> pmTimes(Map<String, Object?> json) =>
        (json['appliesWhen']! as Map<String, Object?>)['appointmentTime']!
            as Map<String, Object?>;

    test('6. Karmanos pm applies from 12:00 to 24:00', () {
      final m = parseModule(pm());
      expect(m.moduleId, 'colo-miralax-split-karmanos-pm-schedule');
      expect(m.version, 1);
      expect(m.appliesWhen, (from: 720, to: 1440));
    });

    test('7. a 12:00 appointment falls on exactly one side', () {
      const am = (from: 0, to: 720);
      const pm = (from: 720, to: 1440);
      const detroit = 'America/Detroit';
      final cases = {
        local(detroit, 2026, 11, 18, 11, 59): (am: true, pm: false),
        local(detroit, 2026, 11, 18, 12): (am: false, pm: true),
        local(detroit, 2026, 11, 18, 23, 59): (am: false, pm: true),
        local(detroit, 2026, 11, 18, 0): (am: true, pm: false),
      };
      cases.forEach((appointment, expected) {
        expect(
          (am: appliesAt(am, appointment), pm: appliesAt(pm, appointment)),
          expected,
          reason: '$appointment',
        );
      });
    });

    test('8. 24:00 is allowed only as the end of the range', () {
      for (final (key, value) in const [
        ('fromInclusive', '24:00'),
        ('toExclusive', '24:01'),
        ('toExclusive', '25:00'),
      ]) {
        final json = pm();
        pmTimes(json)[key] = value;
        expect(
          () => parseModule(json),
          throwsFormatException,
          reason: '$key $value',
        );
      }
    });

    test('9. a module carrying a time zone is rejected', () {
      final json = pm()..['timezone'] = 'America/Detroit';
      expect(() => parseModule(json), throwsFormatException);
    });

    test('16. appliesWhen keeps the minutes: 07:30 to 11:45', () {
      final json = pm();
      pmTimes(json)
        ..['fromInclusive'] = '07:30'
        ..['toExclusive'] = '11:45';
      expect(parseModule(json).appliesWhen, (from: 450, to: 705));
    });

    test('17. appliesAt counts the minutes of the appointment', () {
      const range = (from: 450, to: 705);
      const detroit = 'America/Detroit';
      final cases = {
        local(detroit, 2026, 11, 18, 7, 29): false,
        local(detroit, 2026, 11, 18, 7, 30): true,
        local(detroit, 2026, 11, 18, 11, 44): true,
        local(detroit, 2026, 11, 18, 11, 45): false,
      };
      cases.forEach((appointment, expected) {
        expect(appliesAt(range, appointment), expected, reason: '$appointment');
      });
    });

    test('18. BMC Ticlid hold declares holdWeeks from 1 to 2 weeks', () {
      expect(
        parseModule(fixture('colo-golytely-split-bmc/ticlid-hold.json'))
            .parameters,
        {'holdWeeks': (min: 1, max: 2, unit: 'weeks')},
      );
    });

    test('22. a module without appliesWhen is rejected: there is no '
        'default', () {
      final json = pm()..remove('appliesWhen');
      expect(() => parseModule(json), throwsFormatException);
    });

    for (final bad in const [<Object?>[], 'holdWeeks', 3, null]) {
      test('24. parameters $bad is a FormatException, not a TypeError', () {
        final json = pm()..['parameters'] = bad;
        expect(() => parseModule(json), throwsFormatException);
      });
    }
  });

  group('timedSteps', () {
    List<TimedStep> steps(String path, [Map<String, int> chosen = const {}]) =>
        timedSteps(parseModule(fixture(path)), chosen);

    test('10. UMMC dose1 carries its id and pastDue level', () {
      final dose1 = steps('colo-golytely-split-am-umms/base.json')
          .singleWhere((s) => s.id == 'dose1');
      expect(dose1.anchor, Anchor.appointment);
      final timing = dose1.timing as DayAtTiming;
      expect((timing.day, timing.time), (-1, (hour: 17, minute: 0)));
      final remind = dose1.remind as DayAtRemind;
      expect((remind.day, remind.time), (-1, (hour: 17, minute: 0)));
      expect(dose1.allowNight, isFalse);
      expect(dose1.pastDue, PastDue.critical);
    });

    test('11. a timed step without pastDue is rejected: there is no '
        'default', () {
      final json = readJson(
        '../../fixtures/invalid/missing-past-due-bmc/base.json',
      );
      expect(
        () => timedSteps(parseModule(json), const {}),
        throwsFormatException,
      );
    });

    test('12. untimed checklist and reference items are not timed steps; a '
        'checklist item with a time is', () {
      List<String> ids(String path) => [for (final s in steps(path)) s.id];
      // no-call is a checklist item with a time; the rest are references.
      expect(ids('surgery-anesthesia-msk/base.json'), [
        'stop-eating',
        'no-call',
        'npo',
      ]);
      // ride, med-sheet, prescription (checklist) and contacts (reference)
      // have no time.
      expect(ids('colo-golytely-split-bmc/base.json'), [
        'low-fiber',
        'mix',
        'clear-liquids',
        'med-sheet-again',
        'dose1',
        'dose2',
        'npo',
        'arrive',
      ]);
    });

    test('14. every fixture module parses, with every parameter at its lowest '
        'and highest value; every timed step keeps its id, anchor, allowNight '
        'and pastDue', () {
      for (final dir in protocolDirs()) {
        for (final file in dir.listSync().whereType<File>()) {
          if (file.path.endsWith('protocol.json')) continue;
          final json = readJson(file.path);
          final module = parseModule(json);
          final expected = [
            for (final s
                in (json['steps']! as List<Object?>)
                    .cast<Map<String, Object?>>())
              if (s.containsKey('timing'))
                (
                  s['id'],
                  Anchor.values.byName(s['anchor']! as String),
                  s['allowNight'],
                  PastDue.values.byName(s['pastDue']! as String),
                ),
          ];
          for (final pick in [
            (ParamRange p) => p.min,
            (ParamRange p) => p.max,
          ]) {
            final chosen = module.parameters.map(
              (k, p) => MapEntry(k, pick(p)),
            );
            expect(
              [
                for (final s in timedSteps(module, chosen))
                  (s.id, s.anchor, s.allowNight, s.pastDue),
              ],
              expected,
              reason: file.path,
            );
          }
        }
      }
    });

    group('BMC Ticlid hold', () {
      const ticlid = 'colo-golytely-split-bmc/ticlid-hold.json';
      for (final (weeks, day) in const [(1, -7), (2, -14)]) {
        test('19. holdWeeks $weeks puts timing and remind on day $day', () {
          final step = steps(ticlid, {'holdWeeks': weeks}).single;
          expect(
            ((step.timing as DayTiming).day, (step.remind as DayAtRemind).day),
            (day, day),
          );
        });
      }
      for (final weeks in const [0, 3]) {
        test('20. holdWeeks $weeks is outside 1 to 2 and rejected again '
            'here', () {
          expect(
            () => steps(ticlid, {'holdWeeks': weeks}),
            throwsArgumentError,
          );
        });
      }
    });

    test('21. a timed step without a remind is rejected', () {
      final json = fixture('colo-golytely-split-am-umms/base.json');
      stepJson(json, 'dose1').remove('remind');
      expect(
        () => timedSteps(parseModule(json), const {}),
        throwsFormatException,
      );
    });

    group('23. a step with remind, pastDue, allowNight or anchor but no timing '
        'is rejected, never listed as untimed', () {
      test('UMMC dose1 without its timing', () {
        final json = fixture('colo-golytely-split-am-umms/base.json');
        stepJson(json, 'dose1').remove('timing');
        expect(
          () => timedSteps(parseModule(json), const {}),
          throwsFormatException,
        );
      });
      for (final (key, value) in const [
        ('remind', {'kind': 'offset', 'offset': '-PT2H', 'defaulted': false}),
        ('pastDue', 'doNow'),
        ('allowNight', false),
        ('anchor', 'appointment'),
      ]) {
        test('BMC ride, a checklist item, given only $key', () {
          final json = fixture('colo-golytely-split-bmc/base.json');
          stepJson(json, 'ride')[key] = value;
          expect(
            () => timedSteps(parseModule(json), const {}),
            throwsFormatException,
          );
        });
      }
    });

    test('25. a step with a timing but no anchor, remind, allowNight or '
        'pastDue is rejected, never listed as untimed', () {
      final json = fixture('colo-golytely-split-am-umms/base.json');
      stepJson(json, 'dose1')
        ..remove('anchor')
        ..remove('remind')
        ..remove('allowNight')
        ..remove('pastDue');
      expect(
        () => timedSteps(parseModule(json), const {}),
        throwsFormatException,
      );
    });
  });

  group('26. a parsed manifest or module cannot be changed, at any depth', () {
    Manifest karmanos() =>
        parseManifest(fixture('colo-miralax-split-karmanos/protocol.json'));

    /// BMC P2Y12 hold, with a list of maps added to its p2y12 step so the
    /// freeze is checked inside lists too.
    Module p2y12() {
      final json = fixture('colo-golytely-split-bmc/p2y12-hold.json');
      stepJson(json, 'p2y12')['extra'] = <Object?>[
        <String, Object?>{'key': 'value'},
      ];
      return parseModule(json);
    }

    Map<String, Object?> stepOf(Module m) => m.steps.last;
    Map<String, Object?> mapAt(Map<String, Object?> json, String key) =>
        json[key]! as Map<String, Object?>;

    for (final (name, change) in <(String, void Function())>[
      (
        'Manifest.optional, add',
        () {
          final m = karmanos();
          m.optional.add(m.optional.first);
        },
      ),
      (
        'Manifest.optional, replace',
        () {
          final m = karmanos();
          m.optional[0] = m.optional.last;
        },
      ),
      (
        'Manifest.exactlyOneOf, add',
        () {
          final m = karmanos();
          m.exactlyOneOf.add(m.exactlyOneOf.first);
        },
      ),
      (
        'Manifest.exactlyOneOf, a group remove',
        () => karmanos().exactlyOneOf.first.modules.removeLast(),
      ),
      (
        'Module.parameters, add',
        () {
          final m = p2y12();
          m.parameters['holdWeeks'] = m.parameters['holdDays']!;
        },
      ),
      ('Module.steps, add', () => p2y12().steps.add({})),
      ('a step map, set', () => stepOf(p2y12())['pastDue'] = 'ignore'),
      ('a step map, remove', () => stepOf(p2y12()).remove('pastDue')),
      (
        "a step's timing, set",
        () => mapAt(stepOf(p2y12()), 'timing')['lasts'] = 'oneDay',
      ),
      (
        "a step's timing day parameter, set",
        () => mapAt(mapAt(stepOf(p2y12()), 'timing'), 'day')['before'] = false,
      ),
      (
        'a list in a step, add',
        () => (stepOf(p2y12())['extra']! as List<Object?>).add(1),
      ),
      (
        'a map in a list in a step, set',
        () =>
            ((stepOf(p2y12())['extra']! as List<Object?>).first!
                    as Map<String, Object?>)['key'] =
                'changed',
      ),
    ]) {
      test(name, () => expect(change, throwsUnsupportedError));
    }
  });
}
