import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'scheduler.dart';

// Debug builds only (see main.dart): drives scheduleReminders on a device for
// the notification spike. Not clinical guidance.

// 00:00 to 00:00 is an empty range: no quiet hours, so no heads-ups.
const _defaults = (
  evening: (hour: 20, minute: 0),
  quiet: (from: (hour: 0, minute: 0), to: (hour: 0, minute: 0)),
);

class DebugReminders extends StatefulWidget {
  const DebugReminders({super.key});

  @override
  State<DebugReminders> createState() => _DebugRemindersState();
}

class _DebugRemindersState extends State<DebugReminders> {
  final _plugin = FlutterLocalNotificationsPlugin();
  late final tz.Location _ny;
  String _log = '';

  @override
  void initState() {
    super.initState();
    tzdata.initializeTimeZones();
    _ny = tz.getLocation('America/New_York');
  }

  Future<void> _setUp() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final notifications = await android?.requestNotificationsPermission();
    final exact = await android?.canScheduleExactNotifications();
    // An open with exact alarms off forgets what was delivered, so the next
    // pass shows every late reminder again (ADR 2).
    if (exact == false) await saveRecord(await _recordFile(), const {});
    setState(() => _log = 'notifications: $notifications, exact: $exact');
  }

  Future<File> _recordFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/handed.json');

  Future<void> _openExactAlarmSetting() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestExactAlarmsPermission();
  }

  // The last times scheduled, kept in a file so "Reopen" works after a
  // force-stop or reboot.
  Future<File> _timesFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/debug_times.txt');

  /// One step per time in [times] (whole minutes, ascending), each reminded
  /// at its time and taking effect 30 minutes later, so a late reminder still
  /// has its effect ahead. Counted back from an appointment 10 minutes after
  /// the last effect.
  Future<void> _schedule(List<tz.TZDateTime> times) async {
    await (await _timesFile()).writeAsString(
      times.map((t) => t.millisecondsSinceEpoch).join(','),
    );
    final now = tz.TZDateTime.now(_ny);
    final appointment = times.last.add(const Duration(minutes: 40));
    final steps = [
      for (final (i, time) in times.indexed)
        {
          'id': 'test-$i',
          'type': 'medication_change',
          'anchor': 'appointment',
          'timing': {
            'kind': 'offset',
            'offset': '-PT${appointment.difference(time).inMinutes - 30}M',
          },
          'remind': {
            'kind': 'offset',
            'offset': '-PT${appointment.difference(time).inMinutes}M',
            'defaulted': false,
          },
          'allowNight': false,
          'pastDue': 'doNow',
          'text': 'Test reminder $i.',
        },
    ];
    final module = parseModule({
      'schemaVersion': 2,
      'moduleId': 'debug',
      'version': 1,
      'owner': 'Spike',
      'reviewBy': '2027-04-01',
      'appliesWhen': {
        'appointmentTime': {'fromInclusive': '00:00', 'toExclusive': '24:00'},
      },
      'steps': steps,
    });
    final anchors = (appointment: appointment, arrival: null, discharge: null);
    final record = await _recordFile();
    try {
      await scheduleReminders(
        _plugin,
        timelineOf([(module: module, chosen: const {})], anchors),
        anchors,
        defaults: _defaults,
        clock: () => tz.TZDateTime.now(_ny),
        load: () => loadRecord(record),
        save: (handed) => saveRecord(record, handed),
      );
      final utc = times.map((t) => t.toUtc().toIso8601String()).join('\n');
      setState(() => _log = 'now ${now.toUtc().toIso8601String()}\n$utc');
    } on PlatformException catch (e) {
      setState(() => _log = 'Failed: ${e.code} ${e.message}');
    }
  }

  /// A new pass for the last appointment at the current time, as an app open
  /// would run.
  Future<void> _reopen() async {
    final saved = await (await _timesFile()).readAsString();
    await _schedule([
      for (final ms in saved.split(','))
        tz.TZDateTime.fromMillisecondsSinceEpoch(_ny, int.parse(ms)),
    ]);
  }

  void _inMinutes() {
    final now = tz.TZDateTime.now(_ny);
    // Reminders are whole minutes, so count from the next one.
    final next = tz.TZDateTime(
      _ny,
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).add(const Duration(minutes: 1));
    _schedule([
      for (final m in [2, 4, 6]) next.add(Duration(minutes: m)),
    ]);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Reminder spike (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton(
            onPressed: _setUp,
            child: const Text('Initialize and ask permission'),
          ),
          OutlinedButton(
            onPressed: _openExactAlarmSetting,
            child: const Text('Open Alarms & reminders setting'),
          ),
          FilledButton(
            onPressed: _inMinutes,
            child: const Text('Schedule 3: next minute +2, +4, +6'),
          ),
          FilledButton(
            onPressed: _reopen,
            child: const Text('Reopen: last times, new pass'),
          ),
          FilledButton(
            onPressed: () => _schedule([tz.TZDateTime.utc(2026, 11, 1, 6, 5)]),
            child: const Text('Schedule fall-back: 2026-11-01 01:05 EST'),
          ),
          const SizedBox(height: 16),
          SelectableText(_log),
        ],
      ),
    ),
  );
}
