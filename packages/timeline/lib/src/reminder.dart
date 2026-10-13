import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'clock.dart';
import 'duration.dart';
import 'offset.dart';
import 'timing.dart';

sealed class Remind {
  const Remind();
}

final class OffsetRemind extends Remind {
  const OffsetRemind(this.offset);
  final Duration offset;
}

final class DayAtRemind extends Remind {
  const DayAtRemind(this.day, this.time);
  final int day;
  final ({int hour, int minute}) time;
}

/// Why a reminder was moved earlier. Publishing fails on any move; on the
/// phone the move is only a safety net.
enum MoveReason { afterEffect, quietHours }

/// Local clock times from inclusive to exclusive, wrapping midnight when
/// [to] is earlier than [from].
typedef QuietHours = ({
  ({int hour, int minute}) from,
  ({int hour, int minute}) to,
});

typedef TimedStep = ({
  Anchor anchor,
  Timing timing,
  Remind remind,
  bool allowNight,
});

/// When the patient is notified, the effect time its text states, and any
/// moves that put it there.
typedef Reminder = ({
  tz.TZDateTime at,
  tz.TZDateTime effect,
  Set<MoveReason> moves,
});

/// A step's remind from its JSON. [day] turns a day number into days, usually
/// through [resolveDay]. "defaulted" must be present, though only the
/// validator uses it.
Remind parseRemind(
  Map<String, Object?> json,
  int Function(Object? dayNumber) day,
) => switch (json) {
  {'kind': 'offset', 'offset': final String offset, 'defaulted': bool()} =>
    OffsetRemind(parseElapsed(offset)),
  {
    'kind': 'dayAt',
    'day': final d,
    'time': final String time,
    'defaulted': bool(),
  } =>
    DayAtRemind(day(d), parseClockTime(time)),
  _ => throw FormatException('Not a remind', json),
};

/// What the phone does about [step] when computed at [now]. The stored remind
/// is rounded down to the whole minute, then moved to before the effect if
/// needed, then moved out of quiet hours if needed; a reminder whose time has
/// passed fires at [now], to the second, even in quiet hours. A heads-up is
/// given only while the main reminder is still ahead of [now].
StepReminders remindersOf(
  TimedStep step,
  Anchors anchors, {
  required QuietHours quiet,
  required ({int hour, int minute}) evening,
  required tz.TZDateTime now,
}) {
  final placed = _placed(step, anchors, quiet);
  if (placed == null) return const Pending();
  // "Ahead" is strict: a step taking effect right now is already in effect.
  if (!placed.effect.isAfter(now)) return const InEffect();
  final warn = step.allowNight && placed.at.isAfter(now);
  final quietStart = warn ? _quietStart(placed.at, quiet) : null;
  final headsUp = quietStart == null
      ? null
      : _notBefore(now, _eveningBefore(quietStart, evening));
  return Scheduled((
    at: _notBefore(now, placed.at),
    effect: placed.effect,
    moves: placed.moves,
  ), headsUp);
}

/// When to ask for the arrival time: while arrival-anchored [steps] wait for
/// it and the appointment is still ahead, at the evening reminder time the
/// day before the appointment, or at [now] if that has passed.
tz.TZDateTime? arrivalPrompt(
  Iterable<TimedStep> steps,
  Anchors anchors, {
  required ({int hour, int minute}) evening,
  required tz.TZDateTime now,
}) {
  final appointment = anchors.appointment;
  if (anchors.arrival != null ||
      !steps.any((s) => s.anchor == Anchor.arrival) ||
      !appointment.isAfter(now)) {
    return null;
  }
  return _notBefore(
    now,
    dayAtTime(appointment, -1, evening.hour, evening.minute),
  );
}

/// The latest evening reminder time before [quietStart].
tz.TZDateTime _eveningBefore(
  tz.TZDateTime quietStart,
  ({int hour, int minute}) evening,
) {
  final sameDate = dayAtTime(quietStart, 0, evening.hour, evening.minute);
  return sameDate.isBefore(quietStart)
      ? sameDate
      : dayAtTime(quietStart, -1, evening.hour, evening.minute);
}

/// [time], or [now] if [time] has already passed: late reminders fire at
/// once and keep now exactly.
tz.TZDateTime _notBefore(tz.TZDateTime now, tz.TZDateTime time) =>
    time.isBefore(now) ? tz.TZDateTime.from(now, time.location) : time;

/// The stored remind, rounded down and moved, before any lateness.
Reminder? _placed(TimedStep step, Anchors anchors, QuietHours quiet) {
  final from = anchorTime(step.anchor, anchors);
  if (from == null) return null;
  final effect = effectOf(step.anchor, step.timing, anchors)!.at;
  final moves = <MoveReason>{};
  var at = _wholeMinute(switch (step.remind) {
    OffsetRemind(:final offset) => stepTime(from, offset),
    DayAtRemind(:final day, :final time) => dayAtTime(
      from,
      day,
      time.hour,
      time.minute,
    ),
  });
  // A day step on any day but day 0 is reminded on the morning of its day,
  // after the day has started.
  final morningOfItsDay = switch (step.timing) {
    DayTiming(:final day) => day != 0,
    _ => false,
  };
  if (!morningOfItsDay && at.isAfter(effect)) {
    at = _wholeMinute(effect);
    moves.add(MoveReason.afterEffect);
  }
  // The patient has just tapped "I'm home".
  final atDischarge =
      step.anchor == Anchor.discharge &&
      switch (step.remind) {
        OffsetRemind(offset: Duration.zero) => true,
        _ => false,
      };
  if (!step.allowNight && !atDischarge) {
    if (_quietStart(at, quiet) case final start?) {
      at = start.subtract(const Duration(minutes: 1));
      moves.add(MoveReason.quietHours);
    }
  }
  return (at: at, effect: effect, moves: moves);
}

/// What the phone does about one step.
sealed class StepReminders {
  const StepReminders();
}

/// The step's anchor isn't known yet.
final class Pending extends StepReminders {
  const Pending();
}

/// The step has already taken effect, so no reminder. Whether it was missed
/// (past due) depends on the QR creation instant and is decided in 4c.
final class InEffect extends StepReminders {
  const InEffect();
}

final class Scheduled extends StepReminders {
  const Scheduled(this.main, this.headsUp);
  final Reminder main;
  final tz.TZDateTime? headsUp;
}

tz.TZDateTime _wholeMinute(tz.TZDateTime time) {
  final ms = time.millisecondsSinceEpoch;
  return tz.TZDateTime.fromMillisecondsSinceEpoch(
    time.location,
    ms - ms % Duration.millisecondsPerMinute,
  );
}

/// The start of the quiet period [time] falls in, or null outside quiet
/// hours. Compared on the local clock, so a clock change doesn't shift it.
tz.TZDateTime? _quietStart(tz.TZDateTime time, QuietHours quiet) {
  final clock = time.hour * 60 + time.minute;
  final from = quiet.from.hour * 60 + quiet.from.minute;
  final to = quiet.to.hour * 60 + quiet.to.minute;
  final wraps = to < from;
  final inQuiet = wraps
      ? clock >= from || clock < to
      : clock >= from && clock < to;
  if (!inQuiet) return null;
  // After midnight in a period that wraps, it began the evening before.
  final day = wraps && clock < to ? -1 : 0;
  return dayAtTime(time, day, quiet.from.hour, quiet.from.minute);
}
