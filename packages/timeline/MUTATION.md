# Surviving mutants

Mutation runs so far:

- Slices 1–3 (`duration.dart`, `clock.dart`, `offset.dart`, `limits.dart`): 28 mutants, none survive. "5-digit minutes accepted" and "'P2H' (no T) accepted" survived the first run; "rejected durations" in `test/duration_test.dart` now kills them with "PT99999M" and "P2H".
- Slice 4a (`timing.dart`, `calendar.dart`): 18 mutants, none survive.
- Slice 4b (`reminder.dart`): 39 mutants, 1 survives. "Heads-up allowed at the quiet start itself" survived the first run; test 41 in `test/reminder_test.dart` now kills it.

The survivor:

- `lib/src/reminder.dart` `_quietStart`: `to < from` → `to <= from` (quiet hours that start and end at the same time treated as wrapping midnight). Differs only when quietHours from equals to, which the validator's `emptyRange` check rejects; `fixtures/invalid/empty-quiet-hours-umms` proves it and fails on nothing else.
