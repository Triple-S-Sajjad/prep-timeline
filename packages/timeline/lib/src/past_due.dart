import 'package:timezone/timezone.dart' as tz;

import 'step.dart';
import 'timing.dart';

PastDue parsePastDue(Object? json) =>
    PastDue.values.asNameMap()[json] ??
    (throw FormatException('Not a pastDue level', json));

/// The step's pastDue level if it is past due at [createdAt], the QR creation
/// instant; otherwise null. Only the [appointment] is known at QR creation.
PastDue? pastDueOf(
  TimedStep step,
  tz.TZDateTime appointment, {
  required tz.TZDateTime createdAt,
}) {
  if (step.anchor == Anchor.discharge) return null;
  // Arrival is never after the appointment, so with arrival at the
  // appointment an arrival step's effect is the latest it can be.
  final effect = effectOf(step.anchor, step.timing, (
    appointment: appointment,
    arrival: appointment,
    discharge: null,
  ))!.at;
  // An effect exactly at createdAt has already passed.
  return effect.isAfter(createdAt) ? null : step.pastDue;
}
