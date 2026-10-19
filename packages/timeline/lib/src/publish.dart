import 'package:timezone/timezone.dart' as tz;

import 'bundle.dart';
import 'calendar.dart';
import 'clock.dart';
import 'protocol.dart';
import 'reminder.dart';
import 'step.dart';
import 'timing.dart';

/// Calendar dates from [from] through [through], both included, as UTC
/// midnights. The caller passes the publish date and the review date; the
/// check reads no clock.
typedef DateRange = ({DateTime from, DateTime through});

enum PublishReason {
  quietHours,
  afterEffect,
  conflictingCutoffs,
  noStopDrinking,
  outsideBaseAppliesWhen,
  noAllowedSet,
}

/// A timed step and the parameter values it was computed with.
typedef StepRef = ({String moduleId, String stepId, Map<String, int> chosen});

/// One way publishing fails, at the sampled [sample] anchors. [steps] holds
/// the step, or both steps of a conflicting cutoff, and is empty for
/// noStopDrinking, outsideBaseAppliesWhen and noAllowedSet.
///
/// [selection] is empty except for noStopDrinking and
/// outsideBaseAppliesWhen. For outsideBaseAppliesWhen it
/// is the base module alone. For noStopDrinking it names the npo-free
/// modules: the base, then, in manifest order, each scheduling module that
/// applies at [sample] and has no npo step taking effect before the
/// appointment, with the arrival at the appointment. noStopDrinking is one
/// failure per sample, and [failingSets] counts the scheduling sets allowed
/// at [sample] made only of those modules; it is null for every other
/// reason. [stage] names the stage with no allowed set for noAllowedSet, one
/// failure per stage and sample, and is null for every other reason.
typedef PublishFailure = ({
  PublishReason reason,
  List<StepRef> steps,
  List<String> selection,
  int? failingSets,
  SelectedAt? stage,
  Anchors sample,
});

