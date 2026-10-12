import 'dart:math';

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
  final location = anchor.location;
  final wall = _wall(anchor, day, hour, minute);
  // Read with the offset of its period, the wall time is the first occurrence
  // or, if skipped, the earlier instant.
  final offset = _periodOf(location, wall).timeZone.offset.inMilliseconds;
  return _at(location, wall - offset);
}

/// The first instant of a calendar day counted from [anchor]'s local date.
/// Where a spring-forward change skips midnight, that is the change itself
/// (01:00 in America/Santiago), not the evening before.
tz.TZDateTime dayStart(tz.TZDateTime anchor, int day) {
  checkSupported(anchor);
  final location = anchor.location;
  final midnight = _wall(anchor, day, 0, 0);
  final period = _periodOf(location, midnight);
  final offset = period.timeZone.offset.inMilliseconds;
  return _at(location, max(midnight - offset, period.start));
}

/// The local time as milliseconds read as if UTC. DateTime.utc rolls day
/// overflow into the next month or year.
int _wall(tz.TZDateTime anchor, int day, int hour, int minute) => DateTime.utc(
  anchor.year,
  anchor.month,
  anchor.day + day,
  hour,
  minute,
).millisecondsSinceEpoch;

/// The first offset period of [location] in which local time [wall] happens
/// or, if a spring-forward change skips it, the period that starts at that
/// change. The timezone constructor can't be used: which occurrence of a
/// repeated time it picks depends on the sign of the zone's offset.
tz.TzInstant _periodOf(tz.Location location, int wall) {
  // No offset reaches a day, so [wall] can't happen before this instant, and
  // walking the periods forward from here misses no occurrence.
  var period = location.lookupTimeZone(wall - Duration.millisecondsPerDay);
  while (wall - period.timeZone.offset.inMilliseconds >= period.end) {
    period = location.lookupTimeZone(period.end);
  }
  return period;
}

tz.TZDateTime _at(tz.Location location, int utc) =>
    checkSupported(tz.TZDateTime.fromMillisecondsSinceEpoch(location, utc));
