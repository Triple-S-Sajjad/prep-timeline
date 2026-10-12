"""Validate protocol bundles against the schemas, plus the cross-file rules
JSON Schema can't express.

Usage: python schema/validate.py PROTOCOL_DIR...

Each directory holds protocol.json and its module files. Exits 1 if any
check fails. Computes no timelines; publish-time conflict checks belong to
the timeline calculator.
"""

import hashlib
import json
import re
import sys
import zoneinfo
from collections.abc import Iterator
from pathlib import Path
from typing import Any, NamedTuple

from jsonschema import Draft202012Validator, ValidationError, validators
from jsonschema.protocols import Validator

SCHEMA_DIR = Path(__file__).parent
WHOLE_DAY = ("00:00", "24:00")


def _pattern(
    validator: Validator, pattern: str, instance: Any, schema: Any
) -> Iterator[ValidationError]:
    # jsonschema uses re.search, where "$" also matches before a final "\n",
    # so "PT6H\n" would pass. fullmatch gives JSON Schema's end-of-string "$".
    # Every schema pattern is anchored with ^...$, so nothing else changes.
    if validator.is_type(instance, "string") and not re.fullmatch(pattern, instance):
        yield ValidationError(f"{instance!r} does not match {pattern!r}")


# extend is untyped; the class it builds has Draft202012Validator's interface.
SchemaValidator: type[Draft202012Validator] = validators.extend(  # type: ignore[no-untyped-call]
    Draft202012Validator, {"pattern": _pattern}
)


def _validator(name: str) -> Draft202012Validator:
    schema = json.loads((SCHEMA_DIR / name).read_text(encoding="utf-8"))
    SchemaValidator.check_schema(schema)
    # Without a format checker, "format": "date" is only an annotation.
    checker = SchemaValidator.FORMAT_CHECKER
    return SchemaValidator(schema, format_checker=checker)


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
        elif error.validator in ("pattern", "minimum"):
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


def in_clock_range(time: str, clock_range: dict[str, str]) -> bool:
    """Half-open, wrapping midnight when "to" is earlier than "from".
    Zero-padded HH:MM strings sort in time order."""
    start, end = clock_range["from"], clock_range["to"]
    if start <= end:
        return start <= time < end
    return time >= start or time < end


DURATION = re.compile(r"(-?)PT(?:([0-9]+)H)?(?:([0-9]+)M)?")


def minutes(duration: str) -> int:
    """Signed minutes in a duration whose pattern the schema has checked."""
    match = DURATION.fullmatch(duration)
    assert match is not None
    sign, hours, mins = match.groups()
    total = int(hours or 0) * 60 + int(mins or 0)
    return -total if sign else total


def day_step_problems(step: dict[str, Any], file: Path) -> Iterator[Problem]:
    """A day step on any day but day 0 is reminded on its own day. Day 0 from
    the appointment or arrival is the schema's rule: the evening before."""
    day, remind = step["timing"]["day"], step["remind"]
    if day == 0 and step["anchor"] == "discharge":
        # Its day starts before the patient taps "I'm home", so no reminder
        # could come before it takes effect.
        msg = f"{step['id']} counts from discharge, so it can't be on day 0"
        yield Problem(file, "dischargeDayZero", msg)
    elif day != 0 and (remind["kind"] != "dayAt" or remind["day"] != day):
        msg = f"{step['id']} must be reminded on its own day"
        yield Problem(file, "dayReminder", msg)


def module_problems(module: dict[str, Any], file: Path) -> Iterator[Problem]:
    """Rules for one schema-valid module."""
    seen: set[str] = set()
    for step in module["steps"]:
        if step["id"] in seen:
            yield Problem(file, "duplicateStepId", f"{step['id']!r} is used twice")
        seen.add(step["id"])
        if step.get("timing", {}).get("kind") == "day":
            yield from day_step_problems(step, file)
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


def default_for(step: dict[str, Any], defaults: dict[str, Any]) -> str | int | None:
    """What a defaulted remind must be: the morning reminder time on a day
    step's own day, the evening reminder time the day before, or the effect
    time less the reminder lead, in minutes. None if no default gives it,
    including a dayAt step reminded on its own day: no rule says which
    default that would be yet."""
    timing, remind = step["timing"], step["remind"]
    if remind["kind"] == "offset":
        effect = {"offset": "offset", "window": "start", "deadline": "by"}
        field = effect.get(timing["kind"])
        if field is None:
            return None
        return minutes(timing[field]) - minutes(defaults["reminderLead"])
    if timing["kind"] not in ("day", "dayAt"):
        return None
    if timing["kind"] == "day" and remind["day"] == timing["day"]:
        return str(defaults["morningReminder"])
    if isinstance(timing["day"], int) and remind["day"] == timing["day"] - 1:
        return str(defaults["eveningReminder"])
    return None


def defaulted_problems(
    module: dict[str, Any], defaults: dict[str, Any], file: Path
) -> Iterator[Problem]:
    """A defaulted value must equal the department default it came from."""
    for step in module["steps"]:
        remind = step.get("remind")
        if remind is None or not remind["defaulted"]:
            continue
        offset = remind["kind"] == "offset"
        actual = minutes(remind["offset"]) if offset else remind["time"]
        expected = default_for(step, defaults)
        if actual != expected:
            msg = f"{step['id']}.remind is {actual!r}, default is {expected!r}"
            yield Problem(file, "defaultedMismatch", msg)


CLOCK_TIMES = [f"{h:02}:{m:02}" for h in range(24) for m in range(60)]


def bookable_problems(
    manifest: dict[str, Any], modules: dict[str, Module], file: Path
) -> Iterator[Problem]:
    """The base module applies to every appointment, so its appliesWhen must
    cover every bookable time. appointmentTime groups already cover the whole
    day exactly once (coverage_problems)."""
    base_id = manifest["baseModule"]["moduleId"]
    base = modules.get(base_id)
    if base is None or not base.valid:
        return  # Already reported as missing or schema-invalid.
    start, end = time_range(base.data)
    if start >= end:
        return  # Already reported as appliesWhenRange.
    for time in CLOCK_TIMES:
        if in_clock_range(time, manifest["bookableHours"]) and not start <= time < end:
            msg = f"bookable time {time} is outside {base_id}'s {start}-{end}"
            yield Problem(file, "bookableCoverage", msg)
            return


def manifest_problems(
    manifest: dict[str, Any], modules: dict[str, Module], file: Path
) -> Iterator[Problem]:
    """Rules for a schema-valid manifest and its modules."""
    timezone = manifest["timezone"]
    if timezone not in zoneinfo.available_timezones():
        msg = f"{timezone!r} is not an IANA time zone"
        yield Problem(file, "unknownTimezone", msg)

    defaults = manifest["departmentDefaults"]
    quiet = defaults["quietHours"]
    spans = {"quietHours": quiet, "bookableHours": manifest["bookableHours"]}
    for name, span in spans.items():
        if span["from"] == span["to"]:
            msg = f"{name} starts and ends at {span['from']}"
            yield Problem(file, "emptyRange", msg)
    # Heads-ups come at the evening reminder time, so this keeps them out of
    # quiet hours.
    if in_clock_range(defaults["eveningReminder"], quiet):
        msg = f"eveningReminder {defaults['eveningReminder']} is in quiet hours"
        yield Problem(file, "eveningInQuietHours", msg)
    for loaded in modules.values():
        if loaded.valid:
            yield from defaulted_problems(loaded.data, defaults, loaded.file)
    yield from bookable_problems(manifest, modules, file)

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
