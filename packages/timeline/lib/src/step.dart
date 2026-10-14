import 'clock.dart';
import 'duration.dart';
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

/// What the patient sees for a step whose effect has already passed at QR
/// creation. Set by the clinician on every timed step; there is no default.
enum PastDue { critical, doNow, ignore }

/// A timed step as parsed from its module. Its pastDue level travels with it,
/// so the two can't be mismatched.
typedef TimedStep = ({
  String id,
  Anchor anchor,
  Timing timing,
  Remind remind,
  bool allowNight,
  PastDue pastDue,
});
