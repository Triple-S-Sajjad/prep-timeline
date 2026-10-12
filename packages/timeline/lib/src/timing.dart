import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'clock.dart';
import 'duration.dart';
import 'offset.dart';

enum Anchor { appointment, arrival, discharge }

/// A null arrival or discharge isn't known yet.
typedef Anchors = ({
  tz.TZDateTime appointment,
  tz.TZDateTime? arrival,
  tz.TZDateTime? discharge,
});

enum Lasts { oneDay, untilAnchor }

sealed class Timing {
  const Timing();
}

final class OffsetTiming extends Timing {
  const OffsetTiming(this.offset);
  final Duration offset;
}

final class DayAtTiming extends Timing {
  const DayAtTiming(this.day, this.time);
  final int day;
  final ({int hour, int minute}) time;
}

final class DayTiming extends Timing {
  const DayTiming(this.day, this.lasts);
  final int day;
  final Lasts lasts;
}

final class WindowTiming extends Timing {
  const WindowTiming(this.start, this.duration);
  final Duration start;
  final Duration duration;
}

final class DeadlineTiming extends Timing {
  const DeadlineTiming(this.by);
  final Duration by;
}

/// When a step takes effect, and when it ends for a window or day step.
typedef Effect = ({tz.TZDateTime at, tz.TZDateTime? until});

/// A day number as written: an integer, or a parameter the clinician chose at
/// QR creation, in calendar days and negative when "before". The chosen value
/// is checked against its declared range here as well as at QR decode.
int resolveDay(
  Object? dayNumber,
  Map<String, Object?> parameters,
  Map<String, int> chosen,
) {
  if (dayNumber is int) return dayNumber;
  if (dayNumber case {
    'param': final String name,
    'before': final bool before,
  }) {
    if (parameters[name] case {
      'min': final int min,
      'max': final int max,
      'unit': final String unit,
    }) {
      final value = chosen[name];
      if (value == null || value < min || value > max) {
        throw ArgumentError.value(value, name, 'Must be from $min to $max');
      }
      final days = switch (unit) {
        'days' => value,
        'weeks' => value * 7,
        _ => throw FormatException('Not a parameter unit', unit),
      };
      return before ? -days : days;
    }
    throw FormatException('Undeclared parameter', name);
  }
  throw FormatException('Not a day number', dayNumber);
}

/// A step's timing from its JSON. [day] turns a day number into days, usually
/// through [resolveDay].
Timing parseTiming(
  Map<String, Object?> json,
  int Function(Object? dayNumber) day,
) => switch (json) {
  {'kind': 'offset', 'offset': final String offset} => OffsetTiming(
    parseElapsed(offset),
  ),
  {'kind': 'dayAt', 'day': final d, 'time': final String time} => DayAtTiming(
    day(d),
    parseClockTime(time),
  ),
  {'kind': 'day', 'day': final d, 'lasts': final String lasts} => DayTiming(
    day(d),
    Lasts.values.asNameMap()[lasts] ??
        (throw FormatException('Not a lasts value', lasts)),
  ),
  {
    'kind': 'window',
    'start': final String start,
    'duration': final String duration,
  } =>
    WindowTiming(parseElapsed(start), _windowLength(duration)),
  {'kind': 'deadline', 'by': final String by} => DeadlineTiming(
    parseElapsed(by),
  ),
  _ => throw FormatException('Not a timing', json),
};

Duration _windowLength(String text) {
  final duration = parseElapsed(text);
  if (duration <= Duration.zero) {
    throw FormatException('A window must last longer than zero', text);
  }
  return duration;
}

Effect _untilAnchor(tz.TZDateTime start, tz.TZDateTime anchor) {
  if (start.isAfter(anchor)) {
    throw ArgumentError('A day step after its anchor cannot last until it.');
  }
  return (at: start, until: anchor);
}

/// When a step takes effect, counted from its [anchor], or null while that
/// anchor isn't known yet and the step shows as pending.
Effect? effectOf(Anchor anchor, Timing timing, Anchors anchors) {
  final from = switch (anchor) {
    Anchor.appointment => anchors.appointment,
    Anchor.arrival => anchors.arrival,
    Anchor.discharge => anchors.discharge,
  };
  if (from == null) return null;
  // Calendar days are counted in the anchor's own zone. By name, because the
  // same zone can be loaded more than once.
  if (from.location.name != anchors.appointment.location.name) {
    throw ArgumentError("Every anchor must be in the protocol's time zone.");
  }
  return switch (timing) {
    OffsetTiming(:final offset) || DeadlineTiming(by: final offset) => (
      at: stepTime(from, offset),
      until: null,
    ),
    DayAtTiming(:final day, :final time) => (
      at: dayAtTime(from, day, time.hour, time.minute),
      until: null,
    ),
    DayTiming(:final day, lasts: Lasts.oneDay) => (
      at: dayStart(from, day),
      until: dayStart(from, day + 1),
    ),
    DayTiming(:final day, lasts: Lasts.untilAnchor) => _untilAnchor(
      dayStart(from, day),
      from,
    ),
    WindowTiming(:final start, :final duration) => (
      at: stepTime(from, start),
      until: stepTime(from, start + duration),
    ),
  };
}
