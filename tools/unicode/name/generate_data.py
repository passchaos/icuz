#!/usr/bin/env python3
"""Generate the Unicode 17 character-name and alias table.

Usage:
    generate_data.py DerivedName.txt NameAliases.txt out_dir

Explicit names and aliases are stored in `data.bin`. Pattern names such as
`CJK UNIFIED IDEOGRAPH-*` are emitted as ranges in `ranges.zig` and expanded at
runtime, which keeps the embedded pool small.

The blob also carries a name-hash index: every record's loose-normalized name
is hashed with 32-bit FNV-1a and the (hash, record index) pairs are sorted, so
`findByName` binary-searches instead of scanning the whole pool.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

DERIVED_NAME_SHA256 = "019758bbe6c756c40fca6d505187ea660c5e195533e2ff2c841963a212c9d369"
NAME_ALIASES_SHA256 = "793f6f1e4d15fd90f05ae66460191dc4d75d1fea90136a25f30dd6a4cb950eac"

TYPE_INDEX = {
    "correction": 1,
    "control": 2,
    "alternate": 3,
    "figment": 4,
    "abbreviation": 5,
}


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 "
            f"{expected_sha256}, found {actual}"
        )
    return data.decode("utf-8")


def parse_span(field: str) -> tuple[int, int]:
    if ".." in field:
        first, last = field.split("..", 1)
        return int(first, 16), int(last, 16)
    codepoint = int(field, 16)
    return codepoint, codepoint


def parse_names(
    text: str,
) -> tuple[list[tuple[int, str]], list[tuple[int, int, str]]]:
    explicit: list[tuple[int, str]] = []
    patterns: list[tuple[int, int, str]] = []
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2:
            raise SystemExit(f"DerivedName line {line_number}: malformed row")
        first, last = parse_span(fields[0])
        name = fields[1]
        if name.endswith("*"):
            patterns.append((first, last, name[:-1]))
            continue
        if first != last:
            raise SystemExit(
                f"DerivedName line {line_number}: unexpected literal range"
            )
        explicit.append((first, name))
    if not explicit or not patterns:
        raise SystemExit("missing DerivedName data")
    return explicit, patterns


def parse_aliases(text: str) -> list[tuple[int, str, int]]:
    aliases: list[tuple[int, str, int]] = []
    for line_number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 3:
            raise SystemExit(f"NameAliases line {line_number}: malformed row")
        codepoint = int(fields[0], 16)
        alias = fields[1]
        kind = TYPE_INDEX.get(fields[2].lower())
        if kind is None:
            raise SystemExit(
                f"NameAliases line {line_number}: unknown type {fields[2]}"
            )
        aliases.append((codepoint, alias, kind))
    if not aliases:
        raise SystemExit("missing NameAliases data")
    return aliases


def build_records(
    explicit: list[tuple[int, str]],
    aliases: list[tuple[int, str, int]],
) -> tuple[list[tuple[int, int, int, int]], bytes]:
    pool = bytearray()
    pool_index: dict[str, tuple[int, int]] = {}

    def intern(name: str) -> tuple[int, int]:
        existing = pool_index.get(name)
        if existing is not None:
            return existing
        encoded = name.encode("utf-8")
        offset = len(pool)
        pool.extend(encoded)
        pool_index[name] = (offset, len(encoded))
        return offset, len(encoded)

    ordered: list[tuple[int, int, int, str]] = []
    order = 0
    for codepoint, name in explicit:
        ordered.append((codepoint, 0, order, name))
        order += 1
    for codepoint, alias, kind in aliases:
        ordered.append((codepoint, kind, order, alias))
        order += 1
    ordered.sort(key=lambda record: (record[0], record[1], record[2]))

    records: list[tuple[int, int, int, int]] = []
    for codepoint, kind, _, name in ordered:
        offset, length = intern(name)
        if length > 0xFFFF:
            raise SystemExit(f"name too long: {name!r}")
        records.append((codepoint, offset, length, kind))
    return records, bytes(pool)


def loose_hash(name: str) -> int:
    """32-bit FNV-1a over the UAX #44 loose-normalized name."""
    value = 2166136261
    for ch in name:
        if ch in " -_":
            continue
        code = ord(ch)
        if code >= 0x80:
            raise SystemExit(f"non-ASCII name: {name!r}")
        if 0x61 <= code <= 0x7A:
            code -= 0x20
        value = ((value ^ code) * 16777619) & 0xFFFFFFFF
    return value


def build_index(
    records: list[tuple[int, int, int, int]],
    pool: bytes,
) -> list[tuple[int, int]]:
    entries: list[tuple[int, int]] = []
    for index, (_, offset, length, _) in enumerate(records):
        name = pool[offset : offset + length].decode("ascii")
        entries.append((loose_hash(name), index))
    entries.sort()
    return entries


def render_blob(
    records: list[tuple[int, int, int, int]],
    pool: bytes,
) -> bytes:
    payload = bytearray(
        struct.pack(
            "<4sBBBBII",
            b"CJNM",
            2,
            17,
            0,
            0,
            len(records),
            len(pool),
        )
    )
    for codepoint, offset, length, kind in records:
        payload += struct.pack("<IIHBB", codepoint, offset, length, kind, 0)
    payload += pool
    index = build_index(records, pool)
    payload += struct.pack("<I", len(index))
    for value, record_index in index:
        payload += struct.pack("<II", value, record_index)
    return bytes(payload)


def render_ranges(patterns: list[tuple[int, int, str]]) -> str:
    lines = [
        "// Generated by tools/unicode/name/generate_data.py from Unicode 17.0.0.",
        f"// DerivedName.txt SHA-256: {DERIVED_NAME_SHA256}",
        f"// NameAliases.txt SHA-256: {NAME_ALIASES_SHA256}",
        "",
        "pub const Range = struct {",
        "    first: u21,",
        "    last: u21,",
        "    prefix: []const u8,",
        "};",
        "",
        "pub const patterns = [_]Range{",
    ]
    for first, last, prefix in patterns:
        lines.append(
            f'    .{{ .first = 0x{first:x}, .last = 0x{last:x}, '
            f'.prefix = "{prefix}" }},'
        )
    lines.extend(["};", ""])
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    name_text = checked_text(Path(sys.argv[1]), DERIVED_NAME_SHA256)
    alias_text = checked_text(Path(sys.argv[2]), NAME_ALIASES_SHA256)
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    explicit, patterns = parse_names(name_text)
    aliases = parse_aliases(alias_text)
    records, pool = build_records(explicit, aliases)
    (out_dir / "data.bin").write_bytes(render_blob(records, pool))
    (out_dir / "ranges.zig").write_text(
        render_ranges(patterns),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
