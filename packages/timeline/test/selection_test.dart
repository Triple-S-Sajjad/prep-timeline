import 'dart:io';

import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support.dart';

const umms = 'colo-golytely-split-am-umms';
const bmc = 'colo-golytely-split-bmc';
const karmanos = 'colo-miralax-split-karmanos';
const uw = 'cardiac-cath-uw';
const msk = 'surgery-anesthesia-msk';
const ccf = 'colo-sutab-low-volume-ccf';

const ny = 'America/New_York';
const la = 'America/Los_Angeles';
const detroit = 'America/Detroit';

/// Protocols with no step that stops all liquids, left out of test 33 until
/// they have one (fixtures/open-questions.md, "Stop-drinking step to
/// confirm").
const noStopDrinking = {umms};

typedef Bundle = ({Manifest manifest, Map<String, Module> modules});

/// A fixture protocol's manifest and modules, as the app loads them.
Bundle bundle(String protocol) {
  final dir = '$protocols/$protocol';
  final modules = [
    for (final f in Directory(dir).listSync().whereType<File>())
      if (!f.path.endsWith('protocol.json')) parseModule(readJson(f.path)),
  ];
  return (
    manifest: parseManifest(readJson('$dir/protocol.json')),
    modules: {for (final m in modules) m.moduleId: m},
  );
}

/// A code's JSON with full module IDs, fresh each call so a test can change
/// it.
Map<String, Object?> codeJson(
  String protocol,
  SelectedAt stage,
  List<String> modules,
  Map<String, Map<String, Object?>> parameters,
) => {
  'protocolId': protocol,
  'version': 1,
  'stage': stage.name,
  'modules': [...modules],
  'parameters': {
    for (final MapEntry(:key, :value) in parameters.entries) key: {...value},
  },
  'createdAt': '2026-11-01T14:00:00Z',
};

/// The same with short module names: 'iron-hold' for '<protocol>-iron-hold'.
Map<String, Object?> code(
  String protocol,
  SelectedAt stage,
  List<String> modules, [
  Map<String, Map<String, Object?>> parameters = const {},
]) => codeJson(
  protocol,
  stage,
  [for (final m in modules) '$protocol-$m'],
  {
    for (final MapEntry(:key, :value) in parameters.entries)
      '$protocol-$key': value,
  },
);

