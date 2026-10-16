import 'package:timezone/timezone.dart' as tz;

import 'bundle.dart';
import 'clock.dart';
import 'past_due.dart';
import 'protocol.dart';
import 'step.dart';
import 'timing.dart';

/// What a scheduling or discharge QR code carries, never identity.
/// [parameters] holds each ticked module's chosen values, by module ID.
typedef QrCode = ({
  String protocolId,
  int protocolVersion,
  SelectedAt stage,
  Set<String> modules,
  Map<String, Map<String, int>> parameters,
  tz.TZDateTime createdAt,
});

/// A selected module with the parameter values the clinician chose for it.
typedef SelectedModule = ({Module module, Map<String, int> chosen});

/// A timed step on the timeline. A null [effect] means its anchor isn't known
/// yet and the step shows as pending.
typedef TimelineEntry = ({String moduleId, TimedStep step, Effect? effect});

enum NewInstructionsReason {
  outsideBookableHours,
  outsideAppliesWhen,
  newlyPastDue,
  afterDischarge,
}

/// The modules for an appointment, or why its time needs new instructions:
/// "Your time needs new instructions. Call us."
sealed class SelectionResult {
  const SelectionResult();
}

final class Selected extends SelectionResult {
  const Selected(this.modules);
  final List<SelectedModule> modules;
}

final class NeedsNewInstructions extends SelectionResult {
  const NeedsNewInstructions(this.reason);
  final NewInstructionsReason reason;
}

/// An appointment at or before now, on first entry or on a reschedule:
/// "Choose a time after now."
final class TimeNotAhead extends SelectionResult {
  const TimeNotAhead();
}

/// The code in [json], checked against [bundle]'s manifest and modules.
/// Throws FormatException for a malformed code and ArgumentError for one that
/// breaks a manifest rule.
QrCode decodeQr(Map<String, Object?> json, Bundle bundle) {
  final Bundle(:manifest, :modules) = bundle;
  final code = switch (json) {
    {
      'protocolId': final String protocolId,
      'version': final int version,
      'stage': final String stage,
      'modules': final List<Object?> ticked,
      'parameters': final Map<String, Object?> parameters,
      'createdAt': final String createdAt,
    } =>
      (
        protocolId: protocolId,
        version: version,
        stage:
            SelectedAt.values.asNameMap()[stage] ??
            (throw FormatException('Not a stage', stage)),
        ticked: [
          for (final m in ticked)
            m is String ? m : throw FormatException('Not a module ID', m),
        ],
        parameters: {
          for (final MapEntry(:key, :value) in parameters.entries)
            key: _values(value),
        },
        createdAt: _instant(createdAt, manifest.zone),
      ),
    _ => throw FormatException('Not a QR code', json),
  };
  if (code.protocolId != manifest.protocolId ||
      code.version != manifest.version) {
    throw ArgumentError('The code is for another protocol or version.');
  }
  final stageOf = {for (final r in manifest.optional) r.moduleId: r.selectedAt};
  final ticked = <String>{};
  for (final id in code.ticked) {
    // An unknown or base module has no stage, so it fails here too.
    if (stageOf[id] != code.stage) {
      throw ArgumentError.value(
        id,
        'modules',
        'Not an optional module on a ${code.stage.name} code',
      );
    }
    if (!ticked.add(id)) {
      throw ArgumentError.value(id, 'modules', 'Ticked twice');
    }
  }
  // Every module in a group shares one selectedAt.
  for (final group in manifest.exactlyOneOf) {
    if (stageOf[group.modules.first] != code.stage) continue;
    if (group.modules.where(ticked.contains).length != 1) {
      throw ArgumentError.value(group.modules, 'modules', 'Tick exactly one');
    }
  }
  for (final id in code.parameters.keys) {
    if (!ticked.contains(id)) {
      throw ArgumentError.value(id, 'parameters', 'Not a ticked module');
    }
  }
  for (final id in ticked) {
    _checkValues(
      _module(modules, id).parameters,
      code.parameters[id] ?? const {},
    );
  }
  return (
    protocolId: code.protocolId,
    protocolVersion: code.version,
    stage: code.stage,
    modules: ticked,
    parameters: code.parameters,
    createdAt: code.createdAt,
  );
}

