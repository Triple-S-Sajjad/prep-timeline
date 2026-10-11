import 'package:timezone/timezone.dart' as tz;

/// Moves [appointment] by [offset] in elapsed time. Steps measured in
/// calendar days use the `day` and `dayAt` timing kinds instead.
tz.TZDateTime stepTime(tz.TZDateTime appointment, Duration offset) {
  final result = appointment.add(offset);
  if (appointment.year > 2037 || result.year > 2037) {
    throw ArgumentError('Time zone data only covers dates through 2037.');
  }
  return result;
}
