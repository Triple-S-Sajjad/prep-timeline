# Surviving mutants

Mutation runs so far:

- Slices 1–3 (`duration.dart`, `clock.dart`, `offset.dart`, `limits.dart`): 28 mutants, none survive. "5-digit minutes accepted" and "'P2H' (no T) accepted" survived the first run; "rejected durations" in `test/duration_test.dart` now kills them with "PT99999M" and "P2H".
- Slice 4a (`timing.dart`, `calendar.dart`): 18 mutants, none survive.
- Slice 4b (`reminder.dart`): 39 mutants, 1 survives. "Heads-up allowed at the quiet start itself" survived the first run; test 41 in `test/reminder_test.dart` now kills it.
- Slice 4c (`past_due.dart`): 10 mutants, 2 survive. Re-run after `pastDueOf` took the whole `TimedStep`: 11 mutants, the same 2 survive.
- Slice 5a (`protocol.dart`): 34 mutants, none survive. 13 survived the first run; in `test/protocol_test.dart`, test 15 kills the sha256 format mutants, the two new tests in group 4 kill the dropped and non-string group module IDs, tests 16 and 17 kill "minutes ignored", tests 18 to 20 kill the parameter range, unit and chosen-value mutants, and test 21 kills "timed by remind instead of timing". Re-run after steps with timed fields but no timing were rejected and malformed parameters became a FormatException: 43 mutants, none survive. "timed by remind instead of timing" survived the first re-run, since test 21's step still had its other timed fields; test 25 now kills it. Re-run with only `test/protocol_test.dart`, the file its mutants list names: 43 mutants, none survive.
- Slice 5b (`selection.dart`): 34 mutants, 2 survive. 6 survived the first run, and each was handled:
  - "Unknown or base module accepted" showed a check that repeated the stage check: an unknown or base module has no stage, so the stage check already rejects it. The repeated check is gone.
  - "Zone compared by offset, not name" was written wrong: it compared a number with a `Duration`, so it changed nothing. Fixed, and test 25's Detroit case kills it.
  - "Bookable minutes ignored": test 32's new 07:30 to 16:45 case kills it.
  - "Ties left to an unstable sort": Dart's `List.sort` is stable only up to 32 entries. The new test 35, with 40 steps, kills it.
  - The other two are the survivors listed below.
- Re-run after a missing module and a base module with parameters became an ArgumentError: 40 mutants, the same 2 survive. The 6 new mutants (a null-check crash at each of the three module lookups, the missing module not named, a base module with parameters accepted, and a broken bundle hidden outside bookable hours) are killed by tests 36 and 37 in `test/selection_test.dart`.
- Slice 5c (`reschedule` in `selection.dart`): 54 mutants, the same 2 survive. The 14 new mutants are killed on the first run by tests 38 to 47 in `test/selection_test.dart`. They cover:
  - each zone, discharge and not-after-now check
  - the same-time no-op
  - the ignore level and the old-time and new-time past-due tests
  - the old time judged with the entered arrival
  - a discharge step judged with the discharge at the appointment
  - the anchors after a move and after a block
  - the reported reason
- Re-run after first entry (`selectedModules`) took the current time and returned `TimeNotAhead`: 57 mutants, the same 2 survive. The time check moved from `reschedule` into `selectedModules`, so the 2 mutants on it were moved there too. 3 new mutants are killed by test 48 in `test/selection_test.dart`: bookable hours checked before the time, appliesWhen checked before the time, and a broken bundle hidden by a time not after now.
- Slice 6 (`bundle.dart`): 27 mutants, none survive. "Long key accepted" survived the first run: with a valid signature the library itself rejects a 33-byte key, so only test 10's 1-byte key with protocol.sig missing reached our check. Test 10 now also passes a 33-byte key with protocol.sig missing, which kills it.

Each `tool/mutants/<source>.txt` starts with a `tests:` line naming the test files run for its mutants: every file that uses the source directly, through a source that imports it, or through `test/support.dart`.

The survivors:

- `lib/src/reminder.dart` `_quietStart`: `to < from` → `to <= from` (quiet hours that start and end at the same time treated as wrapping midnight). Differs only when quietHours from equals to, which the validator's `emptyRange` check rejects; `fixtures/invalid/empty-quiet-hours-umms` proves it and fails on nothing else.
- `lib/src/past_due.dart` `pastDueOf`: `discharge: null` → `discharge: appointment`. Discharge-anchored steps return before the effect is computed, and `effectOf` reads only the step's own anchor, so the discharge value is never read.
- `lib/src/past_due.dart` `pastDueOf`: `effectOf(step.anchor, …)` → `effectOf(Anchor.appointment, …)` (every step counted from the appointment). Arrival is set to the appointment, so an arrival step's anchor is the same instant either way, and discharge steps never get here.
- `lib/src/selection.dart` `decodeQr`: `.where(ticked.contains)` → `.where(code.ticked.contains)` (group count taken from the code's list instead of the set). Equivalent: a duplicate ID is rejected earlier in the same function, so the list and the set hold the same IDs.
- `lib/src/selection.dart` `_utc`: the `$` end anchor dropped. Equivalent: `DateTime.parse` rejects any text after the `Z` (tried: trailing letters, a space, a newline, an offset, a digit, a second `Z`), so the code is still rejected with a FormatException.