/// The conflict check at publish (docs/spec.md, Changeability) on unsigned
/// content: the bytes the approval service is about to sign.
///
/// Returns every failure, empty when the content may be signed. Content that
/// can't be checked returns nothing and throws instead: [BundleRefused] with
/// moduleNotMatched (naming the listed module) when no file has a listed
/// module's hash, unlistedFile when a file matches no listed module, and
/// moduleMismatch when a matched file's id or version differs from its
/// listing; FormatException for content that doesn't parse. A hash mismatch
/// is never a [PublishFailure].
List<PublishFailure> publishCheck({
  required List<int> manifest,
  required List<List<int>> modules,
  required DateRange dates,
}) {
  final parsed = manifestOf(manifest);
  final byId = matchModules(parsed, modules);
  final base = parsed.base.moduleId;
  final stageOf = {for (final r in parsed.optional) r.moduleId: r.selectedAt};
  // In module order: the base, then the optional modules in manifest order.
  final variants = {
    for (final id in [base, ...stageOf.keys]) id: _variants(byId[id]!),
  };
  final failures = <PublishFailure>[];

  // The allowed sets depend only on the appointment's clock time, and BMC
  // has 8192 of them.
  final setsByClock = <int, Map<SelectedAt, List<Set<String>>>>{};
  final selectableByClock = <int, Set<String>>{};

  void judgeReminder(_Variant v, TimedStep step, Anchors sample) {
    for (final reason in _reminderFailures(
      step,
      sample,
      parsed.defaults.quiet,
    )) {
      failures.add((
        reason: reason,
        steps: [_ref(v, step)],
        selection: const [],
        failingSets: null,
        stage: null,
        sample: sample,
      ));
    }
  }

  /// Adds a conflict for each two of [npo] selected together, with the
  /// allowed sets of some entry of [setsAt], whose effects differ at a sample
  /// [samplesOf] gives; it is told whether either step counts from the
  /// arrival.
  void judgeCutoffs(
    List<(_Variant, TimedStep)> npo,
    Iterable<Map<SelectedAt, List<Set<String>>>> setsAt,
    List<Anchors> Function(bool byArrival) samplesOf,
  ) {
    // The base, which has no stage, goes with every module, and a
    // scheduling module with every discharge module: they are ticked on
    // separate codes.
    bool together(String a, String b) =>
        stageOf[a] != stageOf[b] ||
        setsAt.any(
          (sets) =>
              sets[stageOf[a]]!.any((s) => s.contains(a) && s.contains(b)),
        );
    for (var i = 0; i < npo.length; i++) {
      for (var j = i + 1; j < npo.length; j++) {
        final (va, a) = npo[i];
        final (vb, b) = npo[j];
        // A module is selected with one choice of its parameter values.
        final selectedTogether = va.moduleId == vb.moduleId
            ? identical(va, vb)
            : together(va.moduleId, vb.moduleId);
        if (!selectedTogether) continue;
        final byArrival =
            a.anchor == Anchor.arrival || b.anchor == Anchor.arrival;
        for (final sample in samplesOf(byArrival)) {
          final at = effectOf(a.anchor, a.timing, sample)!.at;
          if (!at.isAtSameMomentAs(effectOf(b.anchor, b.timing, sample)!.at)) {
            failures.add((
              reason: PublishReason.conflictingCutoffs,
              steps: [_ref(va, a), _ref(vb, b)],
              selection: const [],
              failingSets: null,
              stage: null,
              sample: sample,
            ));
          }
        }
      }
    }
  }

  final (appointment: appointmentDates, discharge: dischargeDates) =
      sampleDates(parsed, byId, dates);
  for (final date in appointmentDates) {
    for (final t in bookableSamples(parsed.zone, date, parsed.bookable)) {
      final Anchors atAppointment = (
        appointment: t,
        arrival: null,
        discharge: null,
      );
      if (!appliesAt(byId[base]!.appliesWhen, t)) {
        // The app refuses this time, so no timeline here is judged.
        failures.add((
          reason: PublishReason.outsideBaseAppliesWhen,
          steps: const [],
          selection: [base],
          failingSets: null,
          stage: null,
          sample: atAppointment,
        ));
        continue;
      }
      final clock = t.hour * 60 + t.minute;
      final sets = setsByClock.putIfAbsent(
        clock,
        () => {
          for (final stage in SelectedAt.values)
            stage: allowedSets(parsed, byId, stage, t),
        },
      );
      for (final MapEntry(key: stage, value: stageSets) in sets.entries) {
        // No code of this stage can be valid at this time.
        if (stageSets.isEmpty) {
          failures.add((
            reason: PublishReason.noAllowedSet,
            steps: const [],
            selection: const [],
            failingSets: null,
            stage: stage,
            sample: atAppointment,
          ));
        }
      }
      final scheduling = sets[SelectedAt.scheduling]!;
      final selectable = selectableByClock.putIfAbsent(
        clock,
        () => {
          base,
          for (final stageSets in sets.values)
            for (final s in stageSets) ...s,
        },
      );
      final List<Anchors> arrivals = [
        for (final a in arrivalSamples(t))
          (appointment: t, arrival: a, discharge: null),
      ];

      final npo = <(_Variant, TimedStep)>[];
      for (final MapEntry(key: id, value: vs) in variants.entries) {
        if (!selectable.contains(id)) continue;
        for (final v in vs) {
          for (final step in v.steps) {
            if (step.anchor == Anchor.discharge) continue;
            for (final sample
                in step.anchor == Anchor.arrival ? arrivals : [atAppointment]) {
              judgeReminder(v, step, sample);
            }
            if (v.npo.contains(step.id)) npo.add((v, step));
          }
        }
      }

      judgeCutoffs(npo, [
        sets,
      ], (byArrival) => byArrival ? arrivals : [atAppointment]);

      final Anchors arrivalAtAppointment = (
        appointment: t,
        arrival: t,
        discharge: null,
      );
      // Every choice of a module's parameter values must stop drinking.
      bool stopsDrinking(String id) => variants[id]!.every(
        (v) => v.steps.any(
          (s) =>
              v.npo.contains(s.id) &&
              s.anchor != Anchor.discharge &&
              effectOf(
                s.anchor,
                s.timing,
                arrivalAtAppointment,
              )!.at.isBefore(t),
        ),
      );
      if (stopsDrinking(base)) continue;
      final npoFree = [
        base,
        for (final r in parsed.optional)
          if (r.selectedAt == SelectedAt.scheduling &&
              appliesAt(byId[r.moduleId]!.appliesWhen, t) &&
              !stopsDrinking(r.moduleId))
            r.moduleId,
      ];
      final failing = scheduling.where((s) => s.every(npoFree.contains)).length;
      if (failing > 0) {
        failures.add((
          reason: PublishReason.noStopDrinking,
          steps: const [],
          selection: npoFree,
          failingSets: failing,
          stage: null,
          sample: arrivalAtAppointment,
        ));
      }
    }
  }

  // A module's appliesWhen depends on an appointment the discharge samples
  // don't fix, so every module's discharge steps are judged, and two modules
  // count as selected together if any bookable time allows them together.
  final dischargeNpo = [
    for (final vs in variants.values)
      for (final v in vs)
        for (final step in v.steps)
          if (step.anchor == Anchor.discharge && v.npo.contains(step.id))
            (v, step),
  ];
  for (final date in dischargeDates) {
    final day = daySamples(parsed.zone, date);
    for (final d in day) {
      final Anchors sample = (
        appointment: day.first,
        arrival: null,
        discharge: d,
      );
      for (final vs in variants.values) {
        for (final v in vs) {
          for (final step in v.steps) {
            if (step.anchor == Anchor.discharge) judgeReminder(v, step, sample);
          }
        }
      }
      judgeCutoffs(dischargeNpo, setsByClock.values, (_) => [sample]);
    }
  }
  return failures;
}

