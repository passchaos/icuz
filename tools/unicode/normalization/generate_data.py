#!/usr/bin/env python3
"""Generate Unicode 17 normalization quick-check and composition tables.

Usage:
    generate_data.py UnicodeData.txt DerivedNormalizationProps.txt data.zig

The generated composition table excludes every Full_Composition_Exclusion
entry. Hangul composition is algorithmic and is therefore intentionally absent
from this table.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
from pathlib import Path


UNICODE_DATA_SHA256 = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
DERIVED_NORMALIZATION_SHA256 = "71fd6a206a2c0cdd41feb6b7f656aa31091db45e9cedc926985d718397f9e488"
PROPERTY_RE = re.compile(
    r"^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*"
    r"([A-Za-z_]+)(?:\s*;\s*([A-Za-z_]+))?"
)
QUICK_CHECK_PROPERTIES = {
    "NFC_QC": "nfc",
    "NFD_QC": "nfd",
    "NFKC_QC": "nfkc",
    "NFKD_QC": "nfkd",
}

PAGE_SIZE = 256
PAGE_COUNT = 0x1100
QUICK_CHECK_FORMS = ("nfc", "nfd", "nfkc", "nfkd")


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 "
            f"{expected_sha256}, found {actual}"
        )
    return data.decode("utf-8")


def parse_unicode_data(text: str) -> tuple[dict[int, tuple[int, ...]], dict[int, int]]:
    decompositions: dict[int, tuple[int, ...]] = {}
    combining_classes: dict[int, int] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split(";")
        if len(fields) < 6:
            raise SystemExit(f"UnicodeData line {line_number}: malformed row")
        codepoint = int(fields[0], 16)
        combining_class = int(fields[3])
        if combining_class != 0:
            combining_classes[codepoint] = combining_class
        mapping = fields[5]
        if mapping and not mapping.startswith("<"):
            decompositions[codepoint] = tuple(int(token, 16) for token in mapping.split())
    return decompositions, combining_classes


def parse_derived(
    text: str,
) -> tuple[set[int], dict[str, list[tuple[int, int, str]]]]:
    exclusions: set[int] = set()
    quick_check: dict[str, list[tuple[int, int, str]]] = {
        form: [] for form in QUICK_CHECK_PROPERTIES.values()
    }
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = PROPERTY_RE.match(line)
        if match is None:
            continue
        first = int(match.group(1), 16)
        last = int(match.group(2) or match.group(1), 16)
        prop = match.group(3)
        value = match.group(4)
        if prop == "Full_Composition_Exclusion":
            exclusions.update(range(first, last + 1))
        elif prop in QUICK_CHECK_PROPERTIES and value in ("N", "M"):
            quick_check[QUICK_CHECK_PROPERTIES[prop]].append(
                (first, last, "no" if value == "N" else "maybe")
            )
    for ranges in quick_check.values():
        ranges.sort()
    return exclusions, quick_check


def build_quick_check_values(
    quick_check: dict[str, list[tuple[int, int, str]]],
) -> list[int]:
    values = [0] * 0x110000
    for form_index, form in enumerate(QUICK_CHECK_FORMS):
        shift = form_index * 2
        for first, last, value in quick_check[form]:
            bits = 1 if value == "no" else 2
            for codepoint in range(first, last + 1):
                values[codepoint] = (values[codepoint] & ~(3 << shift)) | (bits << shift)
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
                raise SystemExit("quick-check page table exceeds u16 index space")
            page_index[chunk] = slot
            pages.append(chunk)
        index.append(slot)
    return index, pages


def render_quick_check_blob(values: list[int]) -> bytes:
    index, pages = build_page_table(values)
    payload = bytearray(
        struct.pack(
            "<4sBBBBHH",
            b"CJQ1",
            1,
            17,
            0,
            0,
            PAGE_COUNT,
            len(pages),
        )
    )
    for slot in index:
        payload += struct.pack("<H", slot)
    for page in pages:
        payload += page
    return bytes(payload)


def render(
    decompositions: dict[int, tuple[int, ...]],
    combining_classes: dict[int, int],
    exclusions: set[int],
    quick_check: dict[str, list[tuple[int, int, str]]],
) -> str:
    compositions: list[tuple[int, int, int]] = []
    for composed, components in decompositions.items():
        if len(components) != 2 or composed in exclusions:
            continue
        starter, combining = components
        if combining_classes.get(starter, 0) != 0:
            raise SystemExit(
                f"unexpected non-starter composition U+{starter:04X} + "
                f"U+{combining:04X} -> U+{composed:04X}"
            )
        compositions.append((starter, combining, composed))
    compositions.sort()

    lines = [
        "// Generated by tools/unicode/normalization/generate_data.py from Unicode 17.0.0.",
        f"// UnicodeData.txt SHA-256: {UNICODE_DATA_SHA256}",
        f"// DerivedNormalizationProps.txt SHA-256: {DERIVED_NORMALIZATION_SHA256}",
        "",
        'const std = @import("std");',
        "",
        "pub const QuickCheck = enum(u2) { yes, no, maybe };",
        "pub const Form = enum { nfc, nfd, nfkc, nfkd };",
        "",
        'const quick_check_data = @embedFile("quick_check.bin");',
        "const header_len = 12;",
        "const index_count = readU16(8);",
        "const page_count = readU16(10);",
        "const index_offset = header_len;",
        "const pages_offset = index_offset + @as(usize, index_count) * 2;",
        "",
        "comptime {",
        "    if (quick_check_data.len < header_len or",
        '        !std.mem.eql(u8, quick_check_data[0..4], "CJQ1") or',
        "        quick_check_data[4] != 1 or quick_check_data[5] != 17 or",
        "        quick_check_data[6] != 0 or quick_check_data[7] != 0)",
        "    {",
        '        @compileError("invalid Unicode normalization quick-check data");',
        "    }",
        "    if (index_count != 0x1100 or",
        "        pages_offset + @as(usize, page_count) * 256 != quick_check_data.len)",
        "    {",
        '        @compileError("invalid Unicode normalization quick-check data lengths");',
        "    }",
        "    if (@intFromEnum(QuickCheck.no) != 1 or",
        "        @intFromEnum(QuickCheck.maybe) != 2 or",
        "        @intFromEnum(Form.nfc) != 0 or @intFromEnum(Form.nfd) != 1 or",
        "        @intFromEnum(Form.nfkc) != 2 or @intFromEnum(Form.nfkd) != 3)",
        "    {",
        '        @compileError("normalization enums no longer match the quick-check blob");',
        "    }",
        "}",
        "",
        "inline fn quickCheckValue(codepoint: u21) u8 {",
        "    if (codepoint < 0x80 or codepoint > 0x10ffff) return 0;",
        "    const page = @as(usize, codepoint) >> 8;",
        "    const slot = readU16(index_offset + page * 2);",
        "    return quick_check_data[",
        "        pages_offset + @as(usize, slot) * 256 +",
        "            (@as(usize, codepoint) & 0xff)",
        "    ];",
        "}",
        "",
        "pub inline fn quickCheck(codepoint: u21, form: Form) QuickCheck {",
        "    const shift: u3 = @as(u3, @intFromEnum(form)) * 2;",
        "    return @enumFromInt(@as(u2, @truncate(quickCheckValue(codepoint) >> shift)));",
        "}",
        "",
        "pub fn nfcQuickCheck(codepoint: u21) QuickCheck {",
        "    return quickCheck(codepoint, .nfc);",
        "}",
        "",
        "pub fn nfdQuickCheck(codepoint: u21) QuickCheck {",
        "    return quickCheck(codepoint, .nfd);",
        "}",
        "",
        "pub fn nfkcQuickCheck(codepoint: u21) QuickCheck {",
        "    return quickCheck(codepoint, .nfkc);",
        "}",
        "",
        "pub fn nfkdQuickCheck(codepoint: u21) QuickCheck {",
        "    return quickCheck(codepoint, .nfkd);",
        "}",
        "",
        "fn readU16(offset: usize) u16 {",
        '    return std.mem.readInt(u16, quick_check_data[offset..][0..2], .little);',
        "}",
        "",
    ]
    lines.extend(
        [
            "const Composition = struct {",
            "    starter: u21,",
            "    combining: u21,",
            "    composed: u21,",
            "};",
            "",
            "const compositions = [_]Composition{",
        ]
    )
    for starter, combining, composed in compositions:
        lines.append(
            f"    .{{ .starter = 0x{starter:x}, .combining = 0x{combining:x}, .composed = 0x{composed:x} }},"
        )
    lines.extend(
        [
            "};",
            "",
            "/// `composition_index[page]` is the first composition whose starter is at or",
            "/// above `page * 256`, so lookups only search one starter page.",
            "fn buildCompositionIndex(records: []const Composition) [0x1100]u16 {",
            "    @setEvalBranchQuota(1_000_000);",
            "    var index: [0x1100]u16 = @splat(0);",
            "    var record_index: usize = 0;",
            "    for (0..0x1100) |page| {",
            "        const base = page * 256;",
            "        while (record_index < records.len and",
            "            records[record_index].starter < base)",
            "        {",
            "            record_index += 1;",
            "        }",
            "        index[page] = @intCast(record_index);",
            "    }",
            "    return index;",
            "}",
            "",
            "const composition_index = buildCompositionIndex(&compositions);",
            "",
            "pub fn composePair(starter: u21, combining: u21) ?u21 {",
            "    const page = starter >> 8;",
            "    var low: usize = composition_index[page];",
            "    var high: usize = if (page + 1 < 0x1100)",
            "        composition_index[page + 1]",
            "    else",
            "        compositions.len;",
            "    while (low < high) {",
            "        const mid = low + (high - low) / 2;",
            "        const item = compositions[mid];",
            "        if (starter < item.starter or (starter == item.starter and combining < item.combining)) {",
            "            high = mid;",
            "        } else if (starter > item.starter or (starter == item.starter and combining > item.combining)) {",
            "            low = mid + 1;",
            "        } else return item.composed;",
            "    }",
            "    return null;",
            "}",
            "",
            'test "generated normalization tables expose all quick-check forms" {',
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(QuickCheck.no, nfcQuickCheck(0x0340));",
            "    try testing.expectEqual(QuickCheck.maybe, nfcQuickCheck(0x0301));",
            "    try testing.expectEqual(QuickCheck.yes, nfcQuickCheck('A'));",
            "    try testing.expectEqual(QuickCheck.no, nfdQuickCheck(0x00c5));",
            "    try testing.expectEqual(QuickCheck.yes, nfdQuickCheck('A'));",
            "    try testing.expectEqual(QuickCheck.no, nfkcQuickCheck(0x00a8));",
            "    try testing.expectEqual(QuickCheck.yes, nfkcQuickCheck('A'));",
            "    try testing.expectEqual(QuickCheck.no, nfkdQuickCheck(0x00a8));",
            "    try testing.expectEqual(@as(?u21, 0x00e9), composePair('e', 0x0301));",
            "    try testing.expectEqual(@as(?u21, null), composePair(0x0915, 0x093c));",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} UnicodeData.txt "
            "DerivedNormalizationProps.txt output.zig"
        )
    unicode_text = checked_text(Path(sys.argv[1]), UNICODE_DATA_SHA256)
    derived_text = checked_text(Path(sys.argv[2]), DERIVED_NORMALIZATION_SHA256)
    decompositions, combining_classes = parse_unicode_data(unicode_text)
    exclusions, quick_check = parse_derived(derived_text)
    if not exclusions or not any(quick_check.values()):
        raise SystemExit("missing Unicode 17 normalization properties")
    output_path = Path(sys.argv[3])
    output_path.write_text(
        render(decompositions, combining_classes, exclusions, quick_check),
        encoding="utf-8",
    )
    output_path.with_name("quick_check.bin").write_bytes(
        render_quick_check_blob(build_quick_check_values(quick_check))
    )


if __name__ == "__main__":
    main()
