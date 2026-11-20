#!/usr/bin/env python3
"""Generate the NFKC_Casefold and NFKC_Simple_Casefold mapping tables.

Usage:
    generate_casefold.py DerivedNormalizationProps.txt out_dir

Parses the derived `NFKC_CF` and `NFKC_SCF` properties and emits two `CJQF`
v1 blobs consumed by src/unicode/normalization/casefold.zig. Empty mappings
(default-ignorable removals) are stored as ranges; other mappings share a
code-point pool.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

UNICODE_VERSION = (17, 0, 0)
DERIVED_NORMALIZATION_SHA256 = (
    "71fd6a206a2c0cdd41feb6b7f656aa31091db45e9cedc926985d718397f9e488"
)

PROPERTIES = (
    ("NFKC_CF", "casefold_data.bin"),
    ("NFKC_SCF", "casefold_simple_data.bin"),
)


def build(data: str, property_name: str) -> bytes:
    mappings: dict[int, tuple[int, ...]] = {}
    removals: list[tuple[int, int]] = []
    for raw in data.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 3 or fields[1] != property_name:
            continue
        span = fields[0].split("..")
        first = int(span[0], 16)
        last = int(span[1], 16) if len(span) == 2 else first
        target = tuple(int(token, 16) for token in fields[2].split())
        if not target:
            removals.append((first, last))
        else:
            for codepoint in range(first, last + 1):
                mappings[codepoint] = target

    removals.sort()
    merged: list[tuple[int, int]] = []
    for first, last in removals:
        if merged and first <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))

    pool: list[int] = []
    records: list[tuple[int, int, int]] = []
    for codepoint in sorted(mappings):
        target = mappings[codepoint]
        records.append((codepoint, len(pool), len(target)))
        pool.extend(target)

    header_len = 32
    mapping_offset = header_len
    removal_offset = mapping_offset + len(records) * 12
    pool_offset = removal_offset + len(merged) * 8
    blob = bytearray()
    blob += b"CJQF"
    blob += bytes((1, *UNICODE_VERSION))
    blob += struct.pack(
        "<IIIIII",
        len(records),
        len(merged),
        len(pool),
        mapping_offset,
        removal_offset,
        pool_offset,
    )
    assert len(blob) == header_len
    for codepoint, offset, length in records:
        blob += struct.pack("<IIHH", codepoint, offset, length, 0)
    for first, last in merged:
        blob += struct.pack("<II", first, last)
    for codepoint in pool:
        blob += struct.pack("<I", codepoint)
    print(
        f"{property_name}: {len(records)} mappings, {len(merged)} removal "
        f"ranges, {len(pool)} pool code points"
    )
    return bytes(blob)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    data = source.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != DERIVED_NORMALIZATION_SHA256:
        raise SystemExit(
            f"{source}: expected Unicode {'.'.join(map(str, UNICODE_VERSION))} "
            f"SHA-256 {DERIVED_NORMALIZATION_SHA256}, found {actual}"
        )
    text = data.decode("utf-8")
    out_dir.mkdir(parents=True, exist_ok=True)
    for property_name, filename in PROPERTIES:
        (out_dir / filename).write_bytes(build(text, property_name))
        print(f"wrote {out_dir / filename}")


if __name__ == "__main__":
    main()
