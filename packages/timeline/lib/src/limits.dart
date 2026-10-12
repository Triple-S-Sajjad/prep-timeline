import 'package:timezone/timezone.dart' as tz;

/// The bundled time zone data stops in 2037; later times would use guessed
/// offsets, so they are refused.
tz.TZDateTime checkSupported(tz.TZDateTime time) {
  if (time.year > 2037) {
    throw ArgumentError('Time zone data only covers dates through 2037.');
  }
  return time;
}
