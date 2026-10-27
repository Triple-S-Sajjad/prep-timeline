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

void main() {
  late tz.Location ny;
  late List<MethodCall> calls;
  late List<int> pendingIds;
  late Object? zonedScheduleError;

  setUpAll(() {
    tzdata.initializeTimeZones();
    ny = tz.getLocation('America/New_York');
  });

  setUp(() {
    calls = [];
    pendingIds = [];
    zonedScheduleError = null;
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
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

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
        now: now,
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

  group('fall-back day, 2026-11-01, appointment 07:30 EST', () {
    final appointment = () => tz.TZDateTime(ny, 2026, 11, 1, 7, 30);
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
          ...List.filled(4, 'zonedSchedule'),
          'pendingNotificationRequests',
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
      tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
      tz.TZDateTime.utc(2026, 10, 1),
    );
    final first = scheduledIds();
    calls.clear();
    await schedule(
      tz.TZDateTime(ny, 2027, 3, 14, 7, 30),
      tz.TZDateTime.utc(2027, 3, 1),
    );
    expect(scheduledIds(), first);
    expect(first.toSet(), hasLength(4));
  });

  test('a late reminder is shown at once, never dropped', () async {
    // 04:40:00.123 EST: stop-liquids' reminder (22:59 EDT) has passed and its
    // effect (05:30 EST) is ahead; dose2 and clear-liquids are in effect. The
    // reminder fires at now; 1 ms passes before the plugin checks it.
    await schedule(
      tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
      tz.TZDateTime.fromMillisecondsSinceEpoch(
        ny,
        utc(2026, 11, 1, 9, 40, 0, 123),
      ),
      clockAt: utc(2026, 11, 1, 9, 40, 0, 124),
    );
    expect(methods(), ['show', 'pendingNotificationRequests']);
    expect(args(calls.first)['title'], 'Prep step due');
    expect(bodies(), ['Due at 5:30 AM']);
  });

  test(
    'a reminder that passes between computing and scheduling is shown',
    () async {
      // now 22:58:59.999 EDT: stop-liquids' reminder (22:59:00.000 EDT) is
      // ahead of now but 1 ms behind the clock when the plugin checks it.
      // dose2's heads-up has passed, so it fires at now, also behind the clock.
      await schedule(
        tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
        tz.TZDateTime.fromMillisecondsSinceEpoch(
          ny,
          utc(2026, 11, 1, 2, 58, 59, 999),
        ),
        clockAt: utc(2026, 11, 1, 2, 59, 0, 1),
      );
      expect(methods(), [
        'show', // dose2 heads-up
        'zonedSchedule', // dose2
        'show', // stop-liquids
        'pendingNotificationRequests',
      ]);
      expect(scheduledMs(), [utc(2026, 11, 1, 6, 30)]);
      expect(bodies(), [
        'Due tomorrow at 1:30 AM',
        'Due at 1:30 AM',
        'Due tomorrow at 5:30 AM',
      ]);
    },
  );

  test('any other scheduling error propagates, nothing shown', () async {
    zonedScheduleError = PlatformException(code: 'exact_alarms_not_permitted');
    await expectLater(
      schedule(
        tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
        tz.TZDateTime.utc(2026, 10, 1),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(methods(), ['zonedSchedule']);
  });

  test('stale alarms are cancelled one by one, current ones kept', () async {
    const stale = 12345;
    await schedule(
      tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
      tz.TZDateTime.utc(2026, 10, 1),
    );
    final current = scheduledIds();
    calls.clear();
    pendingIds = [current[0] as int, stale, current[3] as int];
    await schedule(
      tz.TZDateTime(ny, 2026, 11, 1, 7, 30),
      tz.TZDateTime.utc(2026, 10, 1),
    );
    expect(methods(), [
      ...List.filled(4, 'zonedSchedule'),
      'pendingNotificationRequests',
      'cancel',
    ]);
    expect(args(calls.last), {'id': stale, 'tag': null});
  });
}
