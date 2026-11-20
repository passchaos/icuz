#!/usr/bin/env python3
"""Generate the IANA time zone transition table.

Usage:
    generate_data.py tzdata_dir out_dir

`tzdata_dir` is an extracted IANA tzdata release (for example 2026e). The
generator compiles it with `zic` into TZif files covering 1850 through 2100,
parses those files, and emits a deduplicated `CJTZ` v1 blob. `zic` must be in
PATH (macOS ships it at /usr/sbin/zic).

Zone names include the `backward` link names. Identical TZif payloads (links
and fixed-offset aliases) share one transition range.
"""

from __future__ import annotations

import hashlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ZIC_SOURCES = (
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

RANGE_LO = -3786825600  # 1850-01-01T00:00:00Z
RANGE_HI = 4102444800  # 2100-01-01T00:00:00Z

FLAG_DAYLIGHT = 1


def parse_tzif(data: bytes):
    """Return (transitions, abbreviations) from a TZif v1/v2/v3 file.

    Transitions are (unix_seconds, offset_seconds, abbreviation, daylight)
    tuples. The first transition is always at or before RANGE_LO.
    """
    if len(data) < 44 or data[:4] != b"TZif":
        raise ValueError("not a TZif file")
    version = data[4]

    def read_header(offset: int):
        if data[offset : offset + 4] != b"TZif":
            raise ValueError("invalid TZif header")
        counts = struct.unpack_from(">6I", data, offset + 20)
        return counts, offset + 44

    def read_block(offset: int, time_size: int, counts):
        isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt = counts
        times = []
        for index in range(timecnt):
            if time_size == 8:
                value = struct.unpack_from(">q", data, offset)[0]
            else:
                value = struct.unpack_from(">i", data, offset)[0]
            times.append(value)
            offset += time_size
        indices = list(data[offset : offset + timecnt])
        offset += timecnt
        types = []
        for _ in range(typecnt):
            utoff, isdst, desig = struct.unpack_from(">iBB", data, offset)
            offset += 6
            types.append((utoff, isdst, desig))
        chars = data[offset : offset + charcnt]
        offset += charcnt + leapcnt * (time_size + 4) + isstdcnt + isutcnt
        return times, indices, types, chars, offset

    counts, offset = read_header(0)
    if version == 0:
        times, indices, types, chars, _ = read_block(offset, 4, counts)
    else:
        # Skip the v1 block, then parse the 64-bit block.
        isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt = counts
        offset += (
            timecnt * 4
            + timecnt
            + typecnt * 6
            + charcnt
            + leapcnt * 8
            + isstdcnt
            + isutcnt
        )
        counts, offset = read_header(offset)
        times, indices, types, chars, _ = read_block(offset, 8, counts)

    abbreviations = []
    for _utoff, _isdst, desig in types:
        end = chars.find(b"\0", desig)
        if end < 0:
            end = len(chars)
        abbreviations.append(chars[desig:end].decode("utf-8"))

    transitions = []
    for time, type_index in zip(times, indices):
        if type_index >= len(types):
            continue
        utoff, isdst, _ = types[type_index]
        transitions.append((time, utoff, abbreviations[type_index], isdst != 0))
    if not transitions:
        # Fixed-offset zones still need one state at the range start.
        utoff, isdst, desig = types[0]
        transitions.append((RANGE_LO, utoff, abbreviations[desig], isdst != 0))
    return transitions, abbreviations


def compile_zones(tzdata_dir: Path) -> dict[str, bytes]:
    sources = [str(tzdata_dir / name) for name in ZIC_SOURCES]
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        command = [
            "zic",
            "-r",
            f"@{RANGE_LO}/@{RANGE_HI}",
            "-d",
            str(output),
            *sources,
        ]
        subprocess.run(command, check=True)
        zones = {}
        for path in sorted(output.rglob("*")):
            if not path.is_file():
                continue
            name = path.relative_to(output).as_posix()
            zones[name] = path.read_bytes()
        return zones


def clamp_transitions(transitions):
    clamped = []
    for time, offset, abbreviation, daylight in transitions:
        if time < RANGE_LO:
            clamped.append((RANGE_LO, offset, abbreviation, daylight))
        elif time <= RANGE_HI:
            clamped.append((time, offset, abbreviation, daylight))
    if not clamped:
        raise ValueError("empty transition list")
    if clamped[0][0] != RANGE_LO:
        clamped.insert(0, (RANGE_LO, *clamped[0][1:]))
    return clamped


def render(zone_payloads: dict[str, bytes], tzdata_version: str) -> bytes:
    strings = bytearray()
    string_offsets: dict[str, tuple[int, int]] = {}

    def intern(value: str) -> tuple[int, int]:
        if value in string_offsets:
            return string_offsets[value]
        offset = len(strings)
        encoded = value.encode("utf-8")
        strings.extend(encoded)
        string_offsets[value] = (offset, len(encoded))
        return string_offsets[value]

    abbreviation_index: dict[str, int] = {}
    abbreviations: list[str] = []

    def abbr(value: str) -> int:
        index = abbreviation_index.get(value)
        if index is None:
            index = len(abbreviations)
            abbreviation_index[value] = index
            abbreviations.append(value)
        return index

    # Deduplicate identical TZif payloads so links share transitions.
    payload_key: dict[str, int] = {}
    ranges: list[tuple[int, int]] = []
    transition_bytes = bytearray()
    zones: list[tuple[str, int, int]] = []
    for name in sorted(zone_payloads):
        payload = zone_payloads[name]
        digest = hashlib.sha256(payload).hexdigest()
        range_index = payload_key.get(digest)
        if range_index is None:
            transitions, _ = parse_tzif(payload)
            transitions = clamp_transitions(transitions)
            range_index = len(ranges)
            payload_key[digest] = range_index
            first = len(transition_bytes) // 16
            for time, offset, abbreviation, daylight in transitions:
                transition_bytes += struct.pack(
                    "<qiHBB",
                    time,
                    offset,
                    abbr(abbreviation),
                    FLAG_DAYLIGHT if daylight else 0,
                    0,
                )
            ranges.append((first, len(transitions)))
        first, count = ranges[range_index]
        zones.append((name, first, count))

    tzdata_offset, tzdata_len = intern(tzdata_version)
    zone_bytes = bytearray()
    for name, first, count in zones:
        name_offset, name_len = intern(name)
        zone_bytes += struct.pack(
            "<IBBIH",
            name_offset,
            name_len,
            0,
            first,
            count,
        )
    abbr_bytes = bytearray()
    for value in abbreviations:
        offset, length = intern(value)
        abbr_bytes += struct.pack("<IBB", offset, length, 0)

    header = bytearray(b"CJTZ")
    header += struct.pack(
        "<B3xHHII B3x I",
        2,
        len(zones),
        len(abbreviations),
        len(transition_bytes) // 16,
        tzdata_offset,
        tzdata_len,
        len(strings),
    )
    return bytes(
        header + zone_bytes + transition_bytes + abbr_bytes + strings
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    tzdata_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    version = "unknown"
    version_file = tzdata_dir / "version"
    if version_file.is_file():
        version = version_file.read_text(encoding="utf-8").strip()
    for candidate in ("Makefile",):
        if version != "unknown":
            break
        path = tzdata_dir / candidate
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("version ="):
                version = line.split("=", 1)[1].strip().strip("'\"")
                break
            if line.startswith("# version"):
                version = line.split()[-1]
                break
        if version != "unknown":
            break

    zones = compile_zones(tzdata_dir)
    blob = render(zones, version)
    (out_dir / "data.bin").write_bytes(blob)
    print(
        f"generated {len(zones)} zones, tzdata {version}, {len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
