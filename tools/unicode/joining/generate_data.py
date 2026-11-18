#!/usr/bin/env python3
"""Generate the Unicode 17 Joining_Type page table.

Usage:
    tools/unicode/joining/generate_data.py \
        path/to/extracted/DerivedJoiningType.txt \
        src/unicode/joining/data.bin

The byte values are the `Type` enum discriminants in `joining.zig`:
Non_Joining=0, Right=1, Left=2, Dual=3, Join_Causing=4, Transparent=5.
The header records a fingerprint of that enum so reordering it without
regenerating the blob fails at compile time.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "f39ebe974825d6736aee15582250307aa532b2cfab3caf3f86bd23fddc9c5c4d"
PAGE_SIZE = 256
PAGE_COUNT = 0x1100
TYPE_ORDER = ["non_joining", "right", "left", "dual", "join_causing", "transparent"]
TYPE_INDEX = {
    "U": 0,
    "R": 1,
    "L": 2,
    "D": 3,
    "C": 4,
    "T": 5,
}

LINE_RE = re.compile(
    r"^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*([A-Z])\b"
)


def checked_text(path: Path) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != INPUT_SHA256:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 {INPUT_SHA256}, "
            f"found {actual}"
        )
    return data.decode("utf-8")


def type_fingerprint() -> int:
    value = 2166136261
    for name in TYPE_ORDER:
        for byte in name.encode("ascii"):
            value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
        value = ((value ^ 0xFF) * 16777619) & 0xFFFFFFFF
    return value


def parse_ranges(text: str) -> tuple[str, list[tuple[int, int, int]]]:
    version = "unknown"
    ranges: list[tuple[int, int, int]] = []
    for line in text.splitlines():
        if line.startswith("# DerivedJoiningType-"):
            version = line.removeprefix("# DerivedJoiningType-").removesuffix(".txt")
        match = LINE_RE.match(line)
        if match is None:
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        joining_type = TYPE_INDEX[match.group(3)]
        ranges.append((first, last, joining_type))
    if not ranges:
        raise SystemExit("missing DerivedJoiningType ranges")
    return version, ranges


def build_values(ranges: list[tuple[int, int, int]]) -> list[int]:
    values = [0] * 0x110000
    for first, last, joining_type in ranges:
        for codepoint in range(first, last + 1):
            values[codepoint] = joining_type
    return values


def build_page_table(values: list[int]) -> tuple[list[int], list[bytes]]:
    pages: list[bytes] = []
    page_index: dict[bytes, int] = {}
    index: list[int] = []
    for page in range(PAGE_COUNT):
        chunk = bytes(values[page * PAGE_SIZE : (page + 1) * PAGE_SIZE])
        slot = page_index.get(chunk)
        if slot is None:
            slot = len(pages)
            if slot > 0xFFFF:
                raise SystemExit("joining page table exceeds u16 index space")
            page_index[chunk] = slot
            pages.append(chunk)
        index.append(slot)
    return index, pages


def render_blob(version: str, index: list[int], pages: list[bytes]) -> bytes:
    parts = version.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        raise SystemExit(f"invalid Unicode version: {version}")
    major, minor, patch = (int(part) for part in parts)
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHI",
            b"CJJ1",
            1,
            major,
            minor,
            patch,
            PAGE_COUNT,
            len(pages),
            type_fingerprint(),
        )
    )
    for slot in index:
        payload += struct.pack("<H", slot)
    for page in pages:
        payload += page
    return bytes(payload)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    version, ranges = parse_ranges(checked_text(input_path))
    index, pages = build_page_table(build_values(ranges))
    output_path.write_bytes(render_blob(version, index, pages))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
