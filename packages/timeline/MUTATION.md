# Surviving mutants

Mutation runs so far:

- Slices 1–3 (`duration.dart`, `clock.dart`, `offset.dart`, `limits.dart`): 28 mutants, none survive. "5-digit minutes accepted" and "'P2H' (no T) accepted" survived the first run; "rejected durations" in `test/duration_test.dart` now kills them with "PT99999M" and "P2H".
- Slice 4a (`timing.dart`, `calendar.dart`): 18 mutants, none survive.
- Slice 4b (`reminder.dart`): 39 mutants, 1 survives. "Heads-up allowed at the quiet start itself" survived the first run; test 41 in `test/reminder_test.dart` now kills it.
- Slice 4c (`past_due.dart`): 10 mutants, 2 survive. Re-run after `pastDueOf` took the whole `TimedStep`: 11 mutants, the same 2 survive.
- Slice 5a (`protocol.dart`): 34 mutants, none survive. 13 survived the first run; in `test/protocol_test.dart`, test 15 kills the sha256 format mutants, the two new tests in group 4 kill the dropped and non-string group module IDs, tests 16 and 17 kill "minutes ignored", tests 18 to 20 kill the parameter range, unit and chosen-value mutants, and test 21 kills "timed by remind instead of timing". Re-run after steps with timed fields but no timing were rejected and malformed parameters became a FormatException: 43 mutants, none survive. "timed by remind instead of timing" survived the first re-run, since test 21's step still had its other timed fields; test 25 now kills it. Re-run with only `test/protocol_test.dart`, the file its mutants list names: 43 mutants, none survive.

Each `tool/mutants/<source>.txt` starts with a `tests:` line naming the test files run for its mutants: every file that uses the source directly, through a source that imports it, or through `test/support.dart`.

The survivors:

- `lib/src/reminder.dart` `_quietStart`: `to < from` → `to <= from` (quiet hours that start and end at the same time treated as wrapping midnight). Differs only when quietHours from equals to, which the validator's `emptyRange` check rejects; `fixtures/invalid/empty-quiet-hours-umms` proves it and fails on nothing else.
- `lib/src/past_due.dart` `pastDueOf`: `discharge: null` → `discharge: appointment`. Discharge-anchored steps return before the effect is computed, and `effectOf` reads only the step's own anchor, so the discharge value is never read.
- `lib/src/past_due.dart` `pastDueOf`: `effectOf(step.anchor, …)` → `effectOf(Anchor.appointment, …)` (every step counted from the appointment). Arrival is set to the appointment, so an arrival step's anchor is the same instant either way, and discharge steps never get here.
