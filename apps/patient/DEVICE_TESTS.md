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

## Delivery record cases (ADR 2; not run yet)
Each debug step takes effect 30 minutes after its reminder, so a late reminder still has its effect ahead. "Reopen" runs a new pass for the last times at the current time, as an app open would. Record ids and `when` from dumpsys notification after every step.
9. Reopen after a fire: tap "+2/+4/+6"; after reminder 1 fires, tap Reopen. Expect no new notification for reminder 1 (same `when`), reminders 2 and 3 still in dumpsys alarm. After all three fire, tap Reopen: nothing new.
10. Force-stop past a reminder: tap "+2/+4/+6"; adb shell am force-stop com.example.patient before reminder 1; wait until just after reminder 2's time; launch the app, tap Reopen. Expect reminders 1 and 2 shown at once (`when` = reopen time), reminder 3 back in dumpsys alarm. Tap Reopen again: no second reminder 1 or 2.
11. api36 only, revoke + reboot: tap "+2/+4/+6"; appops ... SCHEDULE_EXACT_ALARM deny; adb reboot before reminder 1; wait until after reminder 1's time. (a) Launch, tap Initialize (log shows exact: false), then allow, tap Reopen: expect reminder 1 shown at once, reminders 2 and 3 in dumpsys alarm if still ahead. (b) Repeat, but allow before launching, then tap Initialize and Reopen: expect reminder 1 not shown (accepted loss, spec's Android bullet); record it.
