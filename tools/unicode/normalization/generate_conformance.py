#!/usr/bin/env python3
"""Compile Unicode 17 NormalizationTest.txt into a compact NFC fixture."""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path


SOURCE_SHA256 = "5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} NormalizationTest.txt output.bin"
        )
    source_path = Path(sys.argv[1])
    source_bytes = source_path.read_bytes()
    if hashlib.sha256(source_bytes).hexdigest() != SOURCE_SHA256:
        raise SystemExit("expected Unicode 17.0 NormalizationTest.txt")
    source = source_bytes.decode("utf-8")

    cases: list[list[list[int]]] = []
    for line_number, raw in enumerate(source.splitlines(), 1):
        row = raw.split("#", 1)[0].strip()
        if not row or row.startswith("@"):
            continue
        fields = row.split(";")
        if len(fields) < 5:
            raise SystemExit(f"line {line_number}: malformed normalization row")
        columns = [
            [int(token, 16) for token in field.split()]
            for field in fields[:5]
        ]
        if any(len(column) > 0xFF for column in columns):
            raise SystemExit(f"line {line_number}: normalization column too long")
        cases.append(columns)
    if len(cases) != 20034:
        raise SystemExit(f"expected 20034 Unicode 17 cases, found {len(cases)}")

    output = bytearray(struct.pack("<4sBBBBI", b"CJNF", 1, 17, 0, 0, len(cases)))
    for columns in cases:
        output.extend(bytes(len(column) for column in columns))
        for column in columns:
            output.extend(struct.pack(f"<{len(column)}I", *column))
    Path(sys.argv[2]).write_bytes(output)


if __name__ == "__main__":
    main()
