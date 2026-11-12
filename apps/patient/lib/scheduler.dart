import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/timezone.dart' as tz;

const _details = NotificationDetails(
  android: AndroidNotificationDetails('reminders', 'Reminders'),
);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// The last scheduling pass started; the next one waits for it.
Future<void> _passes = Future.value();

/// Hands every reminder of [timeline] to the phone, in timeline order, each
/// step's heads-up before its main reminder, after cancelling pending
/// reminders that are no longer in the timeline. Lock-screen text is generic.
///
/// [load] and [save] keep the record of reminders handed to the phone:
/// notification id -> effect instant, UTC ms. A late reminder the phone has
/// already delivered for the same effect is not shown again
/// (docs/adr/0002-reminder-delivery-record.md). One pass runs at a time: a
/// call waits for the previous one, so it loads the record that one saved,
/// and reads the current time from [clock] only when it starts.
Future<void> scheduleReminders(
  FlutterLocalNotificationsPlugin plugin,
  List<TimelineEntry> timeline,
  Anchors anchors, {
  required DepartmentDefaults defaults,
  required tz.TZDateTime Function() clock,
  required Future<Map<int, int>> Function() load,
  required Future<void> Function(Map<int, int> record) save,
  Duration Function(DateTime instant) deviceOffset = _deviceOffset,
}) {
  final pass = _passes.then((_) async {
    final now = clock();
    final handover = <({int id, tz.TZDateTime at, int effect, String body})>[];
    for (final (:moduleId, :step, effect: _) in timeline) {
      final reminders = remindersOf(
        step,
        anchors,
        quiet: defaults.quiet,
        evening: defaults.evening,
        now: now,
      );
      if (reminders is! Scheduled) continue;
      final effect = reminders.main.effect;
      for (final (kind, at) in [
        if (reminders.headsUp case final headsUp?) ('headsUp', headsUp),
        ('main', reminders.main.at),
      ]) {
        handover.add((
          id: _stableId('$moduleId/${step.id}/$kind'),
          at: at,
          effect: effect.millisecondsSinceEpoch,
          body: _body(step, at, effect, deviceOffset),
        ));
      }
    }
    final ids = {for (final r in handover) r.id};
    // A shared id would replace one reminder with another, dropping it.
    if (ids.length != handover.length) {
      throw StateError('Reminder id collision');
    }
    bool isLate(tz.TZDateTime at) => !at.isAfter(now);

    final record = await load();
    final pending = {
      for (final p in await plugin.pendingNotificationRequests()) p.id,
    };
    final stale = pending.difference(ids);
    final cancelled = {
      ...stale,
      for (final r in handover)
        if (isLate(r.at) && pending.contains(r.id)) r.id,
    };
    // Saved before cancelling, and handovers saved only after they happen:
    // a crash in between then repeats a reminder, never drops one.
    record.removeWhere(
      (id, effect) =>
          effect <= now.millisecondsSinceEpoch || cancelled.contains(id),
    );
    await save(record);
    // Cancelling one by one, not cancelAll, keeps shown notifications.
    for (final id in stale) {
      await plugin.cancel(id: id);
    }
    for (final (:id, :at, :effect, :body) in handover) {
      Future<void> show() => plugin.show(
        id: id,
        title: 'Prep step due',
        body: body,
        notificationDetails: _details,
      );
      if (!isLate(at)) {
        try {
          await plugin.zonedSchedule(
            id: id,
            title: 'Prep step due',
            body: body,
            // Android rebuilds the instant from a wall-clock string and a
            // zone name, so a local time in a repeated hour fires at its
            // first occurrence. UTC has no repeated hours.
            scheduledDate: tz.TZDateTime.from(at, tz.UTC),
            notificationDetails: _details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          );
        } on ArgumentError catch (e) {
          if (e.name != 'scheduledDate' ||
              e.message != 'Must be a date in the future') {
            rethrow;
          }
          // Due between computing the reminders and the plugin's own check.
          await show();
        }
      } else if (pending.contains(id)) {
        // Still listed although its time has passed: Android dropped the
        // alarm (force-stop, revoked permission), and the plugin's boot
        // receiver would fire the listed entry again.
        await plugin.cancel(id: id);
        await show();
      } else if (record[id] == effect) {
        continue; // delivered for this effect
      } else {
        await show();
      }
      record[id] = effect;
    }
    await save(record);
  });
  // The next pass runs even if this one fails; this caller still gets the
  // error through [pass].
  _passes = pass.then((_) {}, onError: (Object _) {});
  return pass;
}

/// Reads the record [saveRecord] wrote. A missing, unreadable or corrupt
/// file reads as empty, so the risk is a repeated reminder, never a dropped
/// one.
Future<Map<int, int>> loadRecord(File file) async {
  final Object? json;
  try {
    json = jsonDecode(await file.readAsString());
  } on FileSystemException {
    return {};
  } on FormatException {
    return {};
  }
  if (json is! Map<String, Object?>) return {};
  final record = <int, int>{};
  for (final MapEntry(:key, :value) in json.entries) {
    final id = int.tryParse(key);
    if (id == null || value is! int) return {};
    record[id] = value;
  }
  return record;
}

/// Writes [record] as `{"<id>": effectMs}` to a temporary file, then renames
/// it over [file], so a crash mid-write leaves the previous record whole.
Future<void> saveRecord(File file, Map<int, int> record) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(
    jsonEncode({
      for (final MapEntry(:key, :value) in record.entries) '$key': value,
    }),
    flush: true,
  );
  await tmp.rename(file.path);
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
