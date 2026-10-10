# prep-timeline

A pre-procedure prep app. Clinicians publish signed prep protocols; the patient's phone turns a protocol and an appointment time into a timeline with reminders. No patient data reaches the server.

The full design is in [docs/spec.md](docs/spec.md). Decisions and their reasons are in [docs/adr](docs/adr).

## Status

Repository tooling only. No application code yet; the next step is the Core phase in the spec (protocol schema and timeline calculator).

## Setup

Install these and make sure each is on your `PATH`:

- [Node.js](https://nodejs.org/) 24 LTS, then run `npm ci` in the repo root
- [gitleaks](https://github.com/gitleaks/gitleaks#installing)
- [OSV-Scanner](https://google.github.io/osv-scanner/installation/)
- [Vale](https://vale.sh/docs/install)

Install these once the matching code exists (the pre-push hook only asks for a toolchain after that language has files):

- Dart and Flutter: [Flutter SDK](https://docs.flutter.dev/get-started/install)
- Python 3.14, then `pip install -r requirements-dev.txt` (Ruff, mypy, pytest)

Turn on the pre-push hook (once per clone):

```sh
git config core.hooksPath .githooks
```

## Checks

| Where | What runs |
| --- | --- |
| `.githooks/pre-push` | gitleaks, OSV-Scanner, jscpd, Vale; then tsc + ESLint, Ruff + mypy + pytest, and `dart`/`flutter` analyze + test for each language present |
| GitHub Actions on push to `main` | The same pre-push hook, so a push made with `--no-verify` is still checked |

Shared rule files live at the root: `analysis_options.yaml` (Dart), `tsconfig.base.json` and `eslint.config.js` (TypeScript), `ruff.toml` and `mypy.ini` (Python), `.jscpd.json`, `.vale.ini`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0, see [LICENSE](LICENSE).
