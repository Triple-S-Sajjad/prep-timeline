import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/timezone.dart' as tz;

const _details = NotificationDetails(
  android: AndroidNotificationDetails('reminders', 'Reminders'),
);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Hands every reminder of [timeline] to the phone, in timeline order, each
/// step's heads-up before its main reminder, then cancels pending reminders
/// that are no longer in the timeline. Lock-screen text is generic.
Future<void> scheduleReminders(
  FlutterLocalNotificationsPlugin plugin,
  List<TimelineEntry> timeline,
  Anchors anchors, {
  required DepartmentDefaults defaults,
  required tz.TZDateTime now,
  Duration Function(DateTime instant) deviceOffset = _deviceOffset,
}) async {
  final ids = <int>{};
  for (final (:moduleId, :step, effect: _) in timeline) {
    final reminders = remindersOf(
      step,
      anchors,
      quiet: defaults.quiet,
      evening: defaults.evening,
      now: now,
    );
    if (reminders is! Scheduled) continue;
    for (final (kind, at) in [
      if (reminders.headsUp case final headsUp?) ('headsUp', headsUp),
      ('main', reminders.main.at),
    ]) {
      final id = _stableId('$moduleId/${step.id}/$kind');
      // A shared id would replace one reminder with another, dropping it.
      if (!ids.add(id)) throw StateError('Reminder id collision: $id');
      final body = _body(step, at, reminders.main.effect, deviceOffset);
      try {
        await plugin.zonedSchedule(
          id: id,
          title: 'Prep step due',
          body: body,
          // Android rebuilds the instant from a wall-clock string and a zone
          // name, so a local time in a repeated hour fires at its first
          // occurrence. UTC has no repeated hours.
          scheduledDate: tz.TZDateTime.from(at, tz.UTC),
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      } on ArgumentError catch (e) {
        if (e.name != 'scheduledDate' ||
            e.message != 'Must be a date in the future') {
          rethrow;
        }
        // A late reminder fires at now, and by the time the plugin checks,
        // now has passed; so has a reminder due within that gap.
        await plugin.show(
          id: id,
          title: 'Prep step due',
          body: body,
          notificationDetails: _details,
        );
      }
    }
  }
  // Cancelling one by one, not cancelAll, keeps shown notifications.
  for (final pending in await plugin.pendingNotificationRequests()) {
    if (!ids.contains(pending.id)) await plugin.cancel(id: pending.id);
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// What a reminder at [at] says about [step]'s [effect], on the hospital's
/// clock: "Due at 3:00 AM", "Due by tomorrow at 3:00 AM", "Starts Sat, Nov 7
/// at 3:00 AM", or "Today" for a day step. A time gets the hospital's zone
/// abbreviation when the device's offset at [effect] differs.
String _body(
  TimedStep step,
  tz.TZDateTime at,
  tz.TZDateTime effect,
  Duration Function(DateTime instant) deviceOffset,
) {
  final day = _dayName(tz.TZDateTime.from(at, effect.location), effect);
  final hour = effect.hour % 12 == 0 ? 12 : effect.hour % 12;
  final minute = effect.minute.toString().padLeft(2, '0');
  final zone = deviceOffset(effect) == effect.timeZoneOffset
      ? ''
      : ' ${effect.timeZoneName}';
  final time = '$hour:$minute ${effect.hour < 12 ? 'AM' : 'PM'}$zone';
  final when = day == null ? 'at $time' : '$day at $time';
  return switch (step.timing) {
    DayTiming() => day == null ? 'Today' : 'Starts $day',
    DeadlineTiming() => 'Due by $when',
    WindowTiming() => 'Starts $when',
    OffsetTiming() || DayAtTiming() => 'Due $when',
  };
}

/// Null on the same local date, "tomorrow" on the next, else "Sat, Nov 7".
String? _dayName(tz.TZDateTime from, tz.TZDateTime to) {
  final days = DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
  return switch (days) {
    0 => null,
    1 => 'tomorrow',
    _ => '${_weekdays[to.weekday - 1]}, ${_months[to.month - 1]} ${to.day}',
  };
}

// Not TZDateTime.toLocal: that converts to package:timezone's local zone,
// which is UTC unless set, not the device's.
Duration _deviceOffset(DateTime instant) => DateTime.fromMillisecondsSinceEpoch(
  instant.millisecondsSinceEpoch,
  isUtc: true,
).toLocal().timeZoneOffset;

/// FNV-1a over [key], kept to positive 31 bits: the same step gets the same
/// id on every computation, so rescheduling replaces its notification.
int _stableId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}
