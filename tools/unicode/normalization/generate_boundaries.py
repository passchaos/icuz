#!/usr/bin/env python3
"""Generate Normalizer2 boundary/inert flags with PyICU.

Usage:
    generate_boundaries.py UnicodeData.txt CompositionExclusions.txt \
        DerivedNormalizationProps.txt out_file

The output is a CJNB v1 blob with one record per (code point, form) whose
`isInert` / `hasBoundaryBefore` / `hasBoundaryAfter` tuple differs from the
all-true default. Records are sorted by code point and form.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path

import icu

UNICODE_DATA_SHA = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
COMPOSITION_EXCLUSIONS_SHA = "2f239196ef3b5b61db5cc476e9bd80f534d15aa1b74e1be1dea5d042a344c85f"
DERIVED_NORMALIZATION_PROPS_SHA = (
    "71fd6a206a2c0cdd41feb6b7f656aa31091db45e9cedc926985d718397f9e488"
)
UNICODE_VERSION = (17, 0, 0)
FORMS = (
    ("nfc", icu.Normalizer2.getNFCInstance()),
    ("nfd", icu.Normalizer2.getNFDInstance()),
    ("nfkc", icu.Normalizer2.getNFKCInstance()),
    ("nfkd", icu.Normalizer2.getNFKDInstance()),
)


def checked_text(path: Path, expected: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(
            f"{path}: expected SHA-256 {expected}, found {actual}"
        )
    return data.decode("utf-8")


def parse_composition_exclusions(path: Path) -> set[int]:
    result: set[int] = set()
    for line in checked_text(path, COMPOSITION_EXCLUSIONS_SHA).splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        result.add(int(line, 16))
    return result


def candidates(
    unicode_data: Path,
    exclusions_path: Path,
    derived_props: Path,
) -> list[int]:
    values: set[int] = set()
    for line in checked_text(unicode_data, UNICODE_DATA_SHA).splitlines():
        fields = line.split(";")
        if len(fields) < 6:
            continue
        codepoint = int(fields[0], 16)
        combining_class = int(fields[3])
        decomposition = fields[5]
        if combining_class != 0:
            values.add(codepoint)
        if decomposition:
            values.add(codepoint)
    exclusions = parse_composition_exclusions(exclusions_path)
    for line in checked_text(unicode_data, UNICODE_DATA_SHA).splitlines():
        fields = line.split(";")
        if len(fields) < 6:
            continue
        codepoint = int(fields[0], 16)
        decomposition = fields[5]
        if not decomposition or decomposition.startswith("<"):
            continue
        if codepoint in exclusions:
            continue
        parts = [int(part, 16) for part in decomposition.split()]
        if len(parts) == 2:
            values.add(codepoint)
            values.add(parts[0])
    for line in checked_text(
        derived_props,
        DERIVED_NORMALIZATION_PROPS_SHA,
    ).splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.match(r"^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)", line)
        if match is None:
            continue
        prop = match.group(3)
        if prop not in ("NFC_QC", "NFD_QC", "NFKC_QC", "NFKD_QC"):
            continue
        value = line.split(";")[1].split("#")[0].strip().split()[0]
        if value == "Y":
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        for codepoint in range(first, last + 1):
            values.add(codepoint)
    values.update(range(0x1100, 0x1200))
    values.update(range(0xAC00, 0xD7A4))
    return sorted(values)


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    codepoints = candidates(
        Path(sys.argv[1]),
        Path(sys.argv[2]),
        Path(sys.argv[3]),
    )
    entries = []
    for codepoint in codepoints:
        character = chr(codepoint)
        for form_index, (_, normalizer) in enumerate(FORMS):
            flags = 0
            if normalizer.isInert(character):
                flags |= 1
            if normalizer.hasBoundaryBefore(character):
                flags |= 2
            if normalizer.hasBoundaryAfter(character):
                flags |= 4
            if flags != 7:
                entries.append((codepoint, form_index, flags))
    entries.sort()
    blob = bytearray(b"CJNB")
    blob += bytes((1, *UNICODE_VERSION))
    blob += struct.pack("<I", len(entries))
    for codepoint, form_index, flags in entries:
        blob += struct.pack("<IBBH", codepoint, form_index, flags, 0)
    Path(sys.argv[4]).write_bytes(bytes(blob))
    print(
        f"wrote {len(entries)} boundary records for {len(codepoints)} candidates"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
