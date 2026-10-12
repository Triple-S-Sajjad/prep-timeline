import 'package:timezone/timezone.dart' as tz;

import 'limits.dart';

/// A clock time on a calendar day counted from [anchor]'s local date. Built
/// from the date, not by adding 24-hour blocks, so a clock change in between
/// can't shift the clock time.
///
/// A time skipped by a spring-forward change resolves to the earlier instant,
/// and a repeated time to its first occurrence: for a cutoff, earlier is the
/// more restrictive choice the spec requires.
tz.TZDateTime dayAtTime(tz.TZDateTime anchor, int day, int hour, int minute) {
  checkSupported(anchor);
  // Without this, 24:00 or 17:60 would silently roll over to the next hour or day.
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    throw ArgumentError('Clock time must be between 00:00 and 23:59.');
  }
  final year = anchor.year;
  final month = anchor.month;
  final date = anchor.day + day;
  final result = tz.TZDateTime(
    anchor.location,
    year,
    month,
    date,
    hour,
    minute,
  );
  // In a skipped hour the constructor lands later; step back by the same gap.
  final asked = DateTime.utc(year, month, date, hour, minute);
  final got = DateTime.utc(
    result.year,
    result.month,
    result.day,
    result.hour,
    result.minute,
  );
  return checkSupported(result.subtract(got.difference(asked)));
}

/// The start (00:00) of a calendar day counted from [anchor]'s local date.
tz.TZDateTime dayStart(tz.TZDateTime anchor, int day) =>
    dayAtTime(anchor, day, 0, 0);
