#!/usr/bin/env python3
"""Generate Block and UAX break-property tables for UnicodeSet.

Usage:
    generate_extra.py Blocks.txt LineBreak.txt WordBreakProperty.txt \
        SentenceBreakProperty.txt GraphemeBreakProperty.txt \
        PropertyValueAliases.txt src/unicode/properties/extra_data.zig

The generated source contains complete range tables (gaps filled with each
property's default value) and normalized property-value alias maps.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

INPUT_SHA256 = {
    "Blocks.txt": "c0edefaf1a19771e830a82735472716af6bf3c3975f6c2a23ffbe2580fbbcb15",
    "LineBreak.txt": "e6a18fa91f8f6a6f8e534b1d3f128c21ada45bfe152eb6b1bcc5e15fd8ac92e6",
    "WordBreakProperty.txt": "72274cac1e6b919507db35655c3e175aa27274668a1ece95c28d2069f2ad9852",
    "SentenceBreakProperty.txt": "871c0c985ad95125e25b302414065a10839d068970bceb383ecec138f22a0a18",
    "GraphemeBreakProperty.txt": "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    "PropertyValueAliases.txt": "64e9a5f76f7a1e8b5a47d6a1f9a26522a251208f5276bdfa1559dac7cf2e827a",
}

MAX_CODEPOINT = 0x10FFFF
RANGE_RE = re.compile(r"^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*([^#]+)")
ALIAS_RE = re.compile(r"^(\w+)\s*;\s*([^;#]+?)\s*;\s*([^;#]+?)\s*(?:;\s*([^;#]+?)\s*)?$")


def checked_text(path: Path) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    expected = INPUT_SHA256[path.name]
    if actual != expected:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 {expected}, found {actual}"
        )
    return data.decode("utf-8")


def normalize(name: str) -> str:
    return "".join(ch.lower() for ch in name if ch.isalnum())


def parse_blocks(path: Path) -> list[tuple[int, int, str]]:
    blocks = []
    for line in checked_text(path).splitlines():
        match = RANGE_RE.match(line.strip())
        if match is None:
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        name = match.group(3).strip()
        blocks.append((first, last, name))
    return blocks


def parse_ranges(path: Path, default: str) -> tuple[list[tuple[int, int, str]], set[str]]:
    entries = []
    classes = {default}
    for line in checked_text(path).splitlines():
        match = RANGE_RE.match(line.strip())
        if match is None:
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        value = match.group(3).strip()
        entries.append((first, last, value))
        classes.add(value)
    entries.sort()
    filled = []
    cursor = 0
    for first, last, value in entries:
        if first > cursor:
            filled.append((cursor, first - 1, default))
        if first < cursor:
            raise SystemExit(f"{path}: overlapping ranges at U+{first:04X}")
        filled.append((first, last, value))
        cursor = last + 1
    if cursor <= MAX_CODEPOINT:
        filled.append((cursor, MAX_CODEPOINT, default))
    return filled, classes


def parse_value_aliases(path: Path) -> dict[str, dict[str, list[str]]]:
    aliases: dict[str, dict[str, list[str]]] = {}
    for line in checked_text(path).splitlines():
        stripped = line.split("#", 1)[0].strip()
        if not stripped:
            continue
        fields = [field.strip() for field in stripped.split(";")]
        if len(fields) < 3:
            continue
        prop = fields[0]
        aliases.setdefault(prop, {})[fields[1]] = fields[1:]
    return aliases


def zig_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_enum(name: str, classes: list[str]) -> list[str]:
    lines = [f"pub const {name} = enum(u8) {{"]
    for value in classes:
        lines.append(f"    {value},")
    lines.append("};")
    return lines


def emit_ranges(name: str, ranges: list[tuple[int, int, str]], index: dict[str, int]) -> list[str]:
    lines = [f"pub const {name} = [_]Range{{"]
    for first, last, value in ranges:
        lines.append(
            f"    .{{ .first = 0x{first:X}, .last = 0x{last:X}, "
            f".value = {index[value]} }},"
        )
    lines.append("};")
    return lines


def emit_aliases(name: str, aliases: dict[str, int]) -> list[str]:
    lines = [f"pub const {name} = [_]Alias{{"]
    for key in sorted(aliases):
        lines.append(f'    .{{ .key = {zig_string(key)}, .value = {aliases[key]} }},')
    lines.append("};")
    return lines


def build_break_property(
    output: list[str],
    prefix: str,
    enum_name: str,
    ranges: list[tuple[int, int, str]],
    classes: set[str],
    aliases: dict[str, list[str]],
) -> None:
    ordered = sorted(classes)
    index = {value: position for position, value in enumerate(ordered)}
    output.extend(emit_enum(enum_name, ordered))
    output.append("")
    output.extend(emit_ranges(f"{prefix}_ranges", ranges, index))
    output.append("")
    alias_map: dict[str, int] = {}
    for short, names in aliases.items():
        if short not in index:
            continue
        for name in names:
            key = normalize(name)
            if key in alias_map and alias_map[key] != index[short]:
                raise SystemExit(f"{prefix}: alias collision for {name}")
            alias_map[key] = index[short]
    for value in ordered:
        alias_map.setdefault(normalize(value), index[value])
    output.extend(emit_aliases(f"{prefix}_aliases", alias_map))
    output.append("")


def main() -> None:
    if len(sys.argv) != 8:
        raise SystemExit(
            "usage: generate_extra.py Blocks.txt LineBreak.txt "
            "WordBreakProperty.txt SentenceBreakProperty.txt "
            "GraphemeBreakProperty.txt PropertyValueAliases.txt OUT"
        )
    blocks_path = Path(sys.argv[1])
    line_break_path = Path(sys.argv[2])
    word_break_path = Path(sys.argv[3])
    sentence_break_path = Path(sys.argv[4])
    grapheme_break_path = Path(sys.argv[5])
    aliases_path = Path(sys.argv[6])
    output_path = Path(sys.argv[7])

    blocks = parse_blocks(blocks_path)
    value_aliases = parse_value_aliases(aliases_path)

    output: list[str] = []
    output.append("// Generated by tools/unicode/properties/generate_extra.py from Unicode 17.")
    output.append("// Source: Blocks.txt, LineBreak.txt, WordBreakProperty.txt,")
    output.append("// SentenceBreakProperty.txt, GraphemeBreakProperty.txt, and")
    output.append("// PropertyValueAliases.txt.")
    output.append("")
    output.append("pub const Block = struct { name: []const u8, first: u21, last: u21 };")
    output.append("pub const blocks = [_]Block{")
    block_alias_map: dict[str, int] = {}
    block_by_norm = {normalize(name): index for index, (_, _, name) in enumerate(blocks)}
    for index, (first, last, name) in enumerate(blocks):
        output.append(
            f'    .{{ .name = {zig_string(name)}, .first = 0x{first:X}, '
            f".last = 0x{last:X} }},"
        )
        block_alias_map[normalize(name)] = index
    output.append("};")
    output.append("")
    for short, names in value_aliases.get("blk", {}).items():
        canonical_name = names[1] if len(names) > 1 else names[0]
        canonical = block_by_norm.get(normalize(canonical_name))
        if canonical is None:
            continue
        for name in names:
            block_alias_map[normalize(name)] = canonical
    output.append("pub const BlockAlias = struct { key: []const u8, value: u16 };")
    output.append("pub const block_aliases = [_]BlockAlias{")
    for key in sorted(block_alias_map):
        output.append(
            f'    .{{ .key = {zig_string(key)}, .value = {block_alias_map[key]} }},'
        )
    output.append("};")
    output.append("")
    output.append("pub const Range = struct { first: u21, last: u21, value: u8 };")
    output.append("pub const Alias = struct { key: []const u8, value: u8 };")
    output.append("")

    line_ranges, line_classes = parse_ranges(line_break_path, "XX")
    build_break_property(
        output,
        "line_break",
        "LineBreak",
        line_ranges,
        line_classes,
        value_aliases.get("lb", {}),
    )
    word_ranges, word_classes = parse_ranges(word_break_path, "Other")
    build_break_property(
        output,
        "word_break",
        "WordBreak",
        word_ranges,
        word_classes,
        value_aliases.get("wb", {}),
    )
    sentence_ranges, sentence_classes = parse_ranges(sentence_break_path, "Other")
    build_break_property(
        output,
        "sentence_break",
        "SentenceBreak",
        sentence_ranges,
        sentence_classes,
        value_aliases.get("sb", {}),
    )
    grapheme_ranges, grapheme_classes = parse_ranges(grapheme_break_path, "Other")
    build_break_property(
        output,
        "grapheme_break",
        "GraphemeBreak",
        grapheme_ranges,
        grapheme_classes,
        value_aliases.get("GCB", {}),
    )

    output_path.write_text("\n".join(output) + "\n")
    print(
        f"wrote {len(blocks)} blocks, {len(line_ranges)} line-break ranges, "
        f"{len(word_ranges)} word-break ranges, {len(sentence_ranges)} "
        f"sentence-break ranges, {len(grapheme_ranges)} grapheme-break ranges"
    )


if __name__ == "__main__":
    main()
