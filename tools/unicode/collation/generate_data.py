#!/usr/bin/env python3
"""Generate CLDR 48 root collation data from allkeys_CLDR.txt.

Usage:
    generate_data.py allkeys_CLDR.txt allkeys.txt out_dir

The output is a deduplicated page table mapping a leading code point to a
contiguous entry range, followed by entry records and a flat collation-element
array. Contractions are stored in the same entry list and tried longest-first.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "f6f8961f6c51373bdc00b09fb61cc8c07bec4122bc4b8bcb50ff71c4b0901ab5"
UCA_INPUT_SHA256 = "2503d09367c2639a4fb8fd55e81aaacb0d9fb4ea26600333329bd12456b99ecd"
PAGE_SIZE = 256
PAGE_COUNT = 0x1100
ENTRY_LEN = 20
CE_LEN = 16
# Root weights are stored with low bits reserved for locale tailorings.
WEIGHT_SCALE = 12

CE_RE = re.compile(
    r"\[([.*])([0-9A-Fa-f]{4})\.([0-9A-Fa-f]{4})\.([0-9A-Fa-f]{4})\]"
)
IMPLICIT_RE = re.compile(
    r"^@implicitweights\s+([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\s*;\s*([0-9A-Fa-f]+)"
)


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected source SHA-256 {expected_sha256}, "
            f"found {actual}"
        )
    return data.decode("utf-8")


def parse_entries(
    text: str,
) -> list[tuple[tuple[int, ...], list[tuple[int, int, int, bool]]]]:
    entries: list[tuple[tuple[int, ...], list[tuple[int, int, int, bool]]]] = []
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("@"):
            continue
        if ";" not in line:
            continue
        left, right = line.split(";", 1)
        sequence = tuple(int(token, 16) for token in left.split())
        if not sequence or len(sequence) > 3:
            raise SystemExit(
                f"allkeys line {line_number}: unsupported contraction length"
            )
        ces: list[tuple[int, int, int, bool]] = []
        for marker, primary, secondary, tertiary in CE_RE.findall(right):
            ces.append(
                (
                    int(primary, 16) << WEIGHT_SCALE,
                    int(secondary, 16) << WEIGHT_SCALE,
                    int(tertiary, 16) << WEIGHT_SCALE,
                    marker == "*",
                )
            )
        if not ces:
            raise SystemExit(f"allkeys line {line_number}: missing collation elements")
        entries.append((sequence, ces))
    if not entries:
        raise SystemExit("missing collation entries")
    return entries


def parse_implicit(text: str) -> list[tuple[int, int, int]]:
    implicit: list[tuple[int, int, int]] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = IMPLICIT_RE.match(line)
        if match is None:
            continue
        implicit.append(
            (
                int(match.group(1), 16),
                int(match.group(2), 16),
                int(match.group(3), 16),
            )
        )
    if not implicit:
        raise SystemExit("missing UCA implicit weights")
    return implicit


def build_tables(
    entries: list[tuple[tuple[int, ...], list[tuple[int, int, int, bool]]]],
) -> tuple[list[tuple[int, int, int, int, int, int]], list[tuple[int, int, int, bool]], list[int], list[tuple[int, ...]]]:
    flat_ces: list[tuple[int, int, int, bool]] = []
    records: list[tuple[int, int, int, int, int, int]] = []
    for sequence, ces in entries:
        offset = len(flat_ces)
        flat_ces.extend(ces)
        first = sequence[0]
        second = sequence[1] if len(sequence) > 1 else 0
        third = sequence[2] if len(sequence) > 2 else 0
        records.append((first, second, third, offset, len(ces), len(sequence)))

    records.sort(key=lambda record: (record[0], -record[5], record[1], record[2]))
    if len(records) > 0xFFFF:
        raise SystemExit("collation entry count exceeds u16 page indices")

    index: list[int] = []
    pages: list[tuple[int, ...]] = []
    page_index: dict[tuple[int, ...], int] = {}
    entry_index = 0
    for page in range(PAGE_COUNT):
        slots: list[int] = []
        for slot in range(PAGE_SIZE):
            codepoint = page * PAGE_SIZE + slot
            while (
                entry_index < len(records)
                and records[entry_index][0] < codepoint
            ):
                entry_index += 1
            slots.append(entry_index)
        chunk = tuple(slots)
        page_slot = page_index.get(chunk)
        if page_slot is None:
            page_slot = len(pages)
            if page_slot > 0xFFFF:
                raise SystemExit("collation page table exceeds u16 index space")
            page_index[chunk] = page_slot
            pages.append(chunk)
        index.append(page_slot)
    return records, flat_ces, index, pages


def render_blob(
    records: list[tuple[int, int, int, int, int, int]],
    flat_ces: list[tuple[int, int, int, bool]],
    index: list[int],
    pages: list[tuple[int, ...]],
) -> bytes:
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHII",
            b"CJCL",
            2,
            17,
            0,
            0,
            PAGE_COUNT,
            len(pages),
            len(records),
            len(flat_ces),
        )
    )
    for slot in index:
        payload += struct.pack("<H", slot)
    for page in pages:
        payload += struct.pack("<256H", *page)
    for first, second, third, offset, count, length in records:
        payload += struct.pack(
            "<IIIIBBH",
            first,
            second,
            third,
            offset,
            count,
            length,
            0,
        )
    for primary, secondary, tertiary, variable in flat_ces:
        payload += struct.pack(
            "<IIIBBH",
            primary,
            secondary,
            tertiary,
            1 if variable else 0,
            0,
            0,
        )
    return bytes(payload)


def render_implicit(implicit: list[tuple[int, int, int]]) -> str:
    origin_by_base: dict[int, int] = {}
    for first, _, base in implicit:
        origin_by_base.setdefault(base, first)

    lines = [
        "// Generated by tools/unicode/collation/generate_data.py from CLDR 48 (UCA 17.0.0).",
        f"// allkeys_CLDR.txt SHA-256: {INPUT_SHA256}",
        f"// allkeys.txt SHA-256: {UCA_INPUT_SHA256}",
        "",
        "pub const Range = struct {",
        "    first: u21,",
        "    last: u21,",
        "    origin: u21,",
        "    base: u32,",
        "};",
        "",
        "pub const ranges = [_]Range{",
    ]
    for first, last, base in sorted(implicit):
        origin = origin_by_base[base]
        lines.append(
            f"    .{{ .first = 0x{first:x}, .last = 0x{last:x}, "
            f".origin = 0x{origin:x}, .base = 0x{base << WEIGHT_SCALE:x} }},"
        )
    lines.extend(["};", ""])
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    input_path = Path(sys.argv[1])
    uca_path = Path(sys.argv[2])
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    entries = parse_entries(checked_text(input_path, INPUT_SHA256))
    implicit = parse_implicit(checked_text(uca_path, UCA_INPUT_SHA256))
    records, flat_ces, index, pages = build_tables(entries)
    (out_dir / "data.bin").write_bytes(
        render_blob(records, flat_ces, index, pages)
    )
    (out_dir / "implicit.zig").write_text(
        render_implicit(implicit),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