String hhmm(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

QrCode decode(Bundle b, Map<String, Object?> json) =>
    decodeQr(json, b.manifest, b.modules);

/// The selected modules, failing the test if the time needs new instructions.
List<SelectedModule> selectedOrFail(
  Manifest manifest,
  Map<String, Module> modules,
  QrCode scheduling,
  QrCode? discharge,
  tz.TZDateTime appointment,
) => switch (selectedModules(
  manifest,
  modules,
  scheduling,
  discharge,
  appointment,
)) {
  Selected(:final modules) => modules,
  NeedsNewInstructions(:final reason) => fail(
    'Needs new instructions: $reason',
  ),
};

/// An ArgumentError whose invalid value is [moduleId].
Matcher throwsNaming(String moduleId) => throwsA(
  isA<ArgumentError>().having((e) => e.invalidValue, 'invalidValue', moduleId),
);

Matcher needsNew(NewInstructionsReason reason) =>
    isA<NeedsNewInstructions>().having((n) => n.reason, 'reason', reason);

List<String> ids(List<SelectedModule> selected) => [
  for (final s in selected) s.module.moduleId,
];

/// Each entry as (module name without the protocol prefix, step ID, local
/// effect time, or null while pending).
List<(String, String, String?)> rows(String protocol, List<TimelineEntry> t) =>
    [
      for (final e in t)
        (
          e.moduleId.substring(protocol.length + 1),
          e.step.id,
          e.effect?.at.toIso8601String(),
        ),
    ];

/// A timed step at [offset] from [anchor], reminded when it takes effect.
Map<String, Object?> step(String id, String anchor, String offset) => {
  'id': id,
  'type': 'checklist',
  'anchor': anchor,
  'timing': {'kind': 'offset', 'offset': offset},
  'remind': {'kind': 'offset', 'offset': offset, 'defaulted': false},
  'allowNight': false,
  'pastDue': 'doNow',
  'text': id,
};

/// One constructed module with [steps], applying at every appointment time.
List<SelectedModule> wholeDay(List<Map<String, Object?>> steps) => [
  (
    module: parseModule({
      'moduleId': 'constructed',
      'version': 1,
      'appliesWhen': {
        'appointmentTime': {'fromInclusive': '00:00', 'toExclusive': '24:00'},
      },
      'steps': steps,
    }),
    chosen: const {},
  ),
];

/// Each declared parameter of the [ticked] modules at the value [pick] gives.
Map<String, Map<String, int>> picked(
  Bundle b,
  List<String> ticked,
  int Function(ParamRange) pick,
) => {
  for (final id in ticked)
    if (b.modules[id]!.parameters.isNotEmpty)
      id: b.modules[id]!.parameters.map((k, p) => MapEntry(k, pick(p))),
};

/// The module sets the manifest allows for [stage] at [appointment]: one
/// module from each of the stage's groups, with every subset of its ungrouped
/// modules. Above 6 ungrouped modules, only subsets of at most 2 and the full
/// set, since 2^13 subsets at every sample would take too long.
List<List<String>> allowedSets(
  Bundle b,
  SelectedAt stage,
  tz.TZDateTime appointment,
) {
  final m = b.manifest;
  final stageOf = {for (final r in m.optional) r.moduleId: r.selectedAt};
  final grouped = {for (final g in m.exactlyOneOf) ...g.modules};
  final free = [
    for (final r in m.optional)
      if (r.selectedAt == stage && !grouped.contains(r.moduleId)) r.moduleId,
  ];
  final all = (1 << free.length) - 1;
  int bits(int mask) => mask.toRadixString(2).replaceAll('0', '').length;
  var sets = [
    for (var mask = 0; mask <= all; mask++)
      if (free.length <= 6 || bits(mask) <= 2 || mask == all)
        [
          for (var i = 0; i < free.length; i++)
            if (mask & (1 << i) != 0) free[i],
        ],
  ];
  for (final g in m.exactlyOneOf) {
    if (stageOf[g.modules.first] != stage) continue;
    final options = [
      for (final id in g.modules)
        if (g.selectBy == SelectBy.clinician ||
            appliesAt(b.modules[id]!.appliesWhen, appointment))
          id,
    ];
    sets = [
      for (final s in sets)
        for (final o in options) [...s, o],
    ];
  }
  return sets;
}

/// Every allowed selection of every fixture protocol at every publish sample
/// appointment: every 15 minutes inside bookable hours on [publishDates],
/// each parameter at its lowest and then its highest value, without and with
/// each allowed discharge code.
void forEverySelection(
  void Function(
    String protocol,
    List<SelectedModule> selected,
    tz.TZDateTime appointment,
  )
  check,
) {
  for (final dir in protocolDirs()) {
    final protocol = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final b = bundle(protocol);
    final hasDischarge = b.manifest.optional.any(
      (r) => r.selectedAt == SelectedAt.discharge,
    );
    final hasParameters = b.modules.values.any((m) => m.parameters.isNotEmpty);
    final picks = [
      (ParamRange p) => p.min,
      if (hasParameters) (ParamRange p) => p.max,
    ];
    for (final (y, mo, d) in publishDates) {
      for (var minute = 0; minute < 24 * 60; minute += 15) {
        final clock = (hour: minute ~/ 60, minute: minute % 60);
        if (!inRange(clock, b.manifest.bookable)) continue;
        final a = localTime(
          b.manifest.zone,
          y,
          mo,
          d,
          clock.hour,
          clock.minute,
        );
        for (final pick in picks) {
          QrCode qr(SelectedAt stage, List<String> ticked) => decode(
            b,
            codeJson(protocol, stage, ticked, picked(b, ticked, pick)),
          );
          final discharges = [
            null,
            if (hasDischarge)
              for (final s in allowedSets(b, SelectedAt.discharge, a))
                qr(SelectedAt.discharge, s),
          ];
          for (final s in allowedSets(b, SelectedAt.scheduling, a)) {
            final scheduling = qr(SelectedAt.scheduling, s);
            for (final discharge in discharges) {
              check(
                protocol,
                selectedOrFail(b.manifest, b.modules, scheduling, discharge, a),
                a,
              );
            }
          }
        }
      }
    }
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  const scheduling = SelectedAt.scheduling;
  const discharge = SelectedAt.discharge;

  group('decodeQr and selectedModules', () {
    test('15. UMMC scheduling code with the iron hold: base, then the iron '
        'hold; the creation instant is read in the manifest zone', () {
      final b = bundle(umms);
      final qr = decode(b, code(umms, scheduling, ['iron-hold']));
      expect(qr.protocolId, umms);
      expect(qr.protocolVersion, 1);
      expect(qr.stage, scheduling);
      expect(qr.modules, {'$umms-iron-hold'});
      expect(qr.parameters, isEmpty);
      // 14:00 UTC on 2026-11-01 is after that day's fall-back change.
      expect(qr.createdAt.location.name, ny);
      expect(qr.createdAt.toIso8601String(), '2026-11-01T09:00:00.000-0500');
      final selected = selectedOrFail(
        b.manifest,
        b.modules,
        qr,
        null,
        local(ny, 2026, 11, 18, 9),
      );
      expect(ids(selected), ['$umms-base', '$umms-iron-hold']);
      expect(selected[0].chosen, isEmpty);
      expect(selected[1].chosen, isEmpty);
    });

    group('16. a code for another protocol or version is rejected', () {
      for (final (key, value) in const [('protocolId', bmc), ('version', 2)]) {
        test('$key $value', () {
          final json = code(umms, scheduling, [])..[key] = value;
          expect(() => decode(bundle(umms), json), throwsArgumentError);
        });
      }
    });

    group('17. only the manifest optional modules, each once', () {
      for (final (name, modules) in const [
        ('an unknown module', ['warfarin-hold']),
        ('the base module', ['base']),
        ('a duplicate', ['iron-hold', 'iron-hold']),
      ]) {
        test('$name is rejected', () {
          expect(
            () => decode(bundle(umms), code(umms, scheduling, modules)),
            throwsArgumentError,
          );
        });
      }
    });

    group('18. each module only on the code of its selectedAt', () {
      test('a discharge module on a scheduling code is rejected', () {
        expect(
          () => decode(bundle(uw), code(uw, scheduling, ['sedation'])),
          throwsArgumentError,
        );
      });
      test('a scheduling module on a discharge code is rejected', () {
        expect(
          () => decode(bundle(umms), code(umms, discharge, ['iron-hold'])),
          throwsArgumentError,
        );
      });
      test('a code passed in the other stage is rejected', () {
        final b = bundle(uw);
        final s = decode(b, code(uw, scheduling, []));
        final d = decode(b, code(uw, discharge, ['groin-site']));
        final appt = local(la, 2026, 11, 18, 10);
        expect(
          () => selectedModules(b.manifest, b.modules, d, null, appt),
          throwsArgumentError,
        );
        expect(
          () => selectedModules(b.manifest, b.modules, s, s, appt),
          throwsArgumentError,
        );
      });
    });

    group('19. UW discharge code: exactly one insertion site', () {
      for (final site in const ['groin-site', 'arm-site']) {
        test('$site alone is accepted', () {
          expect(decode(bundle(uw), code(uw, discharge, [site])).modules, {
            '$uw-$site',
          });
        });
      }
      for (final modules in const [
        <String>[],
        ['sedation'],
        ['groin-site', 'arm-site'],
      ]) {
        test('$modules is rejected', () {
          expect(
            () => decode(bundle(uw), code(uw, discharge, modules)),
            throwsArgumentError,
          );
        });
      }
    });

    test('20. UW scheduling code needs no insertion site: its group is chosen '
        'at discharge', () {
      final b = bundle(uw);
      final selected = selectedOrFail(
        b.manifest,
        b.modules,
        decode(b, code(uw, scheduling, [])),
        null,
        local(la, 2026, 11, 18, 10),
      );
      expect(ids(selected), ['$uw-base']);
    });

    group('21. Karmanos: the ticked schedule must match the appointment', () {
      final cases = [
        ('am-schedule', 11, 59, true),
        ('am-schedule', 12, 0, false),
        ('pm-schedule', 12, 0, true),
        ('pm-schedule', 11, 59, false),
      ];
      for (final (module, hour, minute, accepted) in cases) {
        test('$module at ${hhmm(hour, minute)}: '
            '${accepted ? 'accepted' : 'rejected'}', () {
          final b = bundle(karmanos);
          SelectionResult select() => selectedModules(
            b.manifest,
            b.modules,
            decode(b, code(karmanos, scheduling, [module])),
            null,
            local(detroit, 2026, 11, 18, hour, minute),
          );
          expect(
            select(),
            accepted
                ? isA<Selected>().having((r) => ids(r.modules), 'modules', [
                    '$karmanos-base',
                    '$karmanos-$module',
                  ])
                : needsNew(NewInstructionsReason.outsideAppliesWhen),
          );
        });
      }
    });

    group('22. Karmanos: exactly one schedule is ticked', () {
      for (final modules in const [
        <String>[],
        ['am-schedule', 'pm-schedule'],
      ]) {
        test('$modules is rejected', () {
          expect(
            () => decode(bundle(karmanos), code(karmanos, scheduling, modules)),
            throwsArgumentError,
          );
        });
      }
    });

    test('23. every subset of the 13 BMC optional modules is accepted, base '
        'first, then manifest order', () {
      final b = bundle(bmc);
      final optional = [for (final r in b.manifest.optional) r.moduleId];
      expect(optional, hasLength(13));
      final appt = local(ny, 2026, 11, 18, 10);
      final failures = Failures();
      for (var mask = 0; mask < 1 << optional.length; mask++) {
        final ticked = [
          for (var i = 0; i < optional.length; i++)
            if (mask & (1 << i) != 0) optional[i],
        ];
        final params = picked(b, ticked, (p) => p.min);
        final selected = selectedOrFail(
          b.manifest,
          b.modules,
          decode(
            b,
            codeJson(bmc, scheduling, ticked.reversed.toList(), params),
          ),
          null,
          appt,
        );
        failures.check(
          ids(selected).join(',') == ['$bmc-base', ...ticked].join(',') &&
              selected.every(
                (s) =>
                    (params[s.module.moduleId] ?? const {}).toString() ==
                    s.chosen.toString(),
              ),
          () => '$ticked gave ${ids(selected)}',
        );
      }
      failures.expectNone();
    });

    group('24. parameter values: BMC P2Y12 hold, holdDays 5 to 7', () {
      for (final days in const [5, 7]) {
        test('holdDays $days is accepted and carried to the selection', () {
          final b = bundle(bmc);
          final qr = decode(
            b,
            code(
              bmc,
              scheduling,
              ['p2y12-hold'],
              {
                'p2y12-hold': {'holdDays': days},
              },
            ),
          );
          expect(qr.parameters, {
            '$bmc-p2y12-hold': {'holdDays': days},
          });
          final selected = selectedOrFail(
            b.manifest,
            b.modules,
            qr,
            null,
            local(ny, 2026, 11, 18, 10),
          );
          expect(selected.last.chosen, {'holdDays': days});
        });
      }
      final rejected =
          <(String, List<String>, Map<String, Map<String, Object?>>)>[
            ('missing for the module', ['p2y12-hold'], {}),
            ('holdDays missing', ['p2y12-hold'], {'p2y12-hold': {}}),
            (
              'undeclared holdWeeks',
              ['p2y12-hold'],
              {
                'p2y12-hold': {'holdDays': 5, 'holdWeeks': 1},
              },
            ),
            (
              'holdDays 4, below the range',
              ['p2y12-hold'],
              {
                'p2y12-hold': {'holdDays': 4},
              },
            ),
            (
              'holdDays 8, above the range',
              ['p2y12-hold'],
              {
                'p2y12-hold': {'holdDays': 8},
              },
            ),
            (
              'given for the unticked SGLT2 hold',
              ['p2y12-hold'],
              {
                'p2y12-hold': {'holdDays': 5},
                'sglt2-hold': {'holdDays': 3},
              },
            ),
            (
              'given for the iron hold, which declares none',
              ['iron-hold'],
              {
                'iron-hold': {'holdDays': 5},
              },
            ),
          ];
      for (final (name, modules, params) in rejected) {
        test('$name: rejected', () {
          expect(
            () => decode(bundle(bmc), code(bmc, scheduling, modules, params)),
            throwsArgumentError,
          );
        });
      }
      // Not 5.0: compiled to JavaScript it is an int, and the preview must agree
      // with the app.
      for (final value in const <Object?>[5.5, '5', null]) {
        test('holdDays $value is not an integer: malformed', () {
          expect(
            () => decode(
              bundle(bmc),
              code(
                bmc,
                scheduling,
                ['p2y12-hold'],
                {
                  'p2y12-hold': {'holdDays': value},
                },
              ),
            ),
            throwsFormatException,
          );
        });
      }
    });

    group('25. an appointment outside the manifest zone is rejected', () {
      // Detroit keeps New York's offsets, so only the zone name tells them
      // apart.
      for (final zone in const [detroit, 'America/Chicago']) {
        test(zone, () {
          final b = bundle(umms);
          expect(
            () => selectedModules(
              b.manifest,
              b.modules,
              decode(b, code(umms, scheduling, [])),
              null,
              local(zone, 2026, 11, 18, 9),
            ),
            throwsArgumentError,
          );
        });
      }
    });

    test('26. an appointment outside the base appliesWhen needs new '
        'instructions, even inside bookable hours', () {
      final b = bundle(umms);
      final base = fixture('$umms/base.json');
      final times =
          (base['appliesWhen']! as Map<String, Object?>)['appointmentTime']!
              as Map<String, Object?>;
      // Publishing rejects bookable hours outside the base appliesWhen
      // (fixtures/invalid/bookable-outside-base-umms); this checks the phone
      // still refuses such an appointment if one gets through.
      times['fromInclusive'] = '08:00';
      final modules = {...b.modules, '$umms-base': parseModule(base)};
      final qr = decode(b, code(umms, scheduling, []));
      SelectionResult at(int hour, int minute) => selectedModules(
        b.manifest,
        modules,
        qr,
        null,
        local(ny, 2026, 11, 18, hour, minute),
      );
      // Bookable hours are 07:00 to 12:00.
      expect(at(7, 30), needsNew(NewInstructionsReason.outsideAppliesWhen));
      expect(ids((at(8, 0) as Selected).modules), ['$umms-base']);
    });

    group(
      '32. an appointment outside bookableHours needs new instructions',
      () {
        SelectionResult select(Manifest manifest, int hour, int minute) {
          final b = bundle(bmc);
          return selectedModules(
            manifest,
            b.modules,
            decode(b, code(bmc, scheduling, [])),
            null,
            local(ny, 2026, 11, 18, hour, minute),
          );
        }

        // A null range keeps BMC's own bookable hours, 07:00 to 17:00.
        for (final (label, range, cases) in const [
          (
            'BMC, 07:00 to 17:00',
            null,
            [(6, 59, false), (7, 0, true), (16, 59, true), (17, 0, false)],
          ),
          (
            '22:00 to 02:00, wrapping midnight',
            {'from': '22:00', 'to': '02:00'},
            [(21, 59, false), (22, 0, true), (1, 59, true), (2, 0, false)],
          ),
          (
            '07:30 to 16:45, minutes count',
            {'from': '07:30', 'to': '16:45'},
            [(7, 29, false), (7, 30, true), (16, 44, true), (16, 45, false)],
          ),
        ]) {
          for (final (hour, minute, accepted) in cases) {
            test('$label: ${hhmm(hour, minute)} '
                '${accepted ? 'accepted' : 'rejected'}', () {
              final json = fixture('$bmc/protocol.json');
              if (range != null) json['bookableHours'] = {...range};
              final manifest = parseManifest(json);
              final result = select(manifest, hour, minute);
              if (accepted) {
                expect(ids((result as Selected).modules), ['$bmc-base']);
              } else {
                expect(
                  result,
                  needsNew(NewInstructionsReason.outsideBookableHours),
                );
              }
            });
          }
        }
      },
    );

    group('34. a malformed code is a FormatException', () {
      for (final key in const [
        'protocolId',
        'version',
        'stage',
        'modules',
        'parameters',
        'createdAt',
      ]) {
        test('without $key', () {
          final json = code(umms, scheduling, [])..remove(key);
          expect(() => decode(bundle(umms), json), throwsFormatException);
        });
      }
      for (final (key, value) in const <(String, Object?)>[
        ('stage', 'admission'),
        ('modules', 'iron-hold'),
        ('modules', [1]),
        ('parameters', 'none'),
        ('createdAt', '2026-11-01T14:00:00'),
        ('createdAt', '2026-11-01T09:00:00-05:00'),
        ('createdAt', 'yesterday'),
      ]) {
        test('$key $value', () {
          final json = code(umms, scheduling, [])..[key] = value;
          expect(() => decode(bundle(umms), json), throwsFormatException);
        });
      }
    });

    // UMMC bookable hours are 07:00 to 12:00. A broken bundle is rejected
    // even at 13:00, where the time alone would need new instructions.
    const hours = [9, 13];

    group('36. a base module with parameters is rejected', () {
      for (final hour in hours) {
        test('at ${hhmm(hour, 0)}', () {
          final b = bundle(umms);
          // Publishing rejects this (fixtures/invalid/base-parameters-bmc);
          // the codes carry no values for the base, so the phone refuses it.
          final base = fixture('$umms/base.json')
            ..['parameters'] = {
              'holdDays': {'min': 5, 'max': 7, 'unit': 'days'},
            };
          final modules = {...b.modules, '$umms-base': parseModule(base)};
          expect(
            () => selectedModules(
              b.manifest,
              modules,
              decode(b, code(umms, scheduling, [])),
              null,
              local(ny, 2026, 11, 18, hour),
            ),
            throwsNaming('$umms-base'),
          );
        });
      }
    });

    group('37. a module the manifest lists but the bundle lacks is rejected, '
        'naming it', () {
      Map<String, Module> without(String name) =>
          {...bundle(umms).modules}..remove('$umms-$name');

      test('decodeQr, the ticked iron hold', () {
        final b = bundle(umms);
        expect(
          () => decodeQr(
            code(umms, scheduling, ['iron-hold']),
            b.manifest,
            without('iron-hold'),
          ),
          throwsNaming('$umms-iron-hold'),
        );
      });
      for (final name in const ['base', 'iron-hold']) {
        for (final hour in hours) {
          test('selectedModules, the $name at ${hhmm(hour, 0)}', () {
            final b = bundle(umms);
            expect(
              () => selectedModules(
                b.manifest,
                without(name),
                decode(b, code(umms, scheduling, ['iron-hold'])),
                null,
                local(ny, 2026, 11, 18, hour),
              ),
              throwsNaming('$umms-$name'),
            );
          });
        }
      }
    });
  });

  group('timelineOf', () {
    // 2026-11-18 is after the fall-back change, so New York is at -05:00.
    List<TimelineEntry> bmcTimeline(List<String> ticked) {
      final b = bundle(bmc);
      final full = [for (final m in ticked) '$bmc-$m'];
      final appt = local(ny, 2026, 11, 18, 10);
      final selected = selectedOrFail(
        b.manifest,
        b.modules,
        decode(
          b,
          codeJson(bmc, scheduling, full, picked(b, full, (p) => p.min)),
        ),
        null,
        appt,
      );
      return timelineOf(selected, appointment(appt));
    }

    const everyBmcModule = [
      'iron-hold',
      'warfarin-hold',
      'doac-hold',
      'lmwh-hold',
      'p2y12-hold',
      'ticlid-hold',
      'continue-medicines',
      'insulin-half-dose',
      'diabetes-pills',
      'insulin-pump',
      'sglt2-hold',
      'glp1-weekly-hold',
      'glp1-daily-hold',
    ];

    const bmcRows = [
      ('iron-hold', 'iron', '2026-11-11T00:00:00.000-0500'),
      ('ticlid-hold', 'ticlid', '2026-11-11T00:00:00.000-0500'),
      ('glp1-weekly-hold', 'glp1-weekly', '2026-11-11T00:00:00.000-0500'),
      ('warfarin-hold', 'warfarin', '2026-11-13T00:00:00.000-0500'),
      ('p2y12-hold', 'p2y12', '2026-11-13T00:00:00.000-0500'),
      ('base', 'low-fiber', '2026-11-15T00:00:00.000-0500'),
      ('sglt2-hold', 'sglt2', '2026-11-15T00:00:00.000-0500'),
      ('base', 'mix', '2026-11-16T00:00:00.000-0500'),
      ('doac-hold', 'doac', '2026-11-16T00:00:00.000-0500'),
      ('base', 'clear-liquids', '2026-11-17T00:00:00.000-0500'),
      ('base', 'med-sheet-again', '2026-11-17T00:00:00.000-0500'),
      ('lmwh-hold', 'lmwh', '2026-11-17T00:00:00.000-0500'),
      ('insulin-half-dose', 'half-dose', '2026-11-17T00:00:00.000-0500'),
      ('base', 'dose1', '2026-11-17T18:00:00.000-0500'),
      ('diabetes-pills', 'skip-pills', '2026-11-18T00:00:00.000-0500'),
      ('glp1-daily-hold', 'glp1-daily', '2026-11-18T00:00:00.000-0500'),
      ('base', 'dose2', '2026-11-18T08:00:00.000-0500'),
      ('base', 'npo', '2026-11-18T08:00:00.000-0500'),
      ('base', 'arrive', '2026-11-18T09:00:00.000-0500'),
    ];

    test('27. BMC, every module, 2026-11-18 10:00: sorted by effect time; '
        'ties in module order, then step order', () {
      expect(rows(bmc, bmcTimeline(everyBmcModule)), bmcRows);
    });

    test('28. ties follow the manifest, not the order on the code', () {
      expect(rows(bmc, bmcTimeline(everyBmcModule.reversed.toList())), bmcRows);
    });

    group('29. a pending step sorts with its unknown anchor at the '
        'appointment and still shows as pending', () {
      // File order is the reverse of the expected timeline order.
      List<SelectedModule> selected() => wholeDay([
        step('appointment+30m', 'appointment', 'PT30M'),
        step('at-discharge', 'discharge', 'PT0H'),
        step('appointment-1h', 'appointment', '-PT1H'),
        step('arrival-2h', 'arrival', '-PT2H'),
      ]);
      List<(String, String?)> order(List<TimelineEntry> t) => [
        for (final e in t) (e.step.id, e.effect?.at.toIso8601String()),
      ];

      test('arrival and discharge unknown: pending at 08:00 and 10:00', () {
        final appt = local(ny, 2026, 11, 18, 10);
        expect(order(timelineOf(selected(), appointment(appt))), [
          ('arrival-2h', null),
          ('appointment-1h', '2026-11-18T09:00:00.000-0500'),
          ('at-discharge', null),
          ('appointment+30m', '2026-11-18T10:30:00.000-0500'),
        ]);
      });

      test('arrival 08:30 and discharge 12:00 entered: real times', () {
        final appt = local(ny, 2026, 11, 18, 10);
        final anchors = (
          appointment: appt,
          arrival: local(ny, 2026, 11, 18, 8, 30),
          discharge: local(ny, 2026, 11, 18, 12),
        );
        expect(order(timelineOf(selected(), anchors)), [
          ('arrival-2h', '2026-11-18T06:30:00.000-0500'),
          ('appointment-1h', '2026-11-18T09:00:00.000-0500'),
          ('appointment+30m', '2026-11-18T10:30:00.000-0500'),
          ('at-discharge', '2026-11-18T12:00:00.000-0500'),
        ]);
      });

      test('MSK, arrival unknown: npo is pending, after stop-eating', () {
        final b = bundle(msk);
        final appt = local(ny, 2026, 11, 18, 10);
        final chosen = selectedOrFail(
          b.manifest,
          b.modules,
          decode(b, code(msk, scheduling, [])),
          null,
          appt,
        );
        expect(rows(msk, timelineOf(chosen, appointment(appt))), [
          ('base', 'no-call', '2026-11-17T19:00:00.000-0500'),
          ('base', 'stop-eating', '2026-11-18T00:00:00.000-0500'),
          ('base', 'npo', null),
        ]);
      });
    });

    test("35. ties keep step order past 32 entries, where Dart's List.sort "
        'stops being stable', () {
      const offsets = ['-PT2H', '-PT1H', 'PT0H'];
      final ids = [for (var i = 0; i < 40; i++) 'step-$i'];
      final t = timelineOf(
        wholeDay([
          for (var i = 0; i < 40; i++)
            step(ids[i], 'appointment', offsets[i % 3]),
        ]),
        appointment(local(ny, 2026, 11, 18, 10)),
      );
      expect(
        [for (final e in t) e.step.id],
        [
          for (var k = 0; k < 3; k++)
            for (var i = k; i < 40; i += 3) ids[i],
        ],
      );
    });

    test('30. UW: the discharge code adds its modules once scanned', () {
      final b = bundle(uw);
      final appt = local(la, 2026, 11, 18, 10);
      final s = decode(b, code(uw, scheduling, []));
      final d = decode(b, code(uw, discharge, ['groin-site', 'sedation']));
      final before = selectedOrFail(b.manifest, b.modules, s, null, appt);
      expect(ids(before), ['$uw-base']);
      final after = selectedOrFail(b.manifest, b.modules, s, d, appt);
      expect(ids(after), ['$uw-base', '$uw-sedation', '$uw-groin-site']);
      final anchors = (
        appointment: appt,
        arrival: null,
        discharge: local(la, 2026, 11, 18, 15),
      );
      // 2026-11-18 is after the fall-back change: Los Angeles is at -08:00.
      expect(rows(uw, timelineOf(after, anchors)), [
        ('base', 'no-call', '2026-11-15T00:00:00.000-0800'),
        ('base', 'no-caffeine', '2026-11-17T10:00:00.000-0800'),
        ('base', 'no-high-fat', '2026-11-18T02:00:00.000-0800'),
        ('base', 'npo', '2026-11-18T04:00:00.000-0800'),
        ('base', 'arrive', '2026-11-18T10:00:00.000-0800'),
        ('base', 'no-nsaids', '2026-11-18T15:00:00.000-0800'),
        ('sedation', 'after-sedation', '2026-11-18T15:00:00.000-0800'),
        ('groin-site', 'first-week', '2026-11-18T15:00:00.000-0800'),
        ('groin-site', 'first-day', '2026-11-19T15:00:00.000-0800'),
      ]);
    });

    test('31. every fixture protocol, every allowed selection, every publish '
        'sample: each timed step once, sorted, ties in module order, and '
        'pending exactly when its anchor is unknown', () {
      final failures = Failures();
      final seen = <String>{};
      forEverySelection((protocol, selected, a) {
        seen.add(protocol);
        final input = [
          for (final s in selected)
            for (final step in timedSteps(s.module, s.chosen))
              '${s.module.moduleId}/${step.id}',
        ];
        for (final Anchors anchors in [
          appointment(a),
          (
            appointment: a,
            arrival: a.subtract(const Duration(hours: 1)),
            discharge: a.add(const Duration(hours: 3)),
          ),
        ]) {
          final t = timelineOf(selected, anchors);
          final got = [for (final e in t) '${e.moduleId}/${e.step.id}'];
          String where() => '$protocol at $a, $anchors: $got';
          failures.check(
            (List.of(got)..sort()).join() == (List.of(input)..sort()).join(),
            where,
          );
          int key(TimelineEntry e) => effectOf(e.step.anchor, e.step.timing, (
            appointment: a,
            arrival: anchors.arrival ?? a,
            discharge: anchors.discharge ?? a,
          ))!.at.millisecondsSinceEpoch;
          for (var i = 0; i < t.length; i++) {
            final real = effectOf(t[i].step.anchor, t[i].step.timing, anchors);
            failures.check(
              t[i].effect?.at.millisecondsSinceEpoch ==
                      real?.at.millisecondsSinceEpoch &&
                  t[i].effect?.until?.millisecondsSinceEpoch ==
                      real?.until?.millisecondsSinceEpoch,
              where,
            );
            if (i == 0) continue;
            final (k0, k1) = (key(t[i - 1]), key(t[i]));
            failures.check(
              k0 < k1 ||
                  (k0 == k1 &&
                      input.indexOf(got[i - 1]) < input.indexOf(got[i])),
              where,
            );
          }
        }
      });
      expect(seen, {umms, bmc, karmanos, uw, msk, ccf});
      failures.expectNone();
    });

    group('33. liquids stop before the procedure', () {
      test('every protocol but $noStopDrinking, every allowed selection, '
          'every publish sample, arrival at the appointment: an npo step '
          'takes effect before the appointment', () {
        final failures = Failures();
        final seen = <String>{};
        forEverySelection((protocol, selected, a) {
          if (noStopDrinking.contains(protocol)) return;
          seen.add(protocol);
          final npo = {
            for (final s in selected)
              for (final j in s.module.steps)
                if (j['type'] == 'npo') '${s.module.moduleId}/${j['id']}',
          };
          final t = timelineOf(selected, (
            appointment: a,
            arrival: a,
            discharge: null,
          ));
          failures.check(
            t.any(
              (e) =>
                  npo.contains('${e.moduleId}/${e.step.id}') &&
                  e.effect != null &&
                  e.effect!.at.isBefore(a),
            ),
            () => '$protocol at $a: ${ids(selected)}',
          );
        });
        expect(seen, {bmc, karmanos, uw, msk, ccf});
        failures.expectNone();
      });

      test('$noStopDrinking still has no npo step; take it out of '
          'noStopDrinking once it has one', () {
        for (final protocol in noStopDrinking) {
          final types = [
            for (final m in bundle(protocol).modules.values)
              for (final s in m.steps) s['type'],
          ];
          expect(types, isNot(contains('npo')), reason: protocol);
        }
      });
    });
  });
}
