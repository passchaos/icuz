#!/usr/bin/env python3
"""Generate Numeric_Value and Numeric_Type tables.

Usage:
    generate_numeric.py DerivedNumericType.txt DerivedNumericValues.txt out_dir

Emits a `CJNV` v1 blob consumed by src/unicode/properties/numeric.zig.
Values are stored as exact rationals; adjacent code points with the same
value and type are merged into ranges.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

UNICODE_VERSION = (17, 0, 0)
NUMERIC_TYPE_SHA256 = (
    "7c83684d3336b698381745b78a971c3e1242cb3fcac58604469086c19b6edcee"
)
NUMERIC_VALUES_SHA256 = (
    "139b976bdc288be01c80f018523da769cf2845109b5a7f0f8a432db64bfedcfa"
)

TYPES = {"Decimal": 1, "Digit": 2, "Numeric": 3}


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


def parse_type(text: str) -> dict[int, int]:
    types: dict[int, int] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2 or fields[1] not in TYPES:
            continue
        first, last = parse_range(fields[0])
        for codepoint in range(first, last + 1):
            types[codepoint] = TYPES[fields[1]]
    return types


def parse_rational(text: str) -> tuple[int, int]:
    value = text.strip()
    if not value:
        raise ValueError("empty rational")
    sign = 1
    if value.startswith("-"):
        sign = -1
        value = value[1:]
    if "/" in value:
        numerator, denominator = value.split("/", 1)
        return sign * int(numerator), int(denominator)
    return sign * int(value), 1


def parse_values(text: str) -> dict[int, tuple[int, int]]:
    values: dict[int, tuple[int, int]] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 4:
            continue
        first, last = parse_range(fields[0])
        numerator, denominator = parse_rational(fields[3])
        for codepoint in range(first, last + 1):
            values[codepoint] = (numerator, denominator)
    return values


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    type_path = Path(sys.argv[1])
    value_path = Path(sys.argv[2])
    out_dir = Path(sys.argv[3])
    types = parse_type(checked(type_path, NUMERIC_TYPE_SHA256))
    values = parse_values(checked(value_path, NUMERIC_VALUES_SHA256))

    records: list[tuple[int, int, int, int, int]] = []
    for codepoint in sorted(values):
        numerator, denominator = values[codepoint]
        kind = types.get(codepoint, 3)
        if (
            records
            and records[-1][1] + 1 == codepoint
            and records[-1][2] == numerator
            and records[-1][3] == denominator
            and records[-1][4] == kind
        ):
            first, _, num, den, value_type = records[-1]
            records[-1] = (first, codepoint, num, den, value_type)
        else:
            records.append((codepoint, codepoint, numerator, denominator, kind))

    header_len = 16
    blob = bytearray()
    blob += b"CJNV"
    blob += bytes((1, *UNICODE_VERSION))
    blob += struct.pack("<II", len(records), 0)
    assert len(blob) == header_len
    for first, last, numerator, denominator, kind in records:
        blob += struct.pack("<IIqQB3x", first, last, numerator, denominator, kind)

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "numeric_data.bin").write_bytes(blob)
    print(
        f"wrote {out_dir / 'numeric_data.bin'}: {len(records)} ranges, "
        f"{len(values)} numeric code points"
    )


if __name__ == "__main__":
    main()
