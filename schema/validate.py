"""Validate protocol bundles against the schemas, plus the cross-file rules
JSON Schema can't express.

Usage: python schema/validate.py PROTOCOL_DIR...

Each directory holds protocol.json and its module files. Exits 1 if any
check fails. Computes no timelines; publish-time conflict checks belong to
the timeline calculator.
"""

import hashlib
import json
import sys
import zoneinfo
from collections.abc import Iterator
from pathlib import Path
from typing import Any, NamedTuple

from jsonschema import Draft202012Validator

SCHEMA_DIR = Path(__file__).parent
WHOLE_DAY = ("00:00", "24:00")


def _validator(name: str) -> Draft202012Validator:
    schema = json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    # Without a format checker, "format": "date" is only an annotation.
    checker = Draft202012Validator.FORMAT_CHECKER
    return Draft202012Validator(schema, format_checker=checker)


PROTOCOL_SCHEMA = _validator("protocol.schema.json")
MODULE_SCHEMA = _validator("module.schema.json")


class Problem(NamedTuple):
    file: Path
    code: str
    message: str


class Module(NamedTuple):
    file: Path
    sha256: str
    data: dict[str, Any]
    valid: bool


def schema_problems(
    validator: Draft202012Validator, data: Any, file: Path
) -> list[Problem]:
    problems = []
    for error in validator.iter_errors(data):
        # Name the field in the code, so a test can tell a missing pastDue
        # from any other missing field.
        code = str(error.validator)
        if error.validator == "required":
            missing = [p for p in error.validator_value if p not in error.instance]
            code += ":" + ",".join(missing)
        elif error.validator == "additionalProperties":
            known = error.schema.get("properties", {})
            code += ":" + ",".join(sorted(set(error.instance) - set(known)))
        elif error.validator == "pattern":
            code += ":" + str(error.path[-1])
        problems.append(Problem(file, code, f"{error.json_path}: {error.message}"))
    return problems


def param_refs(value: Any) -> Iterator[str]:
    if isinstance(value, dict):
        if "param" in value:
            yield value["param"]
        for child in value.values():
            yield from param_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from param_refs(child)


def time_range(module: dict[str, Any]) -> tuple[str, str]:
    times = module["appliesWhen"]["appointmentTime"]
    return times["fromInclusive"], times["toExclusive"]


def module_problems(module: dict[str, Any], file: Path) -> Iterator[Problem]:
    """Rules for one schema-valid module."""
    seen: set[str] = set()
    for step in module["steps"]:
        if step["id"] in seen:
            yield Problem(file, "duplicateStepId", f"{step['id']!r} is used twice")
        seen.add(step["id"])
    declared = module.get("parameters", {})
    for name in param_refs(module["steps"]):
        if name not in declared:
            yield Problem(file, "undeclaredParam", f"{name!r} is not in parameters")
    for name, p in declared.items():
        if p["min"] > p["max"]:
            msg = f"{name}: min {p['min']} is above max {p['max']}"
            yield Problem(file, "paramRange", msg)
    # Zero-padded HH:MM strings sort in time order, and "24:00" sorts last.
    start, end = time_range(module)
    if start >= end:
        msg = f"appointmentTime {start} is not before {end}"
        yield Problem(file, "appliesWhenRange", msg)


def coverage_problems(
    group: list[str], modules: dict[str, Module], file: Path
) -> Iterator[Problem]:
    """An appointmentTime group must split the day into half-open ranges,
    so every appointment time matches exactly one module."""
    if any(m not in modules or not modules[m].valid for m in group):
        return  # Already reported as missing or schema-invalid.
    ranges = sorted((time_range(modules[m].data), m) for m in group)
    covered = WHOLE_DAY[0]
    for (start, end), module_id in ranges:
        if start > covered:
            yield Problem(file, "variantGap", f"nothing covers {covered}-{start}")
        elif start < covered:
            msg = f"{module_id} starts at {start}, before {covered}"
            yield Problem(file, "variantOverlap", msg)
        covered = max(covered, end)
    if covered != WHOLE_DAY[1]:
        msg = f"nothing covers {covered}-{WHOLE_DAY[1]}"
        yield Problem(file, "variantGap", msg)


