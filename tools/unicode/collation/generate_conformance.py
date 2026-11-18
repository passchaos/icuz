#!/usr/bin/env python3
"""Generate compact CLDR 48 root conformance fixtures from the short test files.

Usage:
    generate_conformance.py CollationTest_NON_IGNORABLE_SHORT.txt \
        CollationTest_SHIFTED_SHORT.txt out_dir
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

NON_IGNORABLE_SHA256 = "7063c05ad292803f8d4269abc64e2ce50ab96d0038f799670ed325f9a5e20bb8"
SHIFTED_SHA256 = "51a2f9d9d0ed4a54bb123c72df7211e9f3b83ca15249ad350cd8780f8ccbf7c5"


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected CLDR 48 source SHA-256 "
            f"{expected_sha256}, found {actual}"
        )
    return data.decode("utf-8")


def parse_cases(text: str) -> list[list[int]]:
    cases: list[list[int]] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        cases.append([int(token, 16) for token in line.split()])
    if not cases:
        raise SystemExit("missing conformance cases")
    return cases


def render(cases: list[list[int]]) -> bytes:
    payload = bytearray(
        struct.pack("<4sBBBB I", b"CJCT", 1, 17, 0, 0, len(cases))
    )
    for case in cases:
        if not case or len(case) > 0xFF:
            raise SystemExit("unsupported conformance case length")
        payload.append(len(case))
        for codepoint in case:
            payload += struct.pack("<I", codepoint)
    return bytes(payload)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    non_ignorable = parse_cases(
        checked_text(Path(sys.argv[1]), NON_IGNORABLE_SHA256)
    )
    shifted = parse_cases(checked_text(Path(sys.argv[2]), SHIFTED_SHA256))
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "conformance_non_ignorable.bin").write_bytes(
        render(non_ignorable)
    )
    (out_dir / "conformance_shifted.bin").write_bytes(render(shifted))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