/// A module with one choice of its parameter values, its timed steps, and
/// the IDs of its npo steps.
typedef _Variant = ({
  String moduleId,
  Map<String, int> chosen,
  List<TimedStep> steps,
  Set<Object?> npo,
});

/// [module] with each choice of values in its declared parameter ranges.
List<_Variant> _variants(Module module) {
  var choices = [<String, int>{}];
  for (final MapEntry(key: name, value: range) in module.parameters.entries) {
    choices = [
      for (final c in choices)
        for (var value = range.min; value <= range.max; value++)
          {...c, name: value},
    ];
  }
  // A timed step keeps no type, so npo steps are found in the JSON.
  final npo = {
    for (final s in module.steps)
      if (s['type'] == 'npo') s['id'],
  };
  return [
    for (final chosen in choices)
      (
        moduleId: module.moduleId,
        chosen: chosen,
        steps: timedSteps(module, chosen),
        npo: npo,
      ),
  ];
}

StepRef _ref(_Variant v, TimedStep step) =>
    (moduleId: v.moduleId, stepId: step.id, chosen: v.chosen);

/// The instant [step]'s stored remind gives, never rounded or moved.
tz.TZDateTime _remindAt(TimedStep step, Anchors anchors) =>
    storedRemind(step, anchorTime(step.anchor, anchors)!);

/// Why [step]'s stored reminder would need moving on the phone, if it would.
List<PublishReason> _reminderFailures(
  TimedStep step,
  Anchors anchors,
  QuietHours quiet,
) {
  final at = _remindAt(step, anchors);
  final effect = effectOf(step.anchor, step.timing, anchors)!.at;
  // A day step on any day but day 0 is reminded on the morning of its day:
  // exempt only on its own local date, before the next day starts.
  final morningOfItsDay = switch (step.timing) {
    DayTiming(:final day) =>
      day != 0 &&
          at.isBefore(dayStart(anchorTime(step.anchor, anchors)!, day + 1)),
    _ => false,
  };
  // The patient has just tapped "I'm home".
  final atDischarge =
      step.anchor == Anchor.discharge &&
      switch (step.remind) {
        OffsetRemind(offset: Duration.zero) => true,
        _ => false,
      };
  return [
    if (!morningOfItsDay && at.isAfter(effect)) PublishReason.afterEffect,
    if (!step.allowNight && !atDischarge && inClockRange(quiet, at))
      PublishReason.quietHours,
  ];
}

/// The calendar dates of [dates], as UTC midnights.
Iterable<DateTime> _dates(DateRange dates) sync* {
  for (
    var d = dates.from;
    !d.isAfter(dates.through);
    d = DateTime.utc(d.year, d.month, d.day + 1)
  ) {
    yield d;
  }
}

/// The first instant of [date] in [zone], or of the date [day] days later.
tz.TZDateTime _start(tz.Location zone, DateTime date, [int day = 0]) =>
    dayStart(localTime(zone, date.year, date.month, date.day, 12, 0), day);

/// The local dates in [dates] whose length isn't 24 hours in [zone].
List<DateTime> clockChangeDates(tz.Location zone, DateRange dates) => [
  for (final d in _dates(dates))
    if (_start(zone, d, 1).difference(_start(zone, d)) !=
        const Duration(hours: 24))
      d,
];