def manifest_problems(
    manifest: dict[str, Any], modules: dict[str, Module], file: Path
) -> Iterator[Problem]:
    """Rules for a schema-valid manifest and its modules."""
    timezone = manifest["timezone"]
    if timezone not in zoneinfo.available_timezones():
        msg = f"{timezone!r} is not an IANA time zone"
        yield Problem(file, "unknownTimezone", msg)

    base_id = manifest["baseModule"]["moduleId"]
    selected_at = {r["moduleId"]: r["selectedAt"] for r in manifest["optionalModules"]}
    if base_id in selected_at:
        msg = f"{base_id} is also an optional module"
        yield Problem(file, "baseListedAsOptional", msg)

    for ref in [manifest["baseModule"], *manifest["optionalModules"]]:
        module_id = ref["moduleId"]
        module = modules.get(module_id)
        if module is None:
            msg = f"no module file has moduleId {module_id!r}"
            yield Problem(file, "missingModule", msg)
            continue
        if module.sha256 != ref["sha256"]:
            msg = f"{module_id}: listed {ref['sha256']}, file is {module.sha256}"
            yield Problem(file, "hashMismatch", msg)
        version = module.data.get("version")
        if version != ref["version"]:
            msg = f"{module_id}: listed version {ref['version']}, file has {version}"
            yield Problem(file, "versionMismatch", msg)

    for group in manifest["allowedCombinations"]["exactlyOneOf"]:
        ids = group["modules"]
        for module_id in sorted(set(ids) - set(selected_at)):
            msg = f"exactlyOneOf names {module_id!r}, not an optional module"
            yield Problem(file, "missingModule", msg)
        if group["selectBy"] == "appointmentTime":
            yield from coverage_problems(ids, modules, file)
            continue
        # The clinician can only pick exactly one if every choice is on the
        # same QR code.
        when = sorted({selected_at[m] for m in ids if m in selected_at})
        if len(when) > 1:
            msg = f"clinician group {ids} mixes selectedAt {when}"
            yield Problem(file, "groupSelectedAt", msg)


def check_protocol(protocol_dir: Path, manifest: Any) -> list[Problem]:
    manifest_file = protocol_dir / "protocol.json"
    problems = schema_problems(PROTOCOL_SCHEMA, manifest, manifest_file)
    manifest_ok = not problems

    modules: dict[str, Module] = {}
    for file in sorted(protocol_dir.glob("*.json")):
        if file == manifest_file:
            continue
        raw = file.read_bytes()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            problems.append(Problem(file, "invalidJson", str(e)))
            continue
        errors = schema_problems(MODULE_SCHEMA, data, file)
        problems += errors or module_problems(data, file)
        # Index modules by moduleId even if they fail the schema, so one bad
        # field doesn't also report its module as missing.
        module_id = data.get("moduleId") if isinstance(data, dict) else None
        if isinstance(module_id, str):
            if module_id in modules:
                msg = f"{module_id!r} is also in {modules[module_id].file.name}"
                problems.append(Problem(file, "duplicateModuleId", msg))
            sha256 = hashlib.sha256(raw).hexdigest()
            modules[module_id] = Module(file, sha256, data, not errors)

    # The cross-file checks rely on the manifest's shape.
    if manifest_ok:
        problems += manifest_problems(manifest, modules, manifest_file)
    return problems


def main(dirs: list[str]) -> int:
    problems = []
    for name in dirs:
        protocol_dir = Path(name)
        text = (protocol_dir / "protocol.json").read_text(encoding="utf-8")
        problems += check_protocol(protocol_dir, json.loads(text))
    for p in problems:
        sys.stderr.write(f"{p.file}: {p.code}: {p.message}\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
