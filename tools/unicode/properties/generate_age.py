#!/usr/bin/env python3
"""Generate the Unicode Age property table.

Usage:
    generate_age.py DerivedAge.txt out_dir

Emits a `CJAG` v1 blob consumed by src/unicode/properties/age.zig. Each
record stores a code-point range and the Unicode version that assigned it.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

UNICODE_VERSION = (17, 0, 0)
DERIVED_AGE_SHA256 = (
    "f8ecdf768bdc210f201abd271d9bc587825618a86a7046a8146cc816393f1998"
)


def checked(path: Path, expected: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(
            f"{path}: expected Unicode 17 SHA-256 {expected}, found {actual}"
        )
    return data.decode("utf-8")


def parse_range(text: str) -> tuple[int, int]:
    span = text.strip().split("..")
    first = int(span[0], 16)
    last = int(span[1], 16) if len(span) == 2 else first
    return first, last


def parse_version(text: str) -> int:
    major, minor = text.strip().split(".")
    return (int(major) << 8) | int(minor)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    records: list[tuple[int, int, int]] = []
    for raw in checked(source, DERIVED_AGE_SHA256).splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2:
            continue
        first, last = parse_range(fields[0])
        version = parse_version(fields[1])
        records.append((first, last, version))

    # DerivedAge.txt groups ranges by version, not by code point, so later
    # versions add characters inside earlier blocks. Sort before merging.
    records.sort()
    merged: list[tuple[int, int, int]] = []
    for first, last, version in records:
        if (
            merged
            and merged[-1][1] + 1 == first
            and merged[-1][2] == version
        ):
            merged[-1] = (merged[-1][0], last, version)
        else:
            merged.append((first, last, version))
    records = merged

    header_len = 16
    blob = bytearray()
    blob += b"CJXV"
    blob += bytes((1, *UNICODE_VERSION))
    blob += struct.pack("<II", len(records), 0)
    assert len(blob) == header_len
    for first, last, version in records:
        blob += struct.pack("<IIHH", first, last, version, 0)

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "age_data.bin").write_bytes(blob)
    print(
        f"wrote {out_dir / 'age_data.bin'}: {len(records)} ranges, "
        f"{sum(last - first + 1 for first, last, _ in records)} assigned code points"
    )


if __name__ == "__main__":
    main()