/// The appointment dates and the discharge dates the check samples, in date
/// order. An appointment date's steps are those anchored to the appointment
/// or the arrival; a discharge date's are those anchored to the discharge.
({List<DateTime> appointment, List<DateTime> discharge}) sampleDates(
  Manifest manifest,
  Map<String, Module> modules,
  DateRange dates,
) {
  final zone = manifest.zone;
  final steps = [
    for (final ref in [manifest.base, ...manifest.optional])
      for (final v in _variants(modules[ref.moduleId]!)) ...v.steps,
  ];
  final changes = clockChangeDates(zone, dates).toSet();
  final appointment = <DateTime>[];
  final discharge = <DateTime>[];
  var ordinaryFound = false;
  for (final date in _dates(dates)) {
    final day = daySamples(zone, date);
    final booked = bookableSamples(zone, date, manifest.bookable);
    // On one date every effect, end and reminder moves later with its
    // anchor or stays put, so the first and last samples bound the span.
    final appointmentCrosses = _crosses(zone, [
      if (booked.isNotEmpty)
        for (final t in [booked.first, booked.last])
          for (final a in [day.first, t])
            for (final step in steps)
              if (step.anchor != Anchor.discharge)
                ..._instants(step, (
                  appointment: t,
                  arrival: a,
                  discharge: null,
                )),
    ]);
    final dischargeCrosses = _crosses(zone, [
      for (final d in [day.first, day.last])
        for (final step in steps)
          if (step.anchor == Anchor.discharge)
            ..._instants(step, (
              appointment: day.first,
              arrival: null,
              discharge: d,
            )),
    ]);
    final ordinary =
        !ordinaryFound &&
        !changes.contains(date) &&
        !appointmentCrosses &&
        !dischargeCrosses;
    if (ordinary) ordinaryFound = true;
    if (ordinary || changes.contains(date) || appointmentCrosses) {
      appointment.add(date);
    }
    if (ordinary || dischargeCrosses) discharge.add(date);
  }
  return (appointment: appointment, discharge: discharge);
}

/// [step]'s effect, its end when it has one, and its stored reminder.
List<tz.TZDateTime> _instants(TimedStep step, Anchors anchors) {
  final effect = effectOf(step.anchor, step.timing, anchors)!;
  return [
    effect.at,
    if (effect.until case final until?) until,
    _remindAt(step, anchors),
  ];
}

/// Whether a clock change in [zone] falls after the earliest of [instants]
/// and at or before the latest.
bool _crosses(tz.Location zone, List<tz.TZDateTime> instants) {
  if (instants.isEmpty) return false;
  final ms = [for (final t in instants) t.millisecondsSinceEpoch]..sort();
  return zone.lookupTimeZone(ms.first).end <= ms.last;
}

/// The instants 15 minutes of elapsed time apart, from the first instant of
/// [date], whose local date is [date] and whose local clock time is inside
/// [bookable]. A range that wraps midnight gives the start and the end of
/// [date], never the early hours of the next date.
List<tz.TZDateTime> bookableSamples(
  tz.Location zone,
  DateTime date,
  QuietHours bookable,
) => [
  for (final t in daySamples(zone, date))
    if (inClockRange(bookable, t)) t,
];

const _sampleStep = Duration(minutes: 15);

/// The instants 15 minutes of elapsed time apart, from the first instant of
/// [appointment]'s local date up to and including [appointment].
List<tz.TZDateTime> arrivalSamples(tz.TZDateTime appointment) => [
  for (
    var t = dayStart(appointment, 0);
    !t.isAfter(appointment);
    t = t.add(_sampleStep)
  )
    t,
];

/// Every 15 minutes of elapsed time across [date]'s local day.
List<tz.TZDateTime> daySamples(tz.Location zone, DateTime date) {
  final end = _start(zone, date, 1);
  return [
    for (var t = _start(zone, date); t.isBefore(end); t = t.add(_sampleStep)) t,
  ];
}

/// Every set of optional modules a [stage] code may tick for [appointment]:
/// each ticked module applies at it, and each exactlyOneOf group of the
/// stage has exactly one ticked.
List<Set<String>> allowedSets(
  Manifest manifest,
  Map<String, Module> modules,
  SelectedAt stage,
  tz.TZDateTime appointment,
) {
  final stageOf = {for (final r in manifest.optional) r.moduleId: r.selectedAt};
  final ids = [
    for (final r in manifest.optional)
      if (r.selectedAt == stage &&
          appliesAt(modules[r.moduleId]!.appliesWhen, appointment))
        r.moduleId,
  ];
  // Every module in a group shares one selectedAt.
  final groups = [
    for (final g in manifest.exactlyOneOf)
      if (stageOf[g.modules.first] == stage) g.modules,
  ];
  return [
    for (var mask = 0; mask < 1 << ids.length; mask++)
      if ({
            for (var i = 0; i < ids.length; i++)
              if (mask & 1 << i != 0) ids[i],
          }
          case final ticked
          when groups.every((g) => g.where(ticked.contains).length == 1))
        ticked,
  ];
}