/// verifyBundle refuses a bundle that lacks a listed module, so this never
/// throws; it stays so a lookup fails closed instead of crashing.
Module _module(Map<String, Module> modules, String id) =>
    modules[id] ??
    (throw ArgumentError.value(id, 'modules', 'Not in the bundle'));

Map<String, int> _values(Object? json) => switch (json) {
  final Map<String, Object?> values => {
    for (final MapEntry(:key, :value) in values.entries)
      key: value is int
          ? value
          : throw FormatException('Not an integer', value),
  },
  _ => throw FormatException('Not parameter values', json),
};

/// The app never picks a value: each declared parameter needs one, in range.
void _checkValues(Map<String, ParamRange> declared, Map<String, int> chosen) {
  for (final name in chosen.keys) {
    if (!declared.containsKey(name)) {
      throw ArgumentError.value(name, 'parameters', 'Undeclared');
    }
  }
  for (final MapEntry(key: name, value: range) in declared.entries) {
    final value = chosen[name];
    if (value == null || value < range.min || value > range.max) {
      throw ArgumentError.value(
        value,
        name,
        'Must be from ${range.min} to ${range.max}',
      );
    }
  }
}

/// UTC only, so a code reads the same on every phone.
final _utc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

tz.TZDateTime _instant(String text, tz.Location zone) {
  if (!_utc.hasMatch(text)) {
    throw FormatException('Not a UTC instant', text);
  }
  return tz.TZDateTime.from(DateTime.parse(text), zone);
}

/// The base module, then the ticked optional modules in manifest order;
/// [TimeNotAhead] when [appointment] is at or before [now]; otherwise
/// [NeedsNewInstructions] when it is outside the bookable hours or a selected
/// module's appliesWhen. The app never picks a module itself.
/// Throws ArgumentError for an appointment in another zone, a code passed in
/// the wrong stage or a base module with parameters, even when the time
/// alone would need new instructions.
SelectionResult selectedModules(
  Bundle bundle,
  QrCode scheduling,
  QrCode? discharge,
  tz.TZDateTime appointment, {
  required tz.TZDateTime now,
}) {
  final Bundle(:manifest, :modules) = bundle;
  // By name, because the same zone can be loaded more than once.
  if (appointment.location.name != manifest.zone.name) {
    throw ArgumentError("The appointment must be in the protocol's zone.");
  }
  if (scheduling.stage != SelectedAt.scheduling ||
      discharge?.stage == SelectedAt.scheduling) {
    throw ArgumentError('Each code must be passed as its own stage.');
  }
  final base = _module(modules, manifest.base.moduleId);
  // Only ticked modules get values on a code, and the base is never ticked.
  if (base.parameters.isNotEmpty) {
    throw ArgumentError.value(
      base.moduleId,
      'modules',
      'A base module has no parameters',
    );
  }
  final ticked = {...scheduling.modules, ...?discharge?.modules};
  final chosen = {...scheduling.parameters, ...?discharge?.parameters};
  final selected = [
    (module: base, chosen: const <String, int>{}),
    for (final ref in manifest.optional)
      if (ticked.contains(ref.moduleId))
        (
          module: _module(modules, ref.moduleId),
          chosen: chosen[ref.moduleId] ?? const <String, int>{},
        ),
  ];
  if (!appointment.isAfter(now)) return const TimeNotAhead();
  if (!_inRange(manifest.bookable, appointment)) {
    return const NeedsNewInstructions(
      NewInstructionsReason.outsideBookableHours,
    );
  }
  if (!selected.every((s) => appliesAt(s.module.appliesWhen, appointment))) {
    return const NeedsNewInstructions(NewInstructionsReason.outsideAppliesWhen);
  }
  return Selected(selected);
}

