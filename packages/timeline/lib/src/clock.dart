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

/// Local clock times from inclusive to exclusive, wrapping midnight when
/// [to] is earlier than [from].
typedef QuietHours = ({
  ({int hour, int minute}) from,
  ({int hour, int minute}) to,
});
