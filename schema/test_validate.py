import json
from pathlib import Path

import pytest

from validate import check_protocol

INVALID = Path(__file__).parent.parent / "fixtures" / "invalid"

# Failures only the timeline calculator can find. This validator must pass
# them, so a calculator test sees the conflict and nothing else.
CALCULATOR_FAILURES = {"conflictingCutoffs"}


@pytest.mark.parametrize("name", sorted(p.name for p in INVALID.iterdir()))
def test_invalid_fixture_fails_for_its_expected_reason(name: str) -> None:
    protocol_dir = INVALID / name
    text = (protocol_dir / "protocol.json").read_text(encoding="utf-8")
    manifest = json.loads(text)
    expected = manifest.pop("expectedFailure")
    codes = {p.code for p in check_protocol(protocol_dir, manifest)}
    if expected in CALCULATOR_FAILURES:
        assert codes == set()
    else:
        assert expected in codes
