#!/usr/bin/env python3
"""Compare the committed Letter flag with Unicode 17 and optional CJWB v1 data.

No extra Unicode dataset is committed. Supply the canonical UnicodeData.txt
used by generate_data.py, and optionally a previously committed word blob.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIMIT = 0x110000
UNICODE_DATA_SHA256 = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"


def expand_blob(path: Path, version: int) -> tuple[bytes, bytes]:
    data = path.read_bytes()
    if data[:8] != b"CJWB" + bytes((version, 17, 0, 0)):
        raise SystemExit(f"{path}: unexpected word property format/version")
    index_count, page_count = struct.unpack_from("<HH", data, 8)
    pages_offset = 12 + index_count * 2
    if index_count != 0x1100 or pages_offset + page_count * 256 != len(data):
        raise SystemExit(f"{path}: invalid word property layout")
    properties = bytearray()
    for page in range(index_count):
        slot = struct.unpack_from("<H", data, 12 + page * 2)[0]
        if slot >= page_count:
            raise SystemExit(f"{path}: page index outside property data")
        offset = pages_offset + slot * 256
        properties.extend(data[offset : offset + 256])
    return data, bytes(properties)


def expected_letters(path: Path) -> tuple[bytearray, int]:
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != UNICODE_DATA_SHA256:
        raise SystemExit("expected the pinned Unicode 17.0 UnicodeData input")
    letters = bytearray(LIMIT)
    pending = None
    range_count = 0
    for line in data.decode("utf-8").splitlines():
        fields = line.split(";")
        codepoint = int(fields[0], 16)
        name, category = fields[1:3]
        if name.endswith(", First>"):
            if pending is not None:
                raise SystemExit("nested UnicodeData range")
            pending = (codepoint, category)
            continue
        if name.endswith(", Last>"):
            if pending is None or pending[1] != category or pending[0] > codepoint:
                raise SystemExit("invalid UnicodeData First/Last range")
            start = pending[0]
            pending = None
            range_count += 1
        else:
            start = codepoint
        if category in ("Lu", "Ll", "Lt", "Lm", "Lo"):
            letters[start : codepoint + 1] = bytes([1]) * (codepoint - start + 1)
    if pending is not None:
        raise SystemExit("unclosed UnicodeData range")
    return letters, range_count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("unicode_data", type=Path)
    parser.add_argument("--previous-blob", type=Path)
    parser.add_argument("--report", type=Path)
    options = parser.parse_args()
    expected, range_count = expected_letters(options.unicode_data)
    data, actual = expand_blob(ROOT / "src/unicode/word/data.bin", 2)
    for codepoint, (value, letter) in enumerate(zip(actual, expected)):
        if bool(value & 0x80) != bool(letter):
            raise SystemExit(f"Letter mismatch at U+{codepoint:04X}")
    report = {
        "unicode_version": "17.0.0",
        "unicode_data_sha256": UNICODE_DATA_SHA256,
        "word_blob_sha256": hashlib.sha256(data).hexdigest(),
        "word_blob_bytes": len(data),
        "codepoints_compared": LIMIT,
        "valid_scalars_compared": LIMIT - 0x800,
        "letter_codepoints": sum(expected),
        "first_last_ranges_compared": range_count,
        "letter_mismatches": 0,
    }
    if options.previous_blob is not None:
        previous_data, previous = expand_blob(options.previous_blob, 1)
        for codepoint, (before, after) in enumerate(zip(previous, actual)):
            if before & 0x80:
                raise SystemExit(f"previous reserved bit set at U+{codepoint:04X}")
            if before != after & 0x7F:
                raise SystemExit(f"existing word property mismatch at U+{codepoint:04X}")
        report.update({
            "previous_word_blob_sha256": hashlib.sha256(previous_data).hexdigest(),
            "previous_word_blob_bytes": len(previous_data),
            "existing_seven_bit_mismatches": 0,
        })
    output = json.dumps(report, indent=2) + "\n"
    if options.report is not None:
        options.report.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    main()
