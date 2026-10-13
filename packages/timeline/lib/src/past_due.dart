import 'package:timezone/timezone.dart' as tz;

import 'timing.dart';

/// What the patient sees for a step whose effect has already passed at QR
/// creation. Set by the clinician on every timed step; there is no default.
enum PastDue { critical, doNow, ignore }

PastDue parsePastDue(Object? json) =>
    PastDue.values.asNameMap()[json] ??
    (throw FormatException('Not a pastDue level', json));

/// [level] if the step is past due at [createdAt], the QR creation instant;
/// otherwise null. Only the [appointment] is known at QR creation.
PastDue? pastDueOf(
  Anchor anchor,
  Timing timing,
  PastDue level,
  tz.TZDateTime appointment, {
  required tz.TZDateTime createdAt,
}) {
  if (anchor == Anchor.discharge) return null;
  // Arrival is never after the appointment, so with arrival at the
  // appointment an arrival step's effect is the latest it can be.
  final effect = effectOf(anchor, timing, (
    appointment: appointment,
    arrival: appointment,
    discharge: null,
  ))!.at;
  // An effect exactly at createdAt has already passed.
  return effect.isAfter(createdAt) ? null : level;
}