/// What a reschedule gives: the selection at the new time with its
/// [anchors], or why it is blocked with the [anchors] it was given.
typedef Rescheduled = ({SelectionResult result, Anchors anchors});

/// Moves [current]'s appointment to [appointment], judged at [now]. Blocked
/// once the procedure is over, then for any result but [Selected] that
/// [selectedModules] gives, then for a step that is not ignore becoming newly
/// past due. A move clears an entered arrival; the
/// same time changes nothing. The app never switches modules. Throws
/// ArgumentError as [selectedModules] does, and for a [current] appointment in
/// another zone.
Rescheduled reschedule(
  Bundle bundle,
  QrCode scheduling,
  QrCode? discharge,
  Anchors current,
  tz.TZDateTime appointment, {
  required tz.TZDateTime now,
}) {
  if (current.appointment.location.name != bundle.manifest.zone.name) {
    throw ArgumentError("The appointment must be in the protocol's zone.");
  }
  // First, so a wrong zone, stage or bundle throws before any result is
  // chosen.
  final selection = selectedModules(
    bundle,
    scheduling,
    discharge,
    appointment,
    now: now,
  );
  Rescheduled kept(SelectionResult result) =>
      (result: result, anchors: current);
  if (discharge != null || current.discharge != null) {
    return kept(
      const NeedsNewInstructions(NewInstructionsReason.afterDischarge),
    );
  }
  if (selection is! Selected ||
      appointment.isAtSameMomentAs(current.appointment)) {
    return kept(selection);
  }
  final old = current.appointment;
  // pastDueOf puts the arrival at each appointment and never counts a
  // discharge step, as a reschedule must, since it clears the arrival.
  final newlyPastDue =
      [for (final s in selection.modules) ...timedSteps(s.module, s.chosen)]
          .any(
            (step) =>
                step.pastDue != PastDue.ignore &&
                pastDueOf(step, old, createdAt: now) == null &&
                pastDueOf(step, appointment, createdAt: now) != null,
          );
  if (newlyPastDue) {
    return kept(const NeedsNewInstructions(NewInstructionsReason.newlyPastDue));
  }
  return (
    result: selection,
    anchors: (appointment: appointment, arrival: null, discharge: null),
  );
}

/// Whether [time]'s local clock time is in [range], which includes its start,
/// excludes its end and may wrap midnight.
bool _inRange(QuietHours range, tz.TZDateTime time) {
  final clock = time.hour * 60 + time.minute;
  final from = range.from.hour * 60 + range.from.minute;
  final to = range.to.hour * 60 + range.to.minute;
  return to < from ? clock >= from || clock < to : from <= clock && clock < to;
}

/// Every timed step of [selected], sorted by effect time; ties keep module
/// order, then each module's own step order. A pending step sorts by its
/// effect with the unknown anchor at the appointment: the latest an arrival
/// can be and the earliest a discharge can be.
List<TimelineEntry> timelineOf(List<SelectedModule> selected, Anchors anchors) {
  final bound = (
    appointment: anchors.appointment,
    arrival: anchors.arrival ?? anchors.appointment,
    discharge: anchors.discharge ?? anchors.appointment,
  );
  final keyed = [
    for (final s in selected)
      for (final step in timedSteps(s.module, s.chosen))
        (
          sortAt: effectOf(step.anchor, step.timing, bound)!.at,
          entry: (
            moduleId: s.module.moduleId,
            step: step,
            effect: effectOf(step.anchor, step.timing, anchors),
          ),
        ),
  ];
  // List.sort isn't stable, so ties fall back to the original position.
  final order = [for (var i = 0; i < keyed.length; i++) i]
    ..sort((a, b) {
      final byTime = keyed[a].sortAt.compareTo(keyed[b].sortAt);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  return [for (final i in order) keyed[i].entry];
}
