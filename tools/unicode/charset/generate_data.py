#!/usr/bin/env python3
"""Generate charset conversion tables from the WHATWG Encoding indexes.

Usage:
    generate_data.py indexes.json out_dir
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "b7c8961095f0b4cae8f4a16a5011e7c84047a60c1277e28ee8df9e56074ee509"

# Order must match the single-byte table index in src/unicode/charset.zig.
SINGLE_BYTE = (
    ("ibm866", "ibm866"),
    ("iso_8859_2", "iso-8859-2"),
    ("iso_8859_3", "iso-8859-3"),
    ("iso_8859_4", "iso-8859-4"),
    ("iso_8859_5", "iso-8859-5"),
    ("iso_8859_6", "iso-8859-6"),
    ("iso_8859_7", "iso-8859-7"),
    ("iso_8859_8", "iso-8859-8"),
    ("iso_8859_8_i", "iso-8859-8"),
    ("iso_8859_10", "iso-8859-10"),
    ("iso_8859_13", "iso-8859-13"),
    ("iso_8859_14", "iso-8859-14"),
    ("iso_8859_15", "iso-8859-15"),
    ("iso_8859_16", "iso-8859-16"),
    ("koi8_r", "koi8-r"),
    ("koi8_u", "koi8-u"),
    ("macintosh", "macintosh"),
    ("windows_874", "windows-874"),
    ("windows_1250", "windows-1250"),
    ("windows_1251", "windows-1251"),
    ("windows_1252", "windows-1252"),
    ("windows_1253", "windows-1253"),
    ("windows_1254", "windows-1254"),
    ("windows_1255", "windows-1255"),
    ("windows_1256", "windows-1256"),
    ("windows_1257", "windows-1257"),
    ("windows_1258", "windows-1258"),
    ("x_mac_cyrillic", "x-mac-cyrillic"),
)

SECTION_SINGLE_BYTE_FORWARD = 1
SECTION_SINGLE_BYTE_REVERSE = 2
SECTION_JIS0208_FORWARD = 3
SECTION_JIS0208_REVERSE = 4
SECTION_JIS0212_FORWARD = 5
SECTION_GB18030_FORWARD = 6
SECTION_GB18030_REVERSE = 7
SECTION_GB18030_RANGES_BY_POINTER = 8
SECTION_GB18030_RANGES_BY_CODEPOINT = 9
SECTION_BIG5_FORWARD = 10
SECTION_BIG5_REVERSE = 11
SECTION_EUC_KR_FORWARD = 12
SECTION_EUC_KR_REVERSE = 13
SECTION_ISO2022JP_KATAKANA_FORWARD = 14
SECTION_ISO2022JP_KATAKANA_REVERSE = 15
SECTION_JIS0212_REVERSE = 16
SECTION_SHIFT_JIS_REVERSE = 17

BIG5_LAST_POINTER = {0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345}


def checked_indexes(path: Path) -> dict:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != INPUT_SHA256:
        raise SystemExit(
            f"{path}: expected WHATWG index SHA-256 {INPUT_SHA256}, "
            f"found {actual}"
        )
    return json.loads(data)


def align4(payload: bytearray) -> None:
    while len(payload) % 4 != 0:
        payload.append(0)


def add_section(
    sections: list[tuple[int, bytes]],
    payload: bytearray,
    section_id: int,
    body: bytes,
) -> None:
    align4(payload)
    sections.append((section_id, body))
    payload.extend(body)


def forward_index(values: list[int | None]) -> bytes:
    body = bytearray(struct.pack("<I", len(values)))
    for value in values:
        body += struct.pack("<I", 0 if value is None else value)
    return bytes(body)


def reverse_index(
    values: list[int | None],
    *,
    exclude=None,
    last_for: set[int] = frozenset(),
) -> bytes:
    reverse: dict[int, int] = {}
    for pointer, value in enumerate(values):
        if value is None or value == 0:
            continue
        if exclude is not None and exclude(pointer):
            continue
        if value in last_for:
            reverse[value] = pointer
        elif value not in reverse:
            reverse[value] = pointer
    entries = sorted(reverse.items())
    # Split layout: sorted code points (u32) for the binary search, then the
    # parallel u16 pointers. Probes touch only the compact code-point array.
    body = bytearray(struct.pack("<I", len(entries)))
    for codepoint, _pointer in entries:
        body += struct.pack("<I", codepoint)
    for _codepoint, pointer in entries:
        if pointer > 0xFFFF:
            raise SystemExit("reverse pointer does not fit in u16")
        body += struct.pack("<H", pointer)
    return bytes(body)


def pair_table(entries: list[tuple[int, int]]) -> bytes:
    body = bytearray(struct.pack("<I", len(entries)))
    for first, second in entries:
        body += struct.pack("<II", first, second)
    return bytes(body)


def single_byte_forward(indexes: dict) -> bytes:
    body = bytearray(struct.pack("<HH", len(SINGLE_BYTE), 128))
    for _, index_name in SINGLE_BYTE:
        values = indexes[index_name]
        if len(values) != 128:
            raise SystemExit(f"{index_name}: expected 128 entries")
        for value in values:
            if value is not None and value > 0xFFFF:
                raise SystemExit(f"{index_name}: codepoint above BMP")
            body += struct.pack("<H", 0 if value is None else value)
    return bytes(body)


def single_byte_reverse(indexes: dict) -> bytes:
    tables: list[list[tuple[int, int]]] = []
    for _, index_name in SINGLE_BYTE:
        values = indexes[index_name]
        reverse: dict[int, int] = {}
        for offset, value in enumerate(values):
            if value is None:
                continue
            byte = 0x80 + offset
            if value not in reverse:
                reverse[value] = byte
        tables.append(sorted(reverse.items()))
    body = bytearray(struct.pack("<H", len(tables)))
    for table in tables:
        body += struct.pack("<H", len(table))
    for table in tables:
        for codepoint, byte in table:
            body += struct.pack("<HB", codepoint, byte)
    return bytes(body)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    input_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    indexes = checked_indexes(input_path)
    sections: list[tuple[int, bytes]] = []
    payload = bytearray()

    add_section(
        sections,
        payload,
        SECTION_SINGLE_BYTE_FORWARD,
        single_byte_forward(indexes),
    )
    add_section(
        sections,
        payload,
        SECTION_SINGLE_BYTE_REVERSE,
        single_byte_reverse(indexes),
    )
    for name, section_id in (
        ("jis0208", SECTION_JIS0208_FORWARD),
        ("jis0212", SECTION_JIS0212_FORWARD),
        ("gb18030", SECTION_GB18030_FORWARD),
        ("big5", SECTION_BIG5_FORWARD),
        ("euc-kr", SECTION_EUC_KR_FORWARD),
    ):
        add_section(sections, payload, section_id, forward_index(indexes[name]))
    for name, section_id in (
        ("jis0208", SECTION_JIS0208_REVERSE),
        ("jis0212", SECTION_JIS0212_REVERSE),
        ("gb18030", SECTION_GB18030_REVERSE),
        ("euc-kr", SECTION_EUC_KR_REVERSE),
    ):
        add_section(sections, payload, section_id, reverse_index(indexes[name]))
    add_section(
        sections,
        payload,
        SECTION_SHIFT_JIS_REVERSE,
        reverse_index(
            indexes["jis0208"],
            exclude=lambda pointer: 8272 <= pointer <= 8835,
        ),
    )
    add_section(
        sections,
        payload,
        SECTION_BIG5_REVERSE,
        reverse_index(
            indexes["big5"],
            exclude=lambda pointer: pointer < (0xA1 - 0x81) * 157,
            last_for=BIG5_LAST_POINTER,
        ),
    )

    ranges = [(pointer, codepoint) for pointer, codepoint in indexes["gb18030-ranges"]]
    add_section(
        sections,
        payload,
        SECTION_GB18030_RANGES_BY_POINTER,
        pair_table(sorted(ranges)),
    )
    add_section(
        sections,
        payload,
        SECTION_GB18030_RANGES_BY_CODEPOINT,
        pair_table(sorted((codepoint, pointer) for pointer, codepoint in ranges)),
    )
    add_section(
        sections,
        payload,
        SECTION_ISO2022JP_KATAKANA_FORWARD,
        forward_index(indexes["iso-2022-jp-katakana"]),
    )
    add_section(
        sections,
        payload,
        SECTION_ISO2022JP_KATAKANA_REVERSE,
        reverse_index(indexes["iso-2022-jp-katakana"]),
    )

    header = bytearray(b"CJCS")
    header += struct.pack("<B3B", 2, 17, 0, 0)
    header += struct.pack("<HH", len(sections), 0)
    table_offset = len(header) + len(sections) * 12
    offset = table_offset
    table = bytearray()
    for index, (section_id, body) in enumerate(sections):
        # Payloads are aligned before each section; do not pad after the
        # final one or the computed size will exceed the blob.
        if index > 0:
            while offset % 4 != 0:
                offset += 1
        table += struct.pack("<HHII", section_id, 0, offset, len(body))
        offset += len(body)
    blob = header + table + payload
    if len(blob) != offset:
        raise SystemExit("internal size mismatch")
    (out_dir / "data.bin").write_bytes(blob)
    print(f"wrote {out_dir / 'data.bin'} ({len(blob)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
