#!/usr/bin/env python3
"""Generate Unicode 17 scalar property and alias tables.

Usage:
    generate_data.py UnicodeData.txt PropList.txt DerivedCoreProperties.txt \
        PropertyValueAliases.txt PropertyAliases.txt emoji-data.txt \
        src/unicode/script/types.zig out_dir

The scalar payload is a deduplicated two-stage page table. Each scalar maps to
one packed u64: five General_Category bits plus one bit per binary property.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path


UNICODE_DATA_SHA256 = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
PROP_LIST_SHA256 = "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd"
DERIVED_CORE_SHA256 = "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"
PROPERTY_VALUE_ALIASES_SHA256 = "64e9a5f76f7a1e8b5a47d6a1f9a26522a251208f5276bdfa1559dac7cf2e827a"
PROPERTY_ALIASES_SHA256 = "4441f573caf952ffece1d7c892e7715bd7136dfc26f96eb6f268bf1e474715fb"
EMOJI_DATA_SHA256 = "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"

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

# The source column selects the UCD file that defines the property.
BINARY_PROPERTIES = [
    ("White_Space", "PropList"),
    ("Alphabetic", "DerivedCoreProperties"),
    ("Uppercase", "DerivedCoreProperties"),
    ("Lowercase", "DerivedCoreProperties"),
    ("Math", "DerivedCoreProperties"),
    ("Default_Ignorable_Code_Point", "DerivedCoreProperties"),
    ("ID_Start", "DerivedCoreProperties"),
    ("ID_Continue", "DerivedCoreProperties"),
    ("XID_Start", "DerivedCoreProperties"),
    ("XID_Continue", "DerivedCoreProperties"),
    ("Case_Ignorable", "DerivedCoreProperties"),
    ("Cased", "DerivedCoreProperties"),
    ("Changes_When_Casefolded", "DerivedCoreProperties"),
    ("Changes_When_Casemapped", "DerivedCoreProperties"),
    ("Changes_When_Lowercased", "DerivedCoreProperties"),
    ("Changes_When_Titlecased", "DerivedCoreProperties"),
    ("Changes_When_Uppercased", "DerivedCoreProperties"),
    ("Grapheme_Base", "DerivedCoreProperties"),
    ("Grapheme_Extend", "DerivedCoreProperties"),
    ("ASCII_Hex_Digit", "PropList"),
    ("Bidi_Control", "PropList"),
    ("Dash", "PropList"),
    ("Deprecated", "PropList"),
    ("Diacritic", "PropList"),
    ("Extender", "PropList"),
    ("Hex_Digit", "PropList"),
    ("Hyphen", "PropList"),
    ("IDS_Binary_Operator", "PropList"),
    ("IDS_Trinary_Operator", "PropList"),
    ("Ideographic", "PropList"),
    ("Join_Control", "PropList"),
    ("Logical_Order_Exception", "PropList"),
    ("Noncharacter_Code_Point", "PropList"),
    ("Other_Alphabetic", "PropList"),
    ("Other_Default_Ignorable_Code_Point", "PropList"),
    ("Other_Grapheme_Extend", "PropList"),
    ("Other_ID_Continue", "PropList"),
    ("Other_ID_Start", "PropList"),
    ("Other_Lowercase", "PropList"),
    ("Other_Math", "PropList"),
    ("Other_Uppercase", "PropList"),
    ("Pattern_Syntax", "PropList"),
    ("Pattern_White_Space", "PropList"),
    ("Prepended_Concatenation_Mark", "PropList"),
    ("Quotation_Mark", "PropList"),
    ("Radical", "PropList"),
    ("Regional_Indicator", "PropList"),
    ("Sentence_Terminal", "PropList"),
    ("Soft_Dotted", "PropList"),
    ("Terminal_Punctuation", "PropList"),
    ("Unified_Ideograph", "PropList"),
    ("Variation_Selector", "PropList"),
    ("Emoji", "Emoji"),
    ("Emoji_Component", "Emoji"),
    ("Emoji_Modifier", "Emoji"),
    ("Emoji_Modifier_Base", "Emoji"),
    ("Emoji_Presentation", "Emoji"),
    ("Extended_Pictographic", "Emoji"),
]
BINARY_PROPERTY_BITS = {
    name: 5 + index for index, (name, _) in enumerate(BINARY_PROPERTIES)
}
if max(BINARY_PROPERTY_BITS.values()) > 63:
    raise SystemExit("too many binary properties for one u64 property word")

PAGE_SIZE = 256
PAGE_COUNT = 0x1100
CATEGORY_BITS = 0x1f
DEFAULT_VALUE = CATEGORY_INDEX["Cn"]


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


def snake_name(name: str) -> str:
    return name.lower()


def function_name(name: str) -> str:
    return "is" + "".join(part.capitalize() for part in name.split("_"))


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


def parse_value_aliases(
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


def parse_property_aliases(text: str) -> dict[str, str]:
    known = {name for name, _ in BINARY_PROPERTIES}
    aliases: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 2:
            continue
        names = [field for field in fields if field]
        canonical = None
        for name in names:
            if name in known:
                canonical = name
                break
        if canonical is None:
            continue
        for name in names:
            aliases[normalize_alias(name)] = canonical
    return aliases


def category_fingerprint() -> int:
    value = 2166136261
    for name in CATEGORIES:
        for byte in name.encode("ascii"):
            value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
        value = ((value ^ 0xFF) * 16777619) & 0xFFFFFFFF
    return value


def build_property_values(
    ranges: list[tuple[int, int, str]],
    binary: dict[str, list[tuple[int, int]]],
) -> list[int]:
    values = [DEFAULT_VALUE] * 0x110000
    for first, last, category in ranges:
        bits = CATEGORY_INDEX[category]
        for codepoint in range(first, last + 1):
            values[codepoint] = (values[codepoint] & ~CATEGORY_BITS) | bits
    for name, ranges_for_property in binary.items():
        bit = BINARY_PROPERTY_BITS[name]
        mask = 1 << bit
        for first, last in ranges_for_property:
            for codepoint in range(first, last + 1):
                values[codepoint] |= mask
    return values


def build_page_table(values: list[int]) -> tuple[list[int], list[tuple[int, ...]]]:
    pages: list[tuple[int, ...]] = []
    page_index: dict[tuple[int, ...], int] = {}
    index: list[int] = []
    for page in range(PAGE_COUNT):
        chunk = tuple(values[page * PAGE_SIZE : (page + 1) * PAGE_SIZE])
        slot = page_index.get(chunk)
        if slot is None:
            slot = len(pages)
            if slot > 0xFFFF:
                raise SystemExit("property page table exceeds u16 index space")
            page_index[chunk] = slot
            pages.append(chunk)
        index.append(slot)
    return index, pages


def render_data_bin(index: list[int], pages: list[tuple[int, ...]]) -> bytes:
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHI",
            b"CJP2",
            2,
            17,
            0,
            0,
            PAGE_COUNT,
            len(pages),
            category_fingerprint(),
        )
    )
    for slot in index:
        payload += struct.pack("<H", slot)
    for page in pages:
        payload += struct.pack("<256Q", *page)
    return bytes(payload)


def render_category() -> str:
    lines = [
        "// Generated by tools/unicode/properties/generate_data.py from Unicode 17.0.0.",
        f"// UnicodeData.txt SHA-256: {UNICODE_DATA_SHA256}",
        f"// PropList.txt SHA-256: {PROP_LIST_SHA256}",
        f"// DerivedCoreProperties.txt SHA-256: {DERIVED_CORE_SHA256}",
        f"// emoji-data.txt SHA-256: {EMOJI_DATA_SHA256}",
        "",
        "// Scalar values live in data.bin; trie.zig decodes the two-stage page",
        "// table. Keeping ranges out of this file makes every property lookup O(1).",
        "",
        'const trie = @import("trie.zig");',
        "",
        "pub const Category = trie.Category;",
        "pub const all_category_mask: u32 = 0x3fff_ffff;",
        "",
        "pub const category = trie.category;",
        "pub const categoryMask = trie.categoryMask;",
        "pub const matchesMask = trie.matchesMask;",
        "",
        "/// Unicode 17 binary properties. Values are bit positions in the packed",
        "/// property word; bits 0..4 hold General_Category.",
        "pub const BinaryProperty = enum(u6) {",
    ]
    for name, _ in BINARY_PROPERTIES:
        lines.append(f"    {snake_name(name)} = {BINARY_PROPERTY_BITS[name]},")
    lines.extend(
        [
            "};",
            "",
            "pub inline fn has(codepoint: u21, property: BinaryProperty) bool {",
            "    return trie.has(codepoint, @intFromEnum(property));",
            "}",
            "",
        ]
    )
    for name, _ in BINARY_PROPERTIES:
        lines.append(
            f"pub inline fn {function_name(name)}(codepoint: u21) bool {{"
        )
        lines.append(f"    return has(codepoint, .{snake_name(name)});")
        lines.append("}")
        lines.append("")
    lines.extend(
        [
            'test "general category and binary properties" {',
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(Category.Lu, category('A'));",
            "    try testing.expectEqual(Category.Ll, category('a'));",
            "    try testing.expectEqual(Category.Nd, category('0'));",
            "    try testing.expectEqual(Category.Cn, category(0x0378));",
            "    try testing.expectEqual(Category.Cs, category(0xd800));",
            "    try testing.expectEqual(Category.Cn, category(0x110000));",
            "    try testing.expect(isWhiteSpace(' '));",
            "    try testing.expect(isAlphabetic('A'));",
            "    try testing.expect(isUppercase('A'));",
            "    try testing.expect(isLowercase('a'));",
            "    try testing.expect(isIdStart('A'));",
            "    try testing.expect(!isIdStart('0'));",
            "    try testing.expect(isIdContinue('0'));",
            "    try testing.expect(isXidStart('A'));",
            "    try testing.expect(isXidContinue('_'));",
            "    try testing.expect(isCaseIgnorable(0x00ad));",
            "    try testing.expect(isCased('A'));",
            "    try testing.expect(isGraphemeBase('A'));",
            "    try testing.expect(isGraphemeExtend(0x0301));",
            "    try testing.expect(isPatternSyntax('$'));",
            "    try testing.expect(isJoinControl(0x200d));",
            "    try testing.expect(isRegionalIndicator(0x1f1e6));",
            "    try testing.expect(isVariationSelector(0xfe0f));",
            "    try testing.expect(isUnifiedIdeograph(0x4e00));",
            "    try testing.expect(isEmoji(0x1f600));",
            "    try testing.expect(isExtendedPictographic(0x1f600));",
            "    try testing.expect(!isAlphabetic('0'));",
            "    try testing.expect(!isWhiteSpace('A'));",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def render_aliases(
    gc_aliases: dict[str, int],
    sc_aliases: dict[str, str],
    binary_aliases: dict[str, str],
) -> str:
    lines = [
        "// Generated by tools/unicode/properties/generate_data.py from Unicode 17.0.0.",
        f"// PropertyValueAliases.txt SHA-256: {PROPERTY_VALUE_ALIASES_SHA256}",
        f"// PropertyAliases.txt SHA-256: {PROPERTY_ALIASES_SHA256}",
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
            "const BinaryPropertyAlias = struct {",
            "    alias: []const u8,",
            "    property: category.BinaryProperty,",
            "};",
            "",
            "const binary_property_aliases = [_]BinaryPropertyAlias{",
        ]
    )
    for alias, property_name in sorted(binary_aliases.items()):
        lines.append(
            f'    .{{ .alias = "{alias}", '
            f".property = .{snake_name(property_name)} }},"
        )
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
            "/// Resolve a binary-property alias such as `Alpha`, `ID_Start`, or",
            "/// `Extended_Pictographic`.",
            "pub fn binaryPropertyFromAlias(",
            "    name: []const u8,",
            ") ?category.BinaryProperty {",
            "    var buffer: [64]u8 = undefined;",
            "    const normalized = normalize(name, &buffer) orelse return null;",
            "    for (binary_property_aliases) |entry| {",
            "        if (std.mem.eql(u8, entry.alias, normalized)) return entry.property;",
            "    }",
            "    return null;",
            "}",
            "",
            "test \"property aliases resolve to categories, scripts, and binaries\" {",
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(@as(?u32, 0x1f), generalCategoryMaskFromAlias(\"L\"));",
            "    try testing.expectEqual(@as(?u32, 0x1), generalCategoryMaskFromAlias(\"Lu\"));",
            "    try testing.expectEqual(@as(?u32, 0x1), generalCategoryMaskFromAlias(\"Uppercase_Letter\"));",
            "    try testing.expectEqual(@as(?u32, null), generalCategoryMaskFromAlias(\"nope\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .greek), scriptFromAlias(\"Grek\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .greek), scriptFromAlias(\"Greek\"));",
            "    try testing.expectEqual(@as(?script_types.Script, .odia), scriptFromAlias(\"Orya\"));",
            "    try testing.expectEqual(@as(?script_types.Script, null), scriptFromAlias(\"nope\"));",
            "    try testing.expectEqual(@as(?category.BinaryProperty, .alphabetic), binaryPropertyFromAlias(\"Alpha\"));",
            "    try testing.expectEqual(@as(?category.BinaryProperty, .id_start), binaryPropertyFromAlias(\"ID_Start\"));",
            "    try testing.expectEqual(@as(?category.BinaryProperty, .extended_pictographic), binaryPropertyFromAlias(\"ExtPict\"));",
            "    try testing.expectEqual(@as(?category.BinaryProperty, null), binaryPropertyFromAlias(\"nope\"));",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) != 9:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} UnicodeData.txt PropList.txt "
            "DerivedCoreProperties.txt PropertyValueAliases.txt "
            "PropertyAliases.txt emoji-data.txt "
            "src/unicode/script/types.zig out_dir"
        )
    unicode_text = checked_text(Path(sys.argv[1]), UNICODE_DATA_SHA256)
    prop_list_text = checked_text(Path(sys.argv[2]), PROP_LIST_SHA256)
    derived_core_text = checked_text(Path(sys.argv[3]), DERIVED_CORE_SHA256)
    value_aliases_text = checked_text(
        Path(sys.argv[4]), PROPERTY_VALUE_ALIASES_SHA256
    )
    property_aliases_text = checked_text(Path(sys.argv[5]), PROPERTY_ALIASES_SHA256)
    emoji_text = checked_text(Path(sys.argv[6]), EMOJI_DATA_SHA256)
    script_names = parse_script_enum(Path(sys.argv[7]))
    out_dir = Path(sys.argv[8])
    out_dir.mkdir(parents=True, exist_ok=True)

    ranges = parse_unicode_data(unicode_text)
    sources = {
        "PropList": prop_list_text,
        "DerivedCoreProperties": derived_core_text,
        "Emoji": emoji_text,
    }
    binary: dict[str, list[tuple[int, int]]] = {}
    for name, source_name in BINARY_PROPERTIES:
        property_ranges = parse_property_ranges(sources[source_name], name)
        if not property_ranges:
            raise SystemExit(f"missing Unicode 17 property {name}")
        binary[name] = property_ranges
    gc_aliases, sc_aliases = parse_value_aliases(value_aliases_text, script_names)
    binary_aliases = parse_property_aliases(property_aliases_text)
    if not gc_aliases or not sc_aliases or not binary_aliases:
        raise SystemExit("missing Unicode 17 property aliases")

    index, pages = build_page_table(build_property_values(ranges, binary))
    (out_dir / "data.bin").write_bytes(render_data_bin(index, pages))
    (out_dir / "general_category.zig").write_text(
        render_category(),
        encoding="utf-8",
    )
    (out_dir / "aliases.zig").write_text(
        render_aliases(gc_aliases, sc_aliases, binary_aliases),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
