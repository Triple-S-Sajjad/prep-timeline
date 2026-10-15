import json
from pathlib import Path

import pytest

from validate import check_protocol, in_clock_range

INVALID = Path(__file__).parent.parent / "fixtures" / "invalid"

# Failures only the timeline calculator can find. This validator must pass
# them, so a calculator test sees the conflict and nothing else.
CALCULATOR_FAILURES = {"conflictingCutoffs"}

# Codes a fixture's one defect also causes. A misspelled field is both an
# unknown property and a missing required one, and the schema reports each.
ALSO_CAUSED = {"misspelled-field-umms": {"required:defaulted"}}


@pytest.mark.parametrize("name", sorted(p.name for p in INVALID.iterdir()))
def test_invalid_fixture_fails_for_its_expected_reason_only(name: str) -> None:
    protocol_dir = INVALID / name
    text = (protocol_dir / "protocol.json").read_text(encoding="utf-8")
    manifest = json.loads(text)
    expected = manifest.pop("expectedFailure")
    codes = {p.code for p in check_protocol(protocol_dir, manifest)}
    if expected in CALCULATOR_FAILURES:
        assert codes == set()
    else:
        assert codes == {expected} | ALSO_CAUSED.get(name, set())


@pytest.mark.parametrize(
    ("time", "start", "end", "inside"),
    [
        # Wraps midnight: 23:00 is quiet, 05:00 is not.
        ("23:00", "23:00", "05:00", True),
        ("00:00", "23:00", "05:00", True),
        ("04:59", "23:00", "05:00", True),
        ("05:00", "23:00", "05:00", False),
        ("22:59", "23:00", "05:00", False),
        ("12:00", "23:00", "05:00", False),
        # Doesn't wrap.
        ("13:00", "13:00", "21:00", True),
        ("20:59", "13:00", "21:00", True),
        ("21:00", "13:00", "21:00", False),
        ("12:59", "13:00", "21:00", False),
    ],
)
def test_clock_range_is_half_open(
    time: str, start: str, end: str, inside: bool
) -> None:
    assert in_clock_range(time, {"from": start, "to": end}) is inside
