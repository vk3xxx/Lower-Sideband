#!/usr/bin/env python3
"""Generate the canonical telemetry fixture with upstream Sideband itself."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sideband-Upstream" / "sbapp"))

import sideband.sense as sense  # noqa: E402

EXPECTED = "8301ce6553f1000297c404fdbf02a0c40408a3f61cc40400003039c40400000096c4040000235ac4020320ce6553f1000493cb4055e00000000000c3c0"

# Sideband always inserts the current sensor timestamp. Freeze it so the
# resulting MessagePack is deterministic and directly comparable to Swift.
sense.time.time = lambda: 1_700_000_000
telemeter = sense.Telemeter()
telemeter.synthesize("location")
location = telemeter.sensors["location"]
location.latitude = -37.8136
location.longitude = 144.9631
location.altitude = 123.45
location.speed = 1.5
location.bearing = 90.5
location.accuracy = 8
location.set_update_time(1_700_000_000)
telemeter.synthesize("battery")
telemeter.sensors["battery"].data = {
    "charge_percent": 87.5,
    "charging": True,
    "temperature": None,
}

actual = telemeter.packed().hex()
if actual != EXPECTED:
    raise SystemExit(f"telemetry fixture mismatch\nexpected: {EXPECTED}\nactual:   {actual}")

print(f"Python Sideband telemetry fixture verified: {actual}")
