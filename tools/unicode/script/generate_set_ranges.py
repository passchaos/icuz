#!/usr/bin/env python3
"""Generate precomputed Script and Script_Extensions ranges.

Usage:
    generate_set_ranges.py src/unicode/script/data.bin \
        src/unicode/script_extensions/data.bin src/unicode/script/types.zig out_dir

Emits a `CJSS` v1 blob consumed by src/unicode/script/set_ranges.zig. It holds
the coalesced scalar ranges for every Script value and every
Script_Extensions value, so set construction copies ranges instead of scanning
all 1.1M scalars.

Both inputs are committed blobs, so this generator is reproducible without a
UCD checkout.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

UNICODE_VERSION = (17, 0, 0)
PAGE_SIZE = 256
PAGE_COUNT = 0x1100


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def parse_script_count(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    body = text.split("pub const Script = enum {", 1)[1].split("};", 1)[0]
    count = 0
    for line in body.splitlines():
        entry = line.strip()
        if not entry or entry.startswith("//"):
            continue
        count += 1
    return count


def load_scripts(
    path: Path,
) -> tuple[list[int], list[bytes], int]:
    data = path.read_bytes()
    if (
        data[:4] != b"CJS1"
        or data[4] != 1
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{path}: unexpected Script table header")
    index_count = read_u16(data, 12)
    page_count = read_u16(data, 14)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{path}: unexpected Script page index length")
    pages_offset = 16 + index_count * 2
    if pages_offset + page_count * PAGE_SIZE != len(data):
        raise SystemExit(f"{path}: unexpected Script page payload length")
    index = [read_u16(data, 16 + page * 2) for page in range(index_count)]
    pages = [
        data[pages_offset + slot * PAGE_SIZE : pages_offset + (slot + 1) * PAGE_SIZE]
        for slot in range(page_count)
    ]
    return index, pages, page_count


def load_extensions(path: Path) -> dict[int, set[int]]:
    data = path.read_bytes()
    if (
        data[:4] != b"CJSE"
        or data[4] != 1
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{path}: unexpected Script_Extensions header")
    set_count = read_u16(data, 12)
    member_count = read_u16(data, 14)
    entry_count = read_u32(data, 16)
    offsets_offset = 20
    members_offset = offsets_offset + (set_count + 1) * 2
    entries_offset = members_offset + member_count
    if entries_offset + entry_count * 8 != len(data):
        raise SystemExit(f"{path}: unexpected Script_Extensions layout")
    offsets = [
        read_u16(data, offsets_offset + index * 2)
        for index in range(set_count + 1)
    ]
    members = data[members_offset : members_offset + member_count]
    explicit: dict[int, set[int]] = {}
    for index in range(entry_count):
        base = entries_offset + index * 8
        codepoint = read_u32(data, base)
        set_index = data[base + 4]
        explicit[codepoint] = set(
            members[offsets[set_index] : offsets[set_index + 1]]
        )
    return explicit


def build_masks(
    pages: list[bytes],
    script_count: int,
) -> list[list[int]]:
    masks: list[list[int]] = []
    for page in pages:
        page_masks = [0] * script_count
        for slot, script_id in enumerate(page):
            if script_id >= script_count:
                raise SystemExit(f"script id {script_id} exceeds the enum")
            page_masks[script_id] |= 1 << slot
        masks.append(page_masks)
    return masks


def apply_extensions(
    index: list[int],
    pages: list[bytes],
    masks: list[list[int]],
    explicit: dict[int, set[int]],
    script_count: int,
) -> list[list[int]]:
    overridden = [list(page_masks) for page_masks in masks]
    for codepoint, members in explicit.items():
        page = codepoint >> 8
        slot = index[page]
        bit = 1 << (codepoint & 0xFF)
        fallback = pages[slot][codepoint & 0xFF]
        for script in range(script_count):
            wanted = script in members
            if wanted == (script == fallback):
                continue
            if wanted:
                overridden[slot][script] |= bit
            else:
                overridden[slot][script] &= ~bit
    return overridden


def page_runs(index: list[int], masks: list[list[int]], entry: int) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    for page, page_slot in enumerate(index):
        mask = masks[page_slot][entry]
        base = page * PAGE_SIZE
        while mask:
            low = mask & -mask
            start = low.bit_length() - 1
            rest = mask >> start
            length = (rest ^ (rest + 1)).bit_length() - 1
            first = base + start
            last = first + length - 1
            if runs and first == runs[-1][1] + 1:
                runs[-1] = (runs[-1][0], last)
            else:
                runs.append((first, last))
            mask &= ~(((1 << length) - 1) << start)
    return runs


def render(
    script_ranges: list[list[tuple[int, int]]],
    extension_ranges: list[list[tuple[int, int]]],
) -> bytes:
    range_count = sum(len(ranges) for ranges in script_ranges)
    range_count += sum(len(ranges) for ranges in extension_ranges)
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHI",
            b"CJSS",
            1,
            *UNICODE_VERSION,
            len(script_ranges),
            len(extension_ranges),
            range_count,
        )
    )
    offset = 0
    for ranges in script_ranges:
        payload += struct.pack("<II", offset, len(ranges))
        offset += len(ranges)
    for ranges in extension_ranges:
        payload += struct.pack("<II", offset, len(ranges))
        offset += len(ranges)
    for ranges in script_ranges:
        for first, last in ranges:
            payload += struct.pack("<II", first, last)
    for ranges in extension_ranges:
        for first, last in ranges:
            payload += struct.pack("<II", first, last)
    return bytes(payload)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    script_path = Path(sys.argv[1])
    extension_path = Path(sys.argv[2])
    types_path = Path(sys.argv[3])
    out_dir = Path(sys.argv[4])
    out_dir.mkdir(parents=True, exist_ok=True)

    script_count = parse_script_count(types_path)
    index, pages, _ = load_scripts(script_path)
    explicit = load_extensions(extension_path)

    script_masks = build_masks(pages, script_count)
    extension_masks = apply_extensions(
        index,
        pages,
        script_masks,
        explicit,
        script_count,
    )
    script_ranges = [
        page_runs(index, script_masks, script) for script in range(script_count)
    ]
    extension_ranges = [
        page_runs(index, extension_masks, script)
        for script in range(script_count)
    ]

    (out_dir / "set_ranges.bin").write_bytes(
        render(script_ranges, extension_ranges)
    )


if __name__ == "__main__":
    main()
