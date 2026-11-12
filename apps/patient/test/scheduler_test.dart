import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patient/scheduler.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// Spike fixture, not clinical guidance. Unsigned: the spike checks no
// signature.
const _module = <String, Object?>{
  'schemaVersion': 2,
  'moduleId': 'spike-base',
  'version': 1,
  'owner': 'Spike',
  'reviewBy': '2027-04-01',
  'appliesWhen': {
    'appointmentTime': {'fromInclusive': '00:00', 'toExclusive': '24:00'},
  },
  'steps': [
    {
      'id': 'clear-liquids',
      'type': 'diet',
      'anchor': 'appointment',
      'timing': {'kind': 'day', 'day': -1, 'lasts': 'oneDay'},
      'remind': {
        'kind': 'dayAt',
        'day': -1,
        'time': '07:00',
        'defaulted': true,
      },
      'allowNight': false,
      'pastDue': 'doNow',
      'text': 'Clear liquids only today.',
    },
    {
      'id': 'dose2',
      'type': 'prep_dose',
      'anchor': 'appointment',
      'timing': {'kind': 'offset', 'offset': '-PT6H'},
      'remind': {'kind': 'offset', 'offset': '-PT6H', 'defaulted': false},
      'allowNight': true,
      'pastDue': 'critical',
      'text': 'Drink the second half of your prep.',
    },
    {
      'id': 'stop-liquids',
      'type': 'npo',
      'anchor': 'appointment',
      'timing': {'kind': 'offset', 'offset': '-PT2H'},
      'remind': {'kind': 'offset', 'offset': '-PT3H', 'defaulted': false},
      'allowNight': false,
      'pastDue': 'critical',
      'text': 'Stop all liquids now.',
    },
  ],
};

// One step per timing kind, for the body text. Spike fixture, not clinical
// guidance.
const _kinds = <String, Object?>{
  'schemaVersion': 2,
  'moduleId': 'spike-kinds',
  'version': 1,
  'owner': 'Spike',
  'reviewBy': '2027-04-01',
  'appliesWhen': {
    'appointmentTime': {'fromInclusive': '00:00', 'toExclusive': '24:00'},
  },
  'steps': [
    {
      'id': 'hold',
      'type': 'medication_hold',
      'anchor': 'appointment',
      'timing': {'kind': 'day', 'day': -7, 'lasts': 'untilAnchor'},
      'remind': {
        'kind': 'dayAt',
        'day': -7,
        'time': '07:00',
        'defaulted': true,
      },
      'allowNight': false,
      'pastDue': 'doNow',
      'text': 'Stop the pill from today.',
    },
    {
      'id': 'mix',
      'type': 'checklist',
      'anchor': 'appointment',
      'timing': {'kind': 'dayAt', 'day': -1, 'time': '21:00'},
      'remind': {
        'kind': 'dayAt',
        'day': -1,
        'time': '20:00',
        'defaulted': false,
      },
      'allowNight': false,
      'pastDue': 'doNow',
      'text': 'Mix the prep.',
    },
    {
      'id': 'no-food',
      'type': 'diet',
      'anchor': 'appointment',
      'timing': {'kind': 'day', 'day': 0, 'lasts': 'untilAnchor'},
      'remind': {
        'kind': 'dayAt',
        'day': -1,
        'time': '20:00',
        'defaulted': true,
      },
      'allowNight': false,
      'pastDue': 'critical',
      'text': 'Nothing to eat this morning.',
    },
    {
      'id': 'finish',
      'type': 'medication_change',
      'anchor': 'appointment',
      'timing': {'kind': 'deadline', 'by': '-PT6H'},
      'remind': {
        'kind': 'dayAt',
        'day': -1,
        'time': '20:00',
        'defaulted': false,
      },
      'allowNight': false,
      'pastDue': 'critical',
      'text': 'Take the morning pill by then.',
    },
    {
      'id': 'far',
      'type': 'medication_change',
      'anchor': 'appointment',
      'timing': {'kind': 'offset', 'offset': '-PT3H'},
      'remind': {'kind': 'offset', 'offset': '-PT51H', 'defaulted': false},
      'allowNight': false,
      'pastDue': 'critical',
      'text': 'Take the other pill.',
    },
    {
      'id': 'no-driving',
      'type': 'restriction',
      'anchor': 'appointment',
      'timing': {'kind': 'window', 'start': '-PT2H', 'duration': 'PT2H'},
      'remind': {'kind': 'offset', 'offset': '-PT2H', 'defaulted': false},
      'allowNight': false,
      'pastDue': 'doNow',
      'text': 'Do not drive.',
    },
  ],
};

