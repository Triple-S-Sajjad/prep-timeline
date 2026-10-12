import 'package:timezone/timezone.dart' as tz;

import 'limits.dart';

/// Moves [appointment] by [offset] in elapsed time. Steps measured in
/// calendar days use the `day` and `dayAt` timing kinds instead.
tz.TZDateTime stepTime(tz.TZDateTime appointment, Duration offset) {
  checkSupported(appointment);
  return checkSupported(appointment.add(offset));
}
