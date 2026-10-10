# Contributing

Work is pushed straight to `main`. The pre-push hook runs every automated check (see [README](README.md#checks)). This checklist covers what a machine can't check. Go through it before every push; the numbers refer to the guardrails in [the spec](docs/spec.md#ai-slop-guardrails).

## Before every push

- [ ] I read every line, including AI-generated ones, and can explain and defend each. Anything I can't explain is removed (#1, #29)
- [ ] Every new package was checked on its registry: it exists, has the expected name and maintainer, and isn't a brand-new lookalike. It has a line in an ADR saying why (#2)
- [ ] Every test asserts a specific outcome. Mocks only at real boundaries: network, clock, storage (#3)
- [ ] Behavior is tested directly; snapshots never replace an assertion (#4)
- [ ] Every try/catch wraps code that can actually throw and does something useful: recover, add context, or convert the error (#5, #6, #13)
- [ ] No checks for states the types already rule out; validation only at trust boundaries (#7)
- [ ] Comments explain *why*, never restate *what* (#8)
- [ ] No new interface, factory or wrapper without a second real use (#9)
- [ ] I searched the codebase for existing logic before writing new logic (#10)
- [ ] Every type-ignore (`@ts-expect-error`, `# type: ignore[code]`, `// ignore:`) has a written reason next to it (#11)
- [ ] UI works by keyboard and screen reader, at 200% text size, and on the smallest supported phone with no feature hidden (#14, #18)

## Adding a package

1. Check it on its registry (npm, pub.dev, PyPI): name, maintainer, age, download count.
2. Pick a version published at least two weeks ago and pin it exactly.
3. Add one line to an ADR in [docs/adr](docs/adr) saying why it is needed.

## Hooks

The hook checks the working tree, so it refuses to run with uncommitted changes. Never bypass it with `--no-verify`; fix the failure instead.
