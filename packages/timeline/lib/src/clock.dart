/// The schema's clockTime pattern. "24:00" is allowed there only as the end
/// of an appointment-time range, never as a time a step happens.
final _clock = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$');

({int hour, int minute}) parseClockTime(String text) {
  final match = _clock.firstMatch(text);
  if (match == null) {
    throw FormatException('Not an HH:MM clock time', text);
  }
  return (hour: int.parse(match[1]!), minute: int.parse(match[2]!));
}

/// Whether [time]'s local clock time is in [range]: its start included, its
/// end excluded, wrapping midnight when the end is earlier. Quiet hours,
/// bookable hours and the publish check all read ranges through this.
bool inClockRange(QuietHours range, DateTime time) {
  final clock = time.hour * 60 + time.minute;
  final from = range.from.hour * 60 + range.from.minute;
  final to = range.to.hour * 60 + range.to.minute;
  return to < from ? clock >= from || clock < to : from <= clock && clock < to;
}

/// Local clock times from inclusive to exclusive, wrapping midnight when
/// [to] is earlier than [from].
typedef QuietHours = ({
  ({int hour, int minute}) from,
  ({int hour, int minute}) to,
});
