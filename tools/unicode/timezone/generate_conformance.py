#!/usr/bin/env python3
"""Generate the time zone offset conformance fixture.

Usage:
    generate_conformance.py tzdata_dir out_file

The fixture compiles the pinned IANA tzdata with `zic` and records the UTC
offset and daylight flag reported by Python's `zoneinfo` (CPython's TZif
reader) for every zone at fixed sample instants plus transition boundaries.
This is a differential check of the committed CJTZ blob against an
independent reader of the same tzdata release.
"""

from __future__ import annotations

import datetime
import struct
import subprocess
import sys
import tempfile
import zoneinfo
from pathlib import Path

RANGE_HI = 4102444800  # 2100-01-01T00:00:00Z

SOURCES = (
    "africa",
    "antarctica",
    "asia",
    "australasia",
    "europe",
    "northamerica",
    "southamerica",
    "etcetera",
    "backward",
)

SAMPLES = (
    0,
    315532800,  # 1980-01-01
    331171200,  # 1980-07-01
    631152000,  # 1990-01-01
    946684800,  # 2000-01-01
    962409600,  # 2000-07-01
    1262304000,  # 2010-01-01
    1577836800,  # 2020-01-01
    1593561600,  # 2020-07-01
    1767225600,  # 2026-01-01
    1782864000,  # 2026-07-01
    1893456000,  # 2030-01-01
    1909094400,  # 2030-07-01
    2208988800,  # 2040-01-01
    2542492800,  # 2050-07-01
    4085510400,  # 2099-06-01
)

MAX_BOUNDARIES = 8


def compile_zones(tzdata_dir: Path, output: Path) -> dict[str, bytes]:
    subprocess.run(
        [
            "zic",
            "-r",
            f"@0/@{RANGE_HI}",
            "-d",
            str(output),
            *[str(tzdata_dir / name) for name in SOURCES],
        ],
        check=True,
    )
    zones = {}
    for path in sorted(output.rglob("*")):
        if not path.is_file():
            continue
        zones[path.relative_to(output).as_posix()] = path.read_bytes()
    return zones


def transition_times(payload: bytes) -> list[int]:
    """Extract transition instants from a TZif v2 file."""
    if payload[:4] != b"TZif" or payload[4] == 0:
        return []
    counts = struct.unpack_from(">6I", payload, 20)
    isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt = counts
    offset = (
        44
        + timecnt * 4
        + timecnt
        + typecnt * 6
        + charcnt
        + leapcnt * 8
        + isstdcnt
        + isutcnt
    )
    counts = struct.unpack_from(">6I", payload, offset + 20)
    isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt = counts
    offset += 44
    return [
        struct.unpack_from(">q", payload, offset + index * 8)[0]
        for index in range(timecnt)
    ]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    tzdata_dir = Path(sys.argv[1])
    output = Path(sys.argv[2])

    version = "unknown"
    version_file = tzdata_dir / "version"
    if version_file.is_file():
        version = version_file.read_text(encoding="utf-8").strip()

    with tempfile.TemporaryDirectory() as temporary:
        compiled = Path(temporary)
        zones = compile_zones(tzdata_dir, compiled)
        zoneinfo.reset_tzpath([str(compiled)])

        cases = []
        for name in sorted(zones):
            try:
                info = zoneinfo.ZoneInfo(name)
            except Exception:
                continue
            instants = list(SAMPLES)
            transitions = [
                value for value in transition_times(zones[name])
                if 0 <= value <= RANGE_HI
            ]
            if transitions:
                step = max(1, len(transitions) // MAX_BOUNDARIES)
                for instant in transitions[::step][:MAX_BOUNDARIES]:
                    for candidate in (instant - 1, instant):
                        if candidate >= 0:
                            instants.append(candidate)
            for instant in instants:
                moment = datetime.datetime.fromtimestamp(
                    instant, datetime.timezone.utc
                )
                local = moment.astimezone(info)
                offset = local.utcoffset()
                daylight = local.dst() is not None and local.dst().total_seconds() != 0
                cases.append(
                    (name, instant, int(offset.total_seconds()), daylight)
                )

    encoded_version = version.encode("utf-8")
    if len(encoded_version) > 255:
        raise SystemExit("tzdata version string too long")
    blob = bytearray(b"CJTQ")
    blob += struct.pack("<BBHI", 1, len(encoded_version), 0, len(cases))
    blob += encoded_version
    for name, instant, offset, daylight in cases:
        encoded = name.encode("utf-8")
        blob += struct.pack(
            "<BBHqi",
            len(encoded),
            1 if daylight else 0,
            0,
            instant,
            offset,
        )
        blob += encoded
    output.write_bytes(bytes(blob))
    print(
        f"wrote {len(cases)} cases for {len(zones)} zones (tzdata {version})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