const _defaults = (
  evening: (hour: 20, minute: 0),
  quiet: (from: (hour: 23, minute: 0), to: (hour: 5, minute: 0)),
);

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

// Expected instants written in UTC, so they can't come from the code under
// test.
int utc(int y, int mo, int d, int h, [int mi = 0, int s = 0, int ms = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s, ms).millisecondsSinceEpoch;

// Effects of _module's steps for the 2026-11-01 07:30 EST appointment.
final _clearLiquidsEffect = utc(2026, 10, 31, 4); // Oct 31 00:00 EDT
final _dose2Effect = utc(2026, 11, 1, 6, 30); // 01:30 EST
final _stopLiquidsEffect = utc(2026, 11, 1, 10, 30); // 05:30 EST

// Record entries: effect and reminder time handed over.
final _c = (effect: _clearLiquidsEffect, at: utc(2026, 10, 31, 11)); // 07:00
final _dh = (effect: _dose2Effect, at: utc(2026, 11, 1, 0)); // 20:00 EDT
final _dm = (effect: _dose2Effect, at: utc(2026, 11, 1, 6, 30)); // 01:30 EST
final _s = (effect: _stopLiquidsEffect, at: utc(2026, 11, 1, 2, 59)); // 22:59

void main() {
  late tz.Location ny;
  late List<MethodCall> calls;
  late List<int> pendingIds;
  late Object? zonedScheduleError;
  // The stored record of handed reminders; the fake storage logs each load
  // and save into [calls], so their order against the plugin calls is
  // checked too.
  late Map<int, Handed> record;
  late Object? saveError;
  // Ids of _module's reminders: clear-liquids, dose2 heads-up, dose2 main,
  // stop-liquids.
  late int c, dh, dm, s;

  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  tz.TZDateTime appointment() => tz.TZDateTime(ny, 2026, 11, 1, 7, 30);
  tz.TZDateTime at(int ms) => tz.TZDateTime.fromMillisecondsSinceEpoch(ny, ms);

  Future<Map<int, Handed>> load() async {
    calls.add(const MethodCall('load'));
    return {...record};
  }

  Future<void> save(Map<int, Handed> next) async {
    calls.add(MethodCall('save', {...next}));
    if (saveError case final error?) throw error;
    record = {...next};
  }

  // The plugin checks for past dates against package:clock, so [clockAt]
  // fixes it; it defaults to [now]. A later [clockAt] is time that passed
  // between computing the reminders and handing them over. The device is in
  // New York unless [deviceOffset] says otherwise.
  Future<void> schedule(
    tz.TZDateTime appointment,
    tz.TZDateTime now, {
    int? clockAt,
    Map<String, Object?> module = _module,
    Duration Function(DateTime)? deviceOffset,
    tz.TZDateTime Function()? readNow,
  }) {
    final anchors = (appointment: appointment, arrival: null, discharge: null);
    final timeline = timelineOf([
      (module: parseModule(module), chosen: const <String, int>{}),
    ], anchors);
    final fixed = DateTime.fromMillisecondsSinceEpoch(
      clockAt ?? now.millisecondsSinceEpoch,
      isUtc: true,
    );
    return withClock(
      Clock.fixed(fixed),
      () => scheduleReminders(
        FlutterLocalNotificationsPlugin(),
        timeline,
        anchors,
        defaults: _defaults,
        clock: readNow ?? () => now,
        load: load,
        save: save,
        deviceOffset:
            deviceOffset ?? (at) => tz.TZDateTime.from(at, ny).timeZoneOffset,
      ),
    );
  }

  Map<Object?, Object?> args(MethodCall c) =>
      c.arguments as Map<Object?, Object?>;

  List<String> methods() => [for (final c in calls) c.method];

  List<Object?> bodies() => [
    for (final c in calls)
      if (c.method == 'zonedSchedule' || c.method == 'show') args(c)['body'],
  ];

  List<Object?> scheduledIds() => [
    for (final c in calls)
      if (c.method == 'zonedSchedule') args(c)['id'],
  ];

  List<Object?> shownIds() => [
    for (final c in calls)
      if (c.method == 'show') args(c)['id'],
  ];

  List<Object?> saves() => [
    for (final c in calls)
      if (c.method == 'save') c.arguments,
  ];

  // The instant the Android side rebuilds: it reads only the wall-clock
  // string and the zone name (FlutterLocalNotificationsPlugin.java:620).
  List<int> scheduledMs() {
    final scheduled = [
      for (final c in calls)
        if (c.method == 'zonedSchedule') args(c),
    ];
    expect(scheduled.map((a) => a['timeZoneName']), everyElement('Etc/UTC'));
    return [
      for (final a in scheduled)
        DateTime.parse('${a['scheduledDateTime']}Z').millisecondsSinceEpoch,
    ];
  }

  setUp(() async {
    calls = [];
    pendingIds = [];
    zonedScheduleError = null;
    record = {};
    saveError = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'zonedSchedule' && zonedScheduleError != null) {
            throw zonedScheduleError!;
          }
          if (call.method == 'pendingNotificationRequests') {
            return [
              for (final id in pendingIds)
                {'id': id, 'title': 'Prep step due', 'body': '', 'payload': ''},
            ];
          }
          return null;
        });
    // Learn the ids from a pass with every reminder ahead.
    await schedule(appointment(), tz.TZDateTime.utc(2026, 10, 1));
    [c, dh, dm, s] = scheduledIds().cast<int>();
    calls = [];
    record = {};
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('fall-back day, 2026-11-01, appointment 07:30 EST', () {
    final now = () => tz.TZDateTime.utc(2026, 10, 1);

    test(
      'every reminder at its exact UTC instant, in timeline order',
      () async {
        await schedule(appointment(), now());
        expect(scheduledMs(), [
          utc(2026, 10, 31, 11), // clear-liquids: Oct 31 07:00 EDT
          utc(2026, 11, 1, 0), // dose2 heads-up: Oct 31 20:00 EDT
          utc(2026, 11, 1, 6, 30), // dose2: second 01:30, EST, not EDT
          utc(2026, 11, 1, 2, 59), // stop-liquids: 04:30 EST moved to 22:59 EDT
        ]);
      },
    );

    test(
      'Android gets exactAllowWhileIdle and the generic title only',
      () async {
        await schedule(appointment(), now());
        expect(methods(), [
          'load',
          'pendingNotificationRequests',
          'save',
          ...List.filled(4, 'zonedSchedule'),
          'save',
        ]);
        for (final c in calls.where((c) => c.method == 'zonedSchedule')) {
          final a = args(c);
          final specifics = a['platformSpecifics'] as Map<Object?, Object?>;
          expect(specifics['scheduleMode'], 'exactAllowWhileIdle');
          expect(a['title'], 'Prep step due');
          expect(a['payload'], '');
        }
      },
    );

    test('each body states the effect time, "tomorrow" for the next local '
        'day', () async {
      await schedule(appointment(), now());
      expect(bodies(), [
        'Today', // clear-liquids: day step, Sat 07:00, starts Sat 00:00
        'Due tomorrow at 1:30 AM', // dose2 heads-up: Sat 20:00
        'Due at 1:30 AM', // dose2: Sun 01:30 EST, effect the same
        'Due tomorrow at 5:30 AM', // stop-liquids: Sat 22:59
      ]);
    });

    test(
      'a device an hour behind gets the hospital zone on every time',
      () async {
        // Chicago-like device: UTC-6 at every effect, New York UTC-5 or -4.
        await schedule(
          appointment(),
          now(),
          deviceOffset: (_) => const Duration(hours: -6),
        );
        expect(bodies(), [
          'Today', // no time stated, so no zone
          'Due tomorrow at 1:30 AM EST',
          'Due at 1:30 AM EST',
          'Due tomorrow at 5:30 AM EST',
        ]);
      },
    );
  });

  test('body wording by timing kind and day distance', () async {
    // Appointment Tue 2026-11-10 14:00 EST; no clock change nearby.
    await schedule(
      tz.TZDateTime(ny, 2026, 11, 10, 14),
      tz.TZDateTime.utc(2026, 10, 1),
      module: _kinds,
    );
    expect(bodies(), [
      'Today', // hold: day -7, Tue Nov 3 07:00, starts Nov 3 00:00
      'Due at 9:00 PM', // mix: dayAt, Mon 20:00, effect Mon 21:00
      'Starts tomorrow', // no-food: day 0, Mon 20:00, starts Tue 00:00
      'Due by tomorrow at 8:00 AM', // finish: deadline, Mon 20:00
      'Due Tue, Nov 10 at 11:00 AM', // far: offset, Sun Nov 8 11:00
      'Starts at 12:00 PM', // no-driving: window, Tue 12:00
    ]);
  });

  test(
    'the zone is added only where the offsets differ at the effect',
    () async {
      // A device fixed at UTC-5 matches New York's EST, not its EDT.
      await schedule(
        tz.TZDateTime(ny, 2027, 3, 14, 7, 30),
        tz.TZDateTime.utc(2027, 3, 1),
        deviceOffset: (_) => const Duration(hours: -5),
      );
      expect(bodies(), [
        'Today',
        'Due tomorrow at 12:30 AM', // effect 00:30 EST
        'Due at 12:30 AM',
        'Due tomorrow at 5:30 AM EDT', // effect 05:30 EDT
      ]);
    },
  );

  test('spring-forward day, 2027-03-14, appointment 07:30 EDT', () async {
    await schedule(
      tz.TZDateTime(ny, 2027, 3, 14, 7, 30),
      tz.TZDateTime.utc(2027, 3, 1),
    );
    expect(scheduledMs(), [
      utc(2027, 3, 13, 12), // clear-liquids: Mar 13 07:00 EST
      utc(2027, 3, 14, 1), // dose2 heads-up: Mar 13 20:00 EST
      utc(2027, 3, 14, 5, 30), // dose2: 00:30 EST
      utc(2027, 3, 14, 3, 59), // stop-liquids: 04:30 EDT moved to 22:59 EST
    ]);
    expect(bodies(), [
      'Today', // clear-liquids: day step, Sat 07:00, starts Sat 00:00
      'Due tomorrow at 12:30 AM', // dose2 heads-up: Sat 20:00 EST
      'Due at 12:30 AM', // dose2: Sun 00:30 EST, effect the same
      'Due tomorrow at 5:30 AM', // stop-liquids: Sat 22:59 EST
    ]);
  });

  test('afternoon effects read PM, noon reads 12:00 PM', () async {
    // Appointment Tue 2026-10-20 18:00 EDT.
    await schedule(
      tz.TZDateTime(ny, 2026, 10, 20, 18),
      tz.TZDateTime.utc(2026, 10, 1),
    );
    expect(bodies(), [
      'Today', // clear-liquids: day step, Mon 07:00
      'Due at 12:00 PM', // dose2: Tue 12:00, no heads-up
      'Due at 4:00 PM', // stop-liquids: Tue 15:00, effect Tue 16:00
    ]);
  });

  test('ids are stable across reschedules and unique', () async {
    await schedule(
      tz.TZDateTime(ny, 2027, 3, 14, 7, 30),
      tz.TZDateTime.utc(2027, 3, 1),
    );
    expect(scheduledIds(), [c, dh, dm, s]);
    expect({c, dh, dm, s}, hasLength(4));
  });

  group('delivery record', () {
    // 04:40:00.123 EST on the appointment day: stop-liquids' reminder (22:59
    // EDT) has passed and its effect (05:30 EST) is ahead; dose2 and
    // clear-liquids are in effect.
    final lateNow = utc(2026, 11, 1, 9, 40, 0, 123);
    // A late reminder is handed over at now.
    final sLate = (effect: _stopLiquidsEffect, at: lateNow);

    test(
      'T1 first computation: a late reminder is shown once and recorded',
      () async {
        await schedule(appointment(), at(lateNow), clockAt: lateNow + 1);
        expect(methods(), [
          'load',
          'pendingNotificationRequests',
          'save',
          'show',
          'save',
        ]);
        expect(saves(), [
          <int, Handed>{},
          {s: sLate},
        ]);
        expect(shownIds(), [s]);
        expect(args(calls[3])['title'], 'Prep step due');
        expect(bodies(), ['Due at 5:30 AM']);
      },
    );

    test('T2 reopen after the reminder fired: not shown again', () async {
      record = {s: _s};
      await schedule(appointment(), at(lateNow));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'save',
      ]);
      expect(saves(), [
        {s: _s},
        {s: _s},
      ]);
    });

    test('T3 a heads-up that fired is skipped, future ones re-handed, '
        'expired entries pruned', () async {
      // 20:30 EDT Oct 31: the heads-up (20:00 EDT) has fired; dose2 and
      // stop-liquids are ahead; clear-liquids is in effect.
      record = {c: _c, dh: _dh, dm: _dm, s: _s};
      pendingIds = [dm, s];
      await schedule(appointment(), at(utc(2026, 11, 1, 0, 30)));
      final kept = {dh: _dh, dm: _dm, s: _s};
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'zonedSchedule',
        'zonedSchedule',
        'save',
      ]);
      expect(saves(), [kept, kept]);
      expect(scheduledIds(), [dm, s]);
      expect(scheduledMs(), [utc(2026, 11, 1, 6, 30), utc(2026, 11, 1, 2, 59)]);
    });

    test('T4 force-stopped past the reminder: still pending, so cancelled '
        'and shown', () async {
      record = {s: _s};
      pendingIds = [s];
      await schedule(appointment(), at(lateNow));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'cancel',
        'show',
        'save',
      ]);
      expect(saves(), [
        <int, Handed>{},
        {s: sLate},
      ]);
      expect(args(calls[3]), {'id': s, 'tag': null});
      expect(shownIds(), [s]);
    });

    test('T5 reschedule: a moved effect is a new reminder', () async {
      // Recorded for the old appointment, 08:30 EST: effect 06:30 EST.
      final old = (
        effect: utc(2026, 11, 1, 11, 30),
        at: utc(2026, 11, 1, 3, 59),
      );
      record = {s: old};
      await schedule(appointment(), at(lateNow));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'show',
        'save',
      ]);
      expect(saves(), [
        {s: old},
        {s: sLate},
      ]);
      expect(shownIds(), [s]);
    });

    test('T6 a stale id is removed from the record before it is cancelled; '
        'current ones kept', () async {
      const stale = 12345;
      final all = {c: _c, dh: _dh, dm: _dm, s: _s};
      record = {
        ...all,
        stale: (effect: utc(2026, 11, 2, 0), at: utc(2026, 11, 2, 0)),
      };
      pendingIds = [c, stale, s];
      await schedule(appointment(), tz.TZDateTime.utc(2026, 10, 1));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'cancel',
        ...List.filled(4, 'zonedSchedule'),
        'save',
      ]);
      expect(saves(), [all, all]);
      expect(args(calls[3]), {'id': stale, 'tag': null});
      expect(scheduledIds(), [c, dh, dm, s]);
    });

    test('T7 a reminder that passes between computing and scheduling is '
        'shown and recorded', () async {
      // now 22:58:59.999 EDT: stop-liquids' reminder (22:59:00.000 EDT) is
      // ahead of now but 1 ms behind the clock when the plugin checks it.
      // dose2's heads-up has passed, so it fires at now.
      await schedule(
        appointment(),
        at(utc(2026, 11, 1, 2, 58, 59, 999)),
        clockAt: utc(2026, 11, 1, 2, 59, 0, 1),
      );
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'show', // dose2 heads-up
        'zonedSchedule', // dose2
        'show', // stop-liquids
        'save',
      ]);
      expect(shownIds(), [dh, s]);
      expect(scheduledMs(), [utc(2026, 11, 1, 6, 30)]);
      expect(bodies(), [
        'Due tomorrow at 1:30 AM',
        'Due at 1:30 AM',
        'Due tomorrow at 5:30 AM',
      ]);
      expect(saves().last, {
        dh: (effect: _dose2Effect, at: utc(2026, 11, 1, 2, 58, 59, 999)),
        dm: _dm,
        s: _s,
      });
    });

    test('T8 any other scheduling error propagates, no final save', () async {
      zonedScheduleError = PlatformException(
        code: 'exact_alarms_not_permitted',
      );
      await expectLater(
        schedule(appointment(), tz.TZDateTime.utc(2026, 10, 1)),
        throwsA(isA<PlatformException>()),
      );
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'zonedSchedule',
      ]);
    });

    test('T9 a failed save propagates before anything is cancelled or '
        'handed', () async {
      saveError = const FileSystemException('disk full');
      pendingIds = [12345];
      await expectLater(
        schedule(appointment(), tz.TZDateTime.utc(2026, 10, 1)),
        throwsA(isA<FileSystemException>()),
      );
      expect(methods(), ['load', 'pendingNotificationRequests', 'save']);
    });

    test('T10 property, 200 seeds: each reminder is delivered at most once; '
        'exactly once without a force-stop', () async {
      for (var seed = 0; seed < 200; seed++) {
        final random = Random(seed);
        // A fake phone: the alarms Android holds (id -> fire instant), the
        // plugin's pending list, and the deliveries per id. One appointment
        // per seed, so an id stands for one (id, effect).
        final alarms = <int, int>{};
        final listed = <int>{};
        final delivered = <int, int>{};
        void deliver(int id) =>
            delivered.update(id, (n) => n + 1, ifAbsent: () => 1);
        void fireUntil(int ms) {
          final due = [
            for (final MapEntry(key: id, value: fireAt) in alarms.entries)
              if (fireAt <= ms) id,
          ];
          for (final id in due) {
            alarms.remove(id);
            listed.remove(id);
            deliver(id);
          }
        }

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'zonedSchedule':
                  final a = args(call);
                  final id = a['id'] as int;
                  alarms[id] = DateTime.parse('${a['scheduledDateTime']}Z')
                      .millisecondsSinceEpoch;
                  listed.add(id);
                case 'show':
                  deliver(args(call)['id'] as int);
                case 'cancel':
                  final id = args(call)['id'] as int;
                  alarms.remove(id);
                  listed.remove(id);
                case 'pendingNotificationRequests':
                  return [
                    for (final id in listed)
                      {
                        'id': id,
                        'title': 'Prep step due',
                        'body': '',
                        'payload': '',
                      },
                  ];
              }
              return null;
            });
        record = {};
        // Opens between Oct 29 00:00Z and the appointment (12:30Z).
        final from = utc(2026, 10, 29, 0);
        final span = utc(2026, 11, 1, 12, 30) - from;
        final count = 1 + random.nextInt(6);
        final opens = [
          for (var i = 0; i < count; i++) from + random.nextInt(span),
        ]..sort();
        var forceStopped = false;
        late Set<Object?> firstHanded;
        for (final (i, open) in opens.indexed) {
          if (i > 0 && random.nextInt(4) == 0) {
            final stop = opens[i - 1] + random.nextInt(open - opens[i - 1] + 1);
            fireUntil(stop);
            alarms.clear(); // Android cancels the alarms; the list keeps them.
            forceStopped = true;
          }
          fireUntil(open);
          calls = [];
          await schedule(appointment(), at(open));
          if (i == 0) firstHanded = {...scheduledIds(), ...shownIds()};
        }
        fireUntil(utc(2027, 1, 1, 0));
        final reason = 'seed $seed, opens $opens, delivered $delivered';
        expect(delivered.values, everyElement(1), reason: reason);
        if (!forceStopped) {
          expect(delivered.keys.toSet(), firstHanded, reason: reason);
        }
      }
    });

    // 01:30:00.500 EST: dose2 (effect and reminder 01:30 EST) has just taken
    // effect; its alarm is due but may still be firing. stop-liquids'
    // reminder has passed and was delivered.
    final raceNow = utc(2026, 11, 1, 6, 30, 0, 500);

    test('T11 delivery race: a due reminder of a step that just took effect, '
        'same effect as recorded, stays pending', () async {
      record = {dh: _dh, dm: _dm, s: _s};
      pendingIds = [dm];
      await schedule(appointment(), at(raceNow));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'save',
      ]);
      // dm keeps its entry while it is still pending; dh has passed.
      final kept = {dm: _dm, s: _s};
      expect(saves(), [kept, kept]);
    });

    // dose2's main reminder cancelled as stale, its entry dropped; only
    // stop-liquids stays recorded.
    void expectDoseCancelled() {
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'cancel',
        'save',
      ]);
      expect(args(calls[3]), {'id': dm, 'tag': null});
      expect(saves(), [
        {s: _s},
        {s: _s},
      ]);
    }

    test('T12 delivery race after a reschedule moved the effect: '
        'cancelled', () async {
      // Recorded for the old appointment, 08:30 EST: dose2 at 02:30 EST.
      record = {
        dm: (effect: utc(2026, 11, 1, 7, 30), at: utc(2026, 11, 1, 7, 30)),
        s: _s,
      };
      pendingIds = [dm];
      await schedule(appointment(), at(raceNow));
      expectDoseCancelled();
    });

    // clear-liquids takes effect Oct 31 00:00 EDT and is reminded at 07:00
    // EDT (11:00Z), after its effect. The other three are ahead.
    Map<int, Handed> allFour() => {c: _c, dh: _dh, dm: _dm, s: _s};

    test('T13 a Scheduled id keeps its entry after its effect: clear-liquids '
        'at 06:59', () async {
      record = {c: _c};
      await schedule(appointment(), at(utc(2026, 10, 31, 10, 59)));
      expect(saves(), [
        {c: _c},
        allFour(),
      ]);
      expect(scheduledIds(), [c, dh, dm, s]);
    });

    test('T14 clear-liquids at exactly 07:00, after its alarm fired: shown '
        'once, not twice', () async {
      // The 07:00 alarm fired: c left the pending list, delivered once.
      record = allFour();
      pendingIds = [dh, dm, s];
      await schedule(appointment(), at(utc(2026, 10, 31, 11)));
      expect(shownIds(), isEmpty, reason: 'the alarm already delivered it');
      expect(saves(), [allFour(), allFour()]);
      expect(scheduledIds(), [dh, dm, s]);
    });

    // dose2's alarm (01:30 EST) still pending, recorded for the same effect.
    Future<void> raceAt(int nowMs) {
      calls = [];
      record = {dh: _dh, dm: _dm, s: _s};
      pendingIds = [dm];
      return schedule(appointment(), at(nowMs));
    }

    test('T15 due 10 s ago, still pending: kept', () async {
      await raceAt(utc(2026, 11, 1, 6, 30, 10));
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'save',
      ]);
      expect(saves(), [
        {dm: _dm, s: _s},
        {dm: _dm, s: _s},
      ]);
    });

    test('T16 due 5 min ago, still pending (a force-stop): cancelled as '
        'stale', () async {
      await raceAt(utc(2026, 11, 1, 6, 35));
      expectDoseCancelled();
    });

    test('T18 grace boundary: due exactly 60 s ago kept, 60.001 s ago '
        'cancelled', () async {
      await raceAt(utc(2026, 11, 1, 6, 31));
      expect(methods(), isNot(contains('cancel')), reason: '60 s');
      await raceAt(utc(2026, 11, 1, 6, 31, 0, 1));
      expect(methods(), contains('cancel'), reason: '60.001 s');
    });

    test('two overlapping passes run one after the other', () async {
      final first = schedule(appointment(), at(lateNow));
      final second = schedule(appointment(), at(lateNow));
      await Future.wait([first, second]);
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'show',
        'save',
        'load', // only after the first pass's final save
        'pendingNotificationRequests',
        'save',
        'save',
      ]);
      expect(shownIds(), [s]);
    });

    test('a queued pass reads the time when it starts, not when it was '
        'queued', () async {
      // Queued at Oct 1, when every reminder was ahead; it starts at 04:40
      // EST, after the first pass has shown stop-liquids.
      var current = tz.TZDateTime.utc(2026, 10, 1);
      final first = schedule(appointment(), at(lateNow));
      final second = schedule(
        appointment(),
        at(lateNow),
        readNow: () => current,
      );
      current = at(lateNow);
      await Future.wait([first, second]);
      expect(methods(), [
        'load',
        'pendingNotificationRequests',
        'save',
        'show',
        'save',
        'load',
        'pendingNotificationRequests',
        'save',
        'save',
      ]);
      expect(record, {s: sLate});
    });

    test('a failed pass does not block the next one', () async {
      saveError = const FileSystemException('disk full');
      final first = schedule(appointment(), at(lateNow));
      final second = schedule(appointment(), at(lateNow));
      await expectLater(first, throwsA(isA<FileSystemException>()));
      saveError = null;
      await second;
      expect(shownIds(), [s]);
      expect(record, {s: sLate});
    });
  });

  group('record file', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('handed');
      file = File('${dir.path}/handed.json');
    });

    tearDown(() => dir.delete(recursive: true));

    test(
      'round trip over an existing file, through a temporary file',
      () async {
        await saveRecord(file, {1: (effect: 1, at: 1)});
        await saveRecord(file, {12: _s, 7: (effect: 0, at: -1)});
        expect(await loadRecord(file), {12: _s, 7: (effect: 0, at: -1)});
        expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
          'handed.json',
        ]);
      },
    );

    test('a missing, unreadable or corrupt file reads as empty', () async {
      expect(await loadRecord(file), <int, Handed>{});
      for (final corrupt in [
        '',
        '{',
        '[]',
        '{"x": {"effect": 1, "at": 1}}',
        '{"1": "2"}',
        '{"1": {"effect": 1}}',
        '{"1": {"effect": 1, "at": "1"}}',
      ]) {
        await file.writeAsString(corrupt);
        expect(await loadRecord(file), <int, Handed>{}, reason: corrupt);
      }
    });

    test(
      'T17 a file in the old {"<id>": effectMs} format reads as empty',
      () async {
        await file.writeAsString('{"12": ${utc(2026, 11, 1, 10, 30)}}');
        expect(await loadRecord(file), <int, Handed>{});
      },
    );
  });
}
