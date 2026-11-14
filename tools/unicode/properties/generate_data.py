#!/usr/bin/env python3
"""Generate Unicode 17 general-category, binary-property, and alias tables.

Usage:
    generate_data.py UnicodeData.txt PropList.txt DerivedCoreProperties.txt \
        PropertyValueAliases.txt src/unicode/script/types.zig out_dir
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path


UNICODE_DATA_SHA256 = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
PROP_LIST_SHA256 = "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd"
DERIVED_CORE_SHA256 = "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"
PROPERTY_VALUE_ALIASES_SHA256 = "64e9a5f76f7a1e8b5a47d6a1f9a26522a251208f5276bdfa1559dac7cf2e827a"

CATEGORIES = [
    "Lu", "Ll", "Lt", "Lm", "Lo",
    "Mn", "Mc", "Me",
    "Nd", "Nl", "No",
    "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "Sm", "Sc", "Sk", "So",
    "Zs", "Zl", "Zp",
    "Cc", "Cf", "Cs", "Co", "Cn",
]
CATEGORY_INDEX = {name: index for index, name in enumerate(CATEGORIES)}
AGGREGATES = {
    "L": ["Lu", "Ll", "Lt", "Lm", "Lo"],
    "LC": ["Lu", "Ll", "Lt"],
    "M": ["Mn", "Mc", "Me"],
    "N": ["Nd", "Nl", "No"],
    "P": ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"],
    "S": ["Sm", "Sc", "Sk", "So"],
    "Z": ["Zs", "Zl", "Zp"],
    "C": ["Cc", "Cf", "Cs", "Co", "Cn"],
}
BINARY_PROPERTIES = [
    "White_Space",
    "Alphabetic",
    "Uppercase",
    "Lowercase",
    "Math",
    "Default_Ignorable_Code_Point",
]


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 "
            f"{expected_sha256}, found {actual}"
        )
    return data.decode("utf-8")


def normalize_alias(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def parse_unicode_data(text: str) -> list[tuple[int, int, str]]:
    ranges: list[tuple[int, int, str]] = []
    pending_first: int | None = None
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split(";")
        if len(fields) < 3:
            raise SystemExit(f"UnicodeData line {line_number}: malformed row")
        codepoint = int(fields[0], 16)
        name = fields[1]
        category = fields[2]
        if name.endswith(", First>"):
            pending_first = codepoint
        elif name.endswith(", Last>"):
            if pending_first is None:
                raise SystemExit(f"UnicodeData line {line_number}: unmatched Last")
            ranges.append((pending_first, codepoint, category))
            pending_first = None
        else:
            ranges.append((codepoint, codepoint, category))
    if pending_first is not None:
        raise SystemExit("UnicodeData: unmatched First")
    return ranges


def parse_property_ranges(text: str, property_name: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    pattern = re.compile(
        r"^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*"
        r"([A-Za-z_]+)"
    )
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = pattern.match(line)
        if match is None or match.group(3) != property_name:
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        ranges.append((first, last))
    ranges.sort()
    return ranges


def merge_ranges(ranges: list[tuple[int, int, str]]) -> list[tuple[int, int, str]]:
    merged: list[tuple[int, int, str]] = []
    for first, last, value in sorted(ranges):
        if merged and merged[-1][1] + 1 == first and merged[-1][2] == value:
            merged[-1] = (merged[-1][0], last, value)
        else:
            merged.append((first, last, value))
    return merged


def merge_simple_ranges(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for first, last in sorted(ranges):
        if merged and merged[-1][1] + 1 == first:
            merged[-1] = (merged[-1][0], last)
        else:
            merged.append((first, last))
    return merged


def parse_script_enum(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    body = text.split("pub const Script = enum {", 1)[1].split("};", 1)[0]
    result: dict[str, str] = {}
    for line in body.splitlines():
        name = line.strip().rstrip(",")
        if not name or name.startswith("//"):
            continue
        result[normalize_alias(name)] = name
    return result


def category_mask(names: list[str]) -> int:
    mask = 0
    for name in names:
        mask |= 1 << CATEGORY_INDEX[name]
    return mask


def parse_aliases(
    text: str,
    script_names: dict[str, str],
) -> tuple[dict[str, int], dict[str, str]]:
    gc_aliases: dict[str, int] = {}
    sc_aliases: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 3:
            continue
        prop = fields[0]
        aliases = [field for field in fields[1:] if field]
        if prop == "gc":
            short = aliases[0]
            if short in AGGREGATES:
                names = AGGREGATES[short]
            elif short in CATEGORY_INDEX:
                names = [short]
            else:
                continue
            mask = category_mask(names)
            for alias in aliases:
                gc_aliases[normalize_alias(alias)] = mask
        elif prop == "sc":
            short = aliases[0]
            long = aliases[1] if len(aliases) > 1 else short
            enum_name = script_names.get(normalize_alias(long))
            if enum_name is None and short == "Orya":
                enum_name = "odia"
            if enum_name is None:
                continue
            for alias in aliases:
                sc_aliases[normalize_alias(alias)] = enum_name
    return gc_aliases, sc_aliases


def render_category(
    ranges: list[tuple[int, int, str]],
    binary: dict[str, list[tuple[int, int]]],
) -> str:
    lines = [
        "// Generated by tools/unicode/properties/generate_data.py from Unicode 17.0.0.",
        f"// UnicodeData.txt SHA-256: {UNICODE_DATA_SHA256}",
        f"// PropList.txt SHA-256: {PROP_LIST_SHA256}",
        f"// DerivedCoreProperties.txt SHA-256: {DERIVED_CORE_SHA256}",
        "",
        "pub const Category = enum(u5) {",
    ]
    for name in CATEGORIES:
        lines.append(f"    {name},")
    lines.extend(
        [
            "};",
            "",
            "pub const all_category_mask: u32 = 0x3fff_ffff;",
            "",
            "const Range = struct {",
            "    first: u21,",
            "    last: u21,",
            "    category: Category,",
            "};",
            "",
            "const category_ranges = [_]Range{",
        ]
    )
    for first, last, category in merge_ranges(ranges):
        lines.append(
            f"    .{{ .first = 0x{first:x}, .last = 0x{last:x}, .category = .{category} }},"
        )
    lines.extend(
        [
            "};",
            "",
            "pub fn category(codepoint: u21) Category {",
            "    var low: usize = 0;",
            "    var high: usize = category_ranges.len;",
            "    while (low < high) {",
            "        const mid = low + (high - low) / 2;",
            "        const range = category_ranges[mid];",
            "        if (codepoint < range.first) high = mid else if (codepoint > range.last) low = mid + 1 else return range.category;",
            "    }",
            "    return .Cn;",
            "}",
            "",
            "pub fn categoryMask(value: Category) u32 {",
            "    return @as(u32, 1) << @intFromEnum(value);",
            "}",
            "",
            "pub fn matchesMask(codepoint: u21, mask: u32) bool {",
            "    return (categoryMask(category(codepoint)) & mask) != 0;",
            "}",
            "",
        ]
    )
    for name, ranges_for_property in binary.items():
        fn_name = "is" + "".join(part.capitalize() for part in name.split("_"))
        lines.extend(
            [
                f"const {normalize_alias(name)}_ranges = [_]Range2{{",
            ]
        )
        for first, last in merge_simple_ranges(ranges_for_property):
            lines.append(f"    .{{ .first = 0x{first:x}, .last = 0x{last:x} }},")
        lines.extend(
            [
                "};",
                "",
                f"pub fn {fn_name}(codepoint: u21) bool {{",
                f"    var low: usize = 0;",
                f"    var high: usize = {normalize_alias(name)}_ranges.len;",
                "    while (low < high) {",
                "        const mid = low + (high - low) / 2;",
                f"        const range = {normalize_alias(name)}_ranges[mid];",
                "        if (codepoint < range.first) high = mid else if (codepoint > range.last) low = mid + 1 else return true;",
                "    }",
                "    return false;",
                "}",
                "",
            ]
        )
    lines.extend(
        [
            "test \"general category and binary properties\" {",
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(Category.Lu, category('A'));",
            "    try testing.expectEqual(Category.Ll, category('a'));",
            "    try testing.expectEqual(Category.Nd, category('0'));",
            "    try testing.expectEqual(Category.Cn, category(0x0378));",
            "    try testing.expect(isWhiteSpace(' '));",
            "    try testing.expect(isAlphabetic('A'));",
            "    try testing.expect(isUppercase('A'));",
            "    try testing.expect(isLowercase('a'));",
            "}",
            "",
            "const Range2 = struct {",
            "    first: u21,",
            "    last: u21,",
            "};",
            "",
        ]
    )
    return "\n".join(lines)


def render_aliases(
    gc_aliases: dict[str, int],
    sc_aliases: dict[str, str],
) -> str:
    lines = [
        "// Generated by tools/unicode/properties/generate_data.py from Unicode 17.0.0.",
        f"// PropertyValueAliases.txt SHA-256: {PROPERTY_VALUE_ALIASES_SHA256}",
        "",
        'const std = @import("std");',
        'const category = @import("general_category.zig");',
        'const script_types = @import("../script/types.zig");',
        "",
        "const CategoryAlias = struct {",
        "    alias: []const u8,",
        "    mask: u32,",
        "};",
        "",
        "const category_aliases = [_]CategoryAlias{",
    ]
    for alias, mask in sorted(gc_aliases.items()):
        lines.append(f'    .{{ .alias = "{alias}", .mask = 0x{mask:x} }},')
    lines.extend(
        [
            "};",
            "",
            "const ScriptAlias = struct {",
            "    alias: []const u8,",
            "    script: script_types.Script,",
            "};",
            "",
            "const script_aliases = [_]ScriptAlias{",
        ]
    )
    for alias, enum_name in sorted(sc_aliases.items()):
        lines.append(f'    .{{ .alias = "{alias}", .script = .{enum_name} }},')
    lines.extend(
        [
            "};",
            "",
            "fn normalize(name: []const u8, buffer: *[64]u8) ?[]const u8 {",
            "    if (name.len > buffer.len) return null;",
            "    var len: usize = 0;",
            "    for (name) |byte| {",
            "        if (byte == '_' or byte == '-' or byte == ' ') continue;",
            "        if (byte >= 'A' and byte <= 'Z') {",
            "            buffer[len] = byte + ('a' - 'A');",
            "        } else if ((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9')) {",
            "            buffer[len] = byte;",
            "        } else {",
            "            return null;",
            "        }",
            "        len += 1;",
            "    }",
            "    return buffer[0..len];",
            "}",
            "",
            "/// Resolve a General_Category alias such as `L`, `Letter`, `Lu`, or",
            "/// `Uppercase_Letter` to a category bitmask.",
            "pub fn generalCategoryMaskFromAlias(name: []const u8) ?u32 {",
            "    var buffer: [64]u8 = undefined;",
            "    const normalized = normalize(name, &buffer) orelse return null;",
            "    for (category_aliases) |entry| {",
            "        if (std.mem.eql(u8, entry.alias, normalized)) return entry.mask;",
            "    }",
            "    return null;",
            "}",
            "",
            "/// Resolve a Script alias such as `Grek` or `Greek`.",
            "pub fn scriptFromAlias(name: []const u8) ?script_types.Script {",
            "    var buffer: [64]u8 = undefined;",
            "    const normalized = normalize(name, &buffer) orelse return null;",
            "    for (script_aliases) |entry| {",
            "        if (std.mem.eql(u8, entry.alias, normalized)) return entry.script;",
            "    }",
            "    return null;",
            "}",
            "",
            "test \"property aliases resolve to categories and scripts\" {",
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(@as(?u32, 0x1f), generalCategoryMaskFromAlias(\"L\"));",
            "    try testing.expectEqual(@as(?u32, 0x1), generalCategoryMaskFromAlias(\"Lu\"));",
            "    try testing.expectEqual(@as(?u32, 0x1), generalCategoryMaskFromAlias(\"Uppercase_Letter\"));",
            "    try testing.expectEqual(@as(?u32, null), generalCategoryMaskFromAlias(\"nope\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .greek), scriptFromAlias(\"Grek\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .greek), scriptFromAlias(\"Greek\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .odia), scriptFromAlias(\"Orya\"));",
            "    try testing.expectEqual(@as(?script_types.Script, null), scriptFromAlias(\"nope\"));",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) != 7:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} UnicodeData.txt PropList.txt "
            "DerivedCoreProperties.txt PropertyValueAliases.txt "
            "src/unicode/script/types.zig out_dir"
        )
    unicode_text = checked_text(Path(sys.argv[1]), UNICODE_DATA_SHA256)
    prop_list_text = checked_text(Path(sys.argv[2]), PROP_LIST_SHA256)
    derived_core_text = checked_text(Path(sys.argv[3]), DERIVED_CORE_SHA256)
    aliases_text = checked_text(Path(sys.argv[4]), PROPERTY_VALUE_ALIASES_SHA256)
    script_names = parse_script_enum(Path(sys.argv[5]))
    out_dir = Path(sys.argv[6])
    out_dir.mkdir(parents=True, exist_ok=True)

    ranges = parse_unicode_data(unicode_text)
    binary: dict[str, list[tuple[int, int]]] = {}
    for name in BINARY_PROPERTIES:
        source = prop_list_text if name == "White_Space" else derived_core_text
        binary[name] = parse_property_ranges(source, name)
    gc_aliases, sc_aliases = parse_aliases(aliases_text, script_names)
    if not gc_aliases or not sc_aliases:
        raise SystemExit("missing Unicode 17 property aliases")

    (out_dir / "general_category.zig").write_text(
        render_category(ranges, binary),
        encoding="utf-8",
    )
    (out_dir / "aliases.zig").write_text(
        render_aliases(gc_aliases, sc_aliases),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
