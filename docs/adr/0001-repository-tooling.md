# 1. Repository tooling

Date: 2026-10-10

## Context

The spec's guardrails (Step 1) need lint, type, duplicate-code, prose and security checks in place before the first feature. Work is solo and pushed straight to `main`, so pull-request-only tools don't apply.

## Decision

Checks run in a pre-push hook (`.githooks/pre-push`) so nothing failing reaches GitHub. CI on push to `main` runs that same hook script, so a push made with `--no-verify` is still caught and the two can't drift apart. GitHub dependency review is not used because it only runs on pull requests.

CI installs gitleaks, OSV-Scanner and Vale from their release pages and checks each download against a pinned SHA-256, rather than using third-party actions that would run the same binaries.

Language checks are gated on files existing, so the repo doesn't need every toolchain before it has code in that language.

GitHub Actions are pinned by commit SHA, and npm packages by exact version, each at least two weeks old when added. The Flutter SDK is exempt from the two-week rule: it comes from Flutter's official stable channel, not a package registry.

## Packages and tools

| Package or tool | Version | Why |
| --- | --- | --- |
| `eslint` | 10.11.0 | Lint TypeScript; enforces no-console, no-empty, no-useless-catch |
| `@eslint/js` | 10.0.1 | ESLint's base recommended rules |
| `typescript-eslint` | 8.70.1 | Type-aware rules: no `any`, no-unsafe-*, described `@ts-expect-error` |
| `typescript` | 6.0.3 | Type checker for the portal. Not 7.x: typescript-eslint 8 supports TypeScript below 6.1 |
| `jscpd` | 5.3.2 | Duplicate-code detection across TS, Dart and Python |
| gitleaks | 8.30.1 in CI | Blocks committed secrets |
| OSV-Scanner | 2.6.0 in CI | Flags dependencies with known vulnerabilities |
| Vale | 3.22.0 in CI | Prose linter for the banned-word and emoji-bullet rules |
| `ruff` | 0.16.9 | Python lint: no print, no empty or useless except, coded type-ignores |
| `mypy` | 2.3.1 | Python type checker, strict mode |
| `pytest` | 9.1.1 | Python test runner |
| `jsonschema` | 4.26.0 | Validates protocol bundles against the JSON Schema 2020-12 files in `schema/`. Python because the cross-file checks (hashes, parameter references) live in the same script. The `ajv` already in `node_modules` comes with ESLint and is version 6, which only supports draft-07 |
| `types-jsonschema` | 4.26.0.20260518 | Type stubs from typeshed; `jsonschema` ships none, and mypy runs in strict mode |
| `tzdata` | 2026.4, Windows only | IANA time zone database (release 2026d) for `zoneinfo`, which the validator uses to reject unknown time zones. Windows has no system copy; Linux and macOS use their own |
| `test` | 1.32.0 | Dart test runner for the timeline calculator; dev only |
| `timezone` | 0.11.1 | IANA time zones and `TZDateTime` for the calculator, since Dart's `DateTime` knows only UTC and the device's zone. Bundles IANA 2025c (stated in the generated headers of `lib/data/*.dart`); see Known limitations |
| `crypto` | 3.0.7 | SHA-256 of the raw manifest and module bytes, the same hex digest as `hashlib.sha256` in `schema/validate.py`. Already in the lockfile through `test`; now a pinned direct dependency |
| `cryptography` | 2.9.0 | Ed25519 verification of `protocol.sig`, in pure Dart on the phone and through Web Crypto in browsers. Adds `ffi` (dart.dev) to the lockfile. `webcrypto` 0.6.1 was rejected because it has no Ed25519 |
| `actions/checkout` | v7.0.1 | Check out the repo in CI |
| `actions/setup-node` | v7.0.0 | Node for npm tools in CI |
| `actions/setup-python` | v7.0.0 | Python in CI, only once `.py` files exist |
| `subosito/flutter-action` | v2.23.0 | Flutter and Dart in CI, only once a `pubspec.yaml` exists. Pinned to Flutter 3.47.7 (Dart 3.13.5) to match the local SDK |

## Known limitations

- The calculator's time zone data is IANA 2025c, from `timezone` 0.11.1. It misses the 2026 clock changes in Canada (America/Vancouver, America/Edmonton, America/Inuvik, America/Winnipeg) and Morocco, so times in those zones after the changes are wrong. Fix: move to `timezone` 0.11.2 (IANA 2026e) together with `tzdata` 2026.5 (IANA 2026e), once both pass the two-week rule, so the validator and the calculator stay on one release. Building our own database from IANA releases was rejected to avoid maintaining a custom build.
- The calculator's time zone data ends in 2037: `timezone` compiles it with `zic -b fat`, and after the last transition it keeps the last offset, so summer times in 2038 or later would be an hour off. The calculator rejects any appointment or step time after 2037.

## Deferred

- axe-core accessibility checks: added with the portal's end-to-end tests, since there are no pages to test yet.
- Design-system tokens file: written before the first screen.
