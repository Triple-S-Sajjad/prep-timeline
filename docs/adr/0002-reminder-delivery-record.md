# 2. Reminder delivery record

Date: 2026-11-11

## Context

Every scheduling pass treated each late reminder as never sent, because nothing was stored, so a late reminder fired again on every app open. The fix lives in `apps/patient/lib/scheduler.dart`.

## Decision

The app keeps a record of reminders handed to the phone: notification id -> (effect, at): the effect instant of the reminder handed under that id and the time it was handed over for, both UTC ms. A late reminder is handed over at the pass's now, so that is its `at`. Keying on the effect means a reschedule or arrival entry that moves the effect counts as a new reminder. A late reminder is skipped only if the record holds the same id and effect and the id is absent from `pendingNotificationRequests()`. In `flutter_local_notifications` 22.3.3 a scheduled entry leaves that list only when it fires, is cancelled, or fails to re-register at boot.

Pass order: load the record -> `pendingNotificationRequests` -> save (record minus expired and to-be-cancelled ids) -> cancel stale ids (except a reminder still being delivered, below) -> for each reminder: future: `zonedSchedule`; late and still pending: `cancel(id)` then `show`; late and delivered: skip; late and not in the record: `show` -> save the final record.

- Save after handing over, never before. A crash then causes a duplicate, never a drop. Removals are saved before cancelling for the same reason. If a save fails, the error propagates.
- Drop entries whose effect is at or before now, plus every id the pass cancels. Never drop the entry of an id that is Scheduled in the current pass, even if its effect has passed: a day step's own-day morning reminder comes after its effect, and without its entry a pass at exactly that minute, after the alarm fired, would show it a second time.
- Delivery race: a pending id that is no longer handed over is stale and cancelled, except when the same id is still in this pass's timeline with the same effect as in the record and its recorded `at` is at most 60 s before now (inclusive) and not after now. The alarm may then be firing at this moment, and cancelling it would drop the reminder. It stays pending and keeps its entry. Past the 60 s window it is cancelled as stale and not shown: a reminder still pending that long after its time was dropped by Android (force-stop), and the plugin's boot receiver could otherwise fire it after its step took effect. It is still cancelled if its step left the timeline or its effect changed (reschedule, arrival entry), because then it would fire for an effect that no longer holds.
- One scheduling pass at a time: a second call waits for the first to finish, and loads the record only then, so it sees what the first handed over.
- An unreadable or corrupt record file counts as empty, so the risk is duplicates, never drops. So does a file in the earlier `{"<id>": effectMs}` format.
- When an open finds exact alarms off (banner path), the record is cleared, so the next pass shows every late reminder (duplicates possible).
- Nothing the app stores is backed up to the cloud: `android:allowBackup="false"` plus `dataExtractionRules` that exclude every domain from cloud backup and device transfer. Otherwise Auto Backup copies the appointment and the record to Google Drive. A reinstall or a new phone equals a first install: the patient scans the code again.

## Storage

`path_provider` gives the app support directory; the record is `<applicationSupportDirectory>/handed.json` as `{"<id>": effectMs}`, written through `dart:io` to a `.tmp` file and then renamed. The cached protocol bundle will need a file directory too, so one package covers both. `shared_preferences` 2.5.6 was the alternative: fine for this map, not for bundle bytes.

Sensitivity: an effect instant reveals the appointment time. It sits beside the appointment, which is stored anyway (see [data inventory](../data-inventory.md)).

## Situations

- First install, or a code scanned late: empty record -> late reminders show once. This is the spec's "fires at once".
- Reschedule: effect changes -> no match -> a late one shows; future ones are re-handed. Ids that left the timeline and are still pending are cancelled and their entries removed.
- Reboot, permission on: the plugin's boot receiver re-registers cached alarms, and past ones fire at boot and leave the list. The next open skips them.
- Force-stop or revoked permission: Android cancels the alarms but the plugin's list keeps them. At the next open, future ones are re-handed, and late ones are still pending -> cancel + show. Without the cancel, the boot receiver would fire the stale entry again.
- Revoke, then reboot: the boot receiver hits `ExactAlarmPermissionException` and deletes the entries unfired, so they look delivered. An open with exact alarms off clears the record (above).
- Revoke -> reboot -> re-grant in Settings -> open, with no open in between: a reminder whose time passed meanwhile is dropped, because the plugin deleted it at boot and no open cleared the record. Accepted and documented in the spec's Android bullet; detecting the boot would need native code.
- App data cleared: the record, the plugin list, alarms, the appointment and the bundle all go. The patient re-scans, which is a first computation.

## Packages

`path_provider` 2.1.6 and `jni` 1.1.1 (override) are listed with their reasons in [ADR 1](0001-repository-tooling.md#packages-and-tools).
