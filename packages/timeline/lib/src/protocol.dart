import 'package:timezone/timezone.dart' as tz;

import 'clock.dart';
import 'past_due.dart';
import 'step.dart';
import 'timing.dart';

/// Minutes after local midnight, from inclusive to exclusive; [to] may be
/// 1440, written "24:00".
typedef MinuteRange = ({int from, int to});

enum SelectedAt { scheduling, discharge }

enum SelectBy { appointmentTime, clinician }

/// A module as the manifest lists it. [selectedAt] is null for the base.
typedef ModuleRef = ({
  String moduleId,
  int version,
  String sha256,
  SelectedAt? selectedAt,
});

typedef Group = ({SelectBy selectBy, List<String> modules});

/// The department defaults the calculator reads; the rest are for authoring.
typedef DepartmentDefaults = ({
  ({int hour, int minute}) evening,
  QuietHours quiet,
});

typedef Manifest = ({
  String protocolId,
  int version,
  tz.Location zone,
  DepartmentDefaults defaults,
  QuietHours bookable,
  ModuleRef base,
  List<ModuleRef> optional,
  List<Group> exactlyOneOf,
});

typedef ParamRange = ({int min, int max, String unit});

/// A module's own fields. Its steps stay JSON until the parameter values are
/// known, since a parameter stands in for a day number.
typedef Module = ({
  String moduleId,
  int version,
  MinuteRange appliesWhen,
  Map<String, ParamRange> parameters,
  List<Map<String, Object?>> steps,
});

Manifest parseManifest(Map<String, Object?> json) => switch (json) {
  {
    'protocolId': final String protocolId,
    'version': final int version,
    'timezone': final String zone,
    'departmentDefaults': {
      'eveningReminder': final String evening,
      'quietHours': final Object? quiet,
    },
    'bookableHours': final Object? bookable,
    'baseModule': final Object? base,
    'optionalModules': final List<Object?> optional,
    'allowedCombinations': {
      'rule': 'anySubset',
      'exactlyOneOf': final List<Object?> groups,
    },
  } =>
    (
      protocolId: protocolId,
      version: version,
      zone: _location(zone),
      defaults: (evening: parseClockTime(evening), quiet: _clockRange(quiet)),
      bookable: _clockRange(bookable),
      base: _moduleRef(base, base: true),
      optional: [for (final ref in optional) _moduleRef(ref, base: false)],
      exactlyOneOf: [for (final group in groups) _group(group)],
    ),
  _ => throw FormatException('Not a manifest', json),
};

tz.Location _location(String name) {
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    throw FormatException('Not an IANA time zone', name);
  }
}

QuietHours _clockRange(Object? json) => switch (json) {
  {'from': final String from, 'to': final String to} => (
    from: parseClockTime(from),
    to: parseClockTime(to),
  ),
  _ => throw FormatException('Not a clock range', json),
};

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

ModuleRef _moduleRef(Object? json, {required bool base}) => switch (json) {
  {
    'moduleId': final String moduleId,
    'version': final int version,
    'sha256': final String sha256,
  }
      when _sha256.hasMatch(sha256) =>
    (
      moduleId: moduleId,
      version: version,
      sha256: sha256,
      selectedAt: base ? null : _enum(SelectedAt.values, json['selectedAt']),
    ),
  _ => throw FormatException('Not a module reference', json),
};

Group _group(Object? json) => switch (json) {
  {'selectBy': final selectBy, 'modules': final List<Object?> modules} => (
    selectBy: _enum(SelectBy.values, selectBy),
    modules: [
      for (final m in modules)
        m is String ? m : throw FormatException('Not a module ID', m),
    ],
  ),
  _ => throw FormatException('Not an exactlyOneOf group', json),
};

T _enum<T extends Enum>(List<T> values, Object? name) =>
    values.asNameMap()[name] ??
    (throw FormatException('Not one of $values', name));

Module parseModule(Map<String, Object?> json) {
  // The time zone is written only in the manifest.
  if (json.containsKey('timezone')) {
    throw FormatException('A module has no time zone', json['timezone']);
  }
  return switch (json) {
    {
      'moduleId': final String moduleId,
      'version': final int version,
      'appliesWhen': {
        'appointmentTime': {
          'fromInclusive': final String from,
          'toExclusive': final String to,
        },
      },
      'steps': final List<Object?> steps,
    } =>
      (
        moduleId: moduleId,
        version: version,
        appliesWhen: (
          from: _minutes(parseClockTime(from)),
          to: to == '24:00' ? _day : _minutes(parseClockTime(to)),
        ),
        parameters: _params(json),
        steps: [
          for (final s in steps)
            s is Map<String, Object?>
                ? s
                : throw FormatException('Not a step', s),
        ],
      ),
    _ => throw FormatException('Not a module', json),
  };
}

const _day = 24 * 60;

int _minutes(({int hour, int minute}) clock) => clock.hour * 60 + clock.minute;

/// A module without parameters leaves the field out; an explicit null is
/// malformed, like any other value that isn't an object.
Map<String, ParamRange> _params(Map<String, Object?> module) =>
    switch (module['parameters']) {
      _ when !module.containsKey('parameters') => const {},
      final Map<String, Object?> params => {
        for (final MapEntry(:key, :value) in params.entries) key: _param(value),
      },
      final other => throw FormatException('Not a parameter list', other),
    };

ParamRange _param(Object? json) => switch (json) {
  {'min': final int min, 'max': final int max, 'unit': final String unit} => (
    min: min,
    max: max,
    unit: unit,
  ),
  _ => throw FormatException('Not a parameter declaration', json),
};

/// The module's timed steps, with [chosen] parameter values; untimed
/// checklist and reference items are left out.
List<TimedStep> timedSteps(Module module, Map<String, int> chosen) {
  final declared = {
    for (final MapEntry(:key, value: p) in module.parameters.entries)
      key: {'min': p.min, 'max': p.max, 'unit': p.unit},
  };
  int day(Object? d) => resolveDay(d, declared, chosen);
  return [
    for (final s in module.steps)
      if (s.containsKey('timing'))
        _timedStep(s, day)
      // A timed field without a timing means the timing was lost; dropping the
      // step as untimed would take it off the timeline unnoticed.
      else if (_timedOnly.any(s.containsKey))
        throw FormatException('A step without timing has timed fields', s),
  ];
}

const _timedOnly = ['anchor', 'remind', 'allowNight', 'pastDue'];

TimedStep _timedStep(Map<String, Object?> json, int Function(Object?) day) =>
    switch (json) {
      {
        'id': final String id,
        'anchor': final anchor,
        'timing': final Map<String, Object?> timing,
        'remind': final Map<String, Object?> remind,
        'allowNight': final bool allowNight,
      } =>
        (
          id: id,
          anchor: _enum(Anchor.values, anchor),
          timing: parseTiming(timing, day),
          remind: parseRemind(remind, day),
          allowNight: allowNight,
          pastDue: parsePastDue(json['pastDue']),
        ),
      _ => throw FormatException('Not a timed step', json),
    };

/// Whether [appointment]'s local clock time is in [range].
bool appliesAt(MinuteRange range, tz.TZDateTime appointment) {
  final clock = _minutes((hour: appointment.hour, minute: appointment.minute));
  return range.from <= clock && clock < range.to;
}
