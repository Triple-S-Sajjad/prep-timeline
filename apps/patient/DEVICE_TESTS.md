# Device tests: notification spike (Android)
Pass bar: scheduled <= fired < scheduled + 60 s. "fired" = the notification's `when` from dumpsys notification (the plugin doesn't set `when`, so it's the build time at firing). Record scheduled, fired and pass/fail for every reminder.

## Setup, per emulator (-s emulator-55xx)
- emulator -avd api36 -no-snapshot ; emulator -avd api26_2gb -memory 2048 -no-snapshot
- adb root; adb shell settings put global auto_time 0; adb shell settings put global auto_time_zone 0; adb shell setprop persist.sys.timezone America/New_York; check adb shell date shows EDT/EST.
- From apps/patient: flutter run -d <device>; tap Initialize.
- api36 only: adb shell pm grant com.example.patient android.permission.POST_NOTIFICATIONS; adb shell appops set com.example.patient SCHEDULE_EXACT_ALARM allow
- Scheduled: adb shell dumpsys alarm | grep -A4 com.example.patient
- Fired: adb shell dumpsys notification --noredact | grep -E "pkg=com.example.patient|when="

## Cases (tap "+2/+4/+6" first unless noted)
1. Swiped away: swipe the app off in recents; adb shell pidof com.example.patient prints nothing.
2. Force-stopped: adb shell am force-stop com.example.patient. Expected to fail (Android cancels the app's alarms); record it.
3. Reboot: adb reboot; adb wait-for-device; dumpsys alarm shows them again.
4. Doze: adb shell dumpsys battery unplug; adb shell input keyevent KEYCODE_SLEEP; adb shell dumpsys deviceidle force-idle; check adb shell dumpsys deviceidle get deep = IDLE. After: adb shell dumpsys deviceidle unforce; adb shell dumpsys battery reset.
5. api36 only, exact alarms: (a) appops ... SCHEDULE_EXACT_ALARM deny, tap schedule: expect "Failed: exact_alarms_not_permitted", dumpsys alarm empty, no inexact alarm. (b) allow, schedule, then deny: expect nothing fires; then run case 3 after it.
6. Fall-back: adb shell date -u 110105502026.00 (05:50Z = 01:50 EDT); tap "fall-back": log shows 2026-11-01T06:05:00.000Z; expect when in [06:05:00Z, 06:06:00Z), not an immediate fire. Then setprop persist.sys.timezone America/Chicago, reschedule: body ends "EST".
7. api26_2gb only: in Doze (case 4 steps), schedule 3 reminders 1 minute apart, once with exactAllowWhileIdle and once with AndroidScheduleMode.alarmClock. Record which mode meets the bar. A debug-only switch for the mode is allowed; no release behavior change.
8. api26_2gb, after cases 1-3: adb shell dumpsys meminfo com.example.patient; record TOTAL PSS.
