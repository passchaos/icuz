#!/usr/bin/env python3
"""Generate Unicode 17 case mapping and case folding tables.

Usage:
    generate_data.py UnicodeData.txt CaseFolding.txt output.zig
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


UNICODE_DATA_SHA256 = "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
CASE_FOLDING_SHA256 = "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"


def checked_text(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(
            f"{path}: expected Unicode 17 source SHA-256 "
            f"{expected_sha256}, found {actual}"
        )
    return data.decode("utf-8")


def parse_unicode_data(text: str) -> tuple[dict[int, int], dict[int, int], dict[int, int]]:
    lower: dict[int, int] = {}
    upper: dict[int, int] = {}
    title: dict[int, int] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split(";")
        if len(fields) < 15:
            raise SystemExit(f"UnicodeData line {line_number}: malformed row")
        codepoint = int(fields[0], 16)
        if fields[12]:
            upper[codepoint] = int(fields[12], 16)
        if fields[13]:
            lower[codepoint] = int(fields[13], 16)
        if fields[14]:
            title[codepoint] = int(fields[14], 16)
    return lower, upper, title


def parse_case_folding(
    text: str,
) -> tuple[dict[int, int], dict[int, tuple[int, ...]]]:
    simple: dict[int, int] = {}
    full: dict[int, tuple[int, ...]] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(";")]
        if len(fields) < 3:
            raise SystemExit(f"malformed CaseFolding row: {raw}")
        codepoint = int(fields[0], 16)
        status = fields[1]
        mapping = tuple(int(token, 16) for token in fields[2].split())
        if status == "C":
            simple[codepoint] = mapping[0]
            full[codepoint] = mapping
        elif status == "S":
            simple[codepoint] = mapping[0]
        elif status == "F":
            full[codepoint] = mapping
        # T (Turkic) is intentionally excluded from the default mappings.
    return simple, full


def render_single(name: str, entries: dict[int, int]) -> list[str]:
    lines = [f"const {name}_records = [_]SingleRecord{{"]
    for codepoint, mapped in sorted(entries.items()):
        lines.append(f"    .{{ .codepoint = 0x{codepoint:x}, .mapped = 0x{mapped:x} }},")
    lines.extend(["};", ""])
    return lines


def render_multi(name: str, entries: dict[int, tuple[int, ...]]) -> list[str]:
    flat: list[int] = []
    records: list[tuple[int, int, int]] = []
    for codepoint, mapped in sorted(entries.items()):
        records.append((codepoint, len(flat), len(mapped)))
        flat.extend(mapped)
    if any(length > 0xFF for _, _, length in records):
        raise SystemExit(f"{name} mapping length exceeds u8")
    lines = [f"const {name}_records = [_]MultiRecord{{"]
    for codepoint, offset, length in records:
        lines.append(
            f"    .{{ .codepoint = 0x{codepoint:x}, .offset = {offset}, .len = {length} }},"
        )
    lines.extend(["};", "", f"const {name}_components = [_]u21{{"])
    for start in range(0, len(flat), 16):
        chunk = ", ".join(f"0x{value:x}" for value in flat[start : start + 16])
        lines.append(f"    {chunk},")
    lines.extend(["};", ""])
    return lines


PAGE_LIMIT = 0x200


def render_page_index(name: str, codepoints) -> list[str]:
    keys = sorted(codepoints)
    index = []
    record = 0
    for page in range(PAGE_LIMIT):
        page_start = page << 8
        while record < len(keys) and keys[record] < page_start:
            record += 1
        index.append(record)
    if any(codepoint >> 8 >= PAGE_LIMIT for codepoint in keys):
        raise SystemExit(f"{name} mapping exceeds the page index")
    lines = [f"const {name}_index = [_]u16{{"]
    for start in range(0, len(index), 16):
        chunk = ", ".join(str(value) for value in index[start : start + 16])
        lines.append(f"    {chunk},")
    lines.extend(["};", ""])
    return lines


def render_page_masks(name: str, codepoints) -> list[str]:
    pages = sorted({codepoint >> 8 for codepoint in codepoints})
    if any(page >= PAGE_LIMIT for page in pages):
        raise SystemExit(f"{name} mapping exceeds the page index")
    slots = [0xFF] * PAGE_LIMIT
    masks: list[list[int]] = []
    for slot, page in enumerate(pages):
        slots[page] = slot
        mask = [0] * 32
        for codepoint in codepoints:
            if codepoint >> 8 == page:
                low = codepoint & 0xFF
                mask[low >> 3] |= 1 << (low & 7)
        masks.append(mask)
    lines = [f"const {name}_slots = [_]u8{{"]
    for start in range(0, len(slots), 16):
        chunk = ", ".join(str(value) for value in slots[start : start + 16])
        lines.append(f"    {chunk},")
    lines.extend(["};", "", f"const {name}_masks = [_][32]u8{{"])
    for mask in masks:
        chunk = ", ".join(str(byte) for byte in mask)
        lines.append(f"    .{{{chunk}}},")
    lines.extend(["};", ""])
    return lines


DENSE_PAGE_MIN = 8


def render_dense(name: str, codepoints) -> list[str]:
    """Direct page tables for dense pages.

    A 256-entry byte table per dense page replaces the page-local binary
    search; values are record indices within the page plus one, zero meaning
    "no mapping". Sparse pages keep the mask plus binary-search path.
    """
    pages = sorted({codepoint >> 8 for codepoint in codepoints})
    slots = [0xFF] * PAGE_LIMIT
    flat: list[int] = []
    for page in pages:
        page_cps = sorted(cp for cp in codepoints if cp >> 8 == page)
        if len(page_cps) < DENSE_PAGE_MIN:
            continue
        slots[page] = len(flat) >> 8
        table = [0] * 256
        for local, codepoint in enumerate(page_cps):
            table[codepoint & 0xFF] = local + 1
        flat.extend(table)
    lines = [f"const {name}_dense_slots = [_]u8{{"]
    for start in range(0, len(slots), 16):
        chunk = ", ".join(str(value) for value in slots[start : start + 16])
        lines.append(f"    {chunk},")
    lines.extend(["};", "", f"const {name}_dense = [_]u8{{"])
    for start in range(0, len(flat), 32):
        chunk = ", ".join(str(value) for value in flat[start : start + 32])
        lines.append(f"    {chunk},")
    lines.extend(["};", ""])
    return lines


def render(
    lower: dict[int, int],
    upper: dict[int, int],
    title: dict[int, int],
    simple_fold: dict[int, int],
    full_fold: dict[int, tuple[int, ...]],
) -> str:
    lines = [
        "// Generated by tools/unicode/case/generate_data.py from Unicode 17.0.0.",
        f"// UnicodeData.txt SHA-256: {UNICODE_DATA_SHA256}",
        f"// CaseFolding.txt SHA-256: {CASE_FOLDING_SHA256}",
        "",
        "const SingleRecord = struct {",
        "    codepoint: u21,",
        "    mapped: u21,",
        "};",
        "",
        "const MultiRecord = struct {",
        "    codepoint: u21,",
        "    offset: u16,",
        "    len: u8,",
        "};",
        "",
    ]
    lines.extend(render_single("lower", lower))
    lines.extend(render_page_index("lower", lower))
    lines.extend(render_page_masks("lower", lower))
    lines.extend(render_dense("lower", lower))
    lines.extend(render_single("upper", upper))
    lines.extend(render_page_index("upper", upper))
    lines.extend(render_page_masks("upper", upper))
    lines.extend(render_dense("upper", upper))
    lines.extend(render_single("title", title))
    lines.extend(render_page_index("title", title))
    lines.extend(render_page_masks("title", title))
    lines.extend(render_dense("title", title))
    lines.extend(render_single("simple_fold", simple_fold))
    lines.extend(render_page_index("simple_fold", simple_fold))
    lines.extend(render_page_masks("simple_fold", simple_fold))
    lines.extend(render_dense("simple_fold", simple_fold))
    lines.extend(render_multi("full_fold", full_fold))
    lines.extend(render_page_index("full_fold", full_fold))
    lines.extend(render_page_masks("full_fold", full_fold))
    lines.extend(render_dense("full_fold", full_fold))
    lines.extend(
        [
            "const page_limit = 0x200;",
            "",
            "const SingleTable = struct {",
            "    records: []const SingleRecord,",
            "    index: []const u16,",
            "    slots: []const u8,",
            "    masks: []const [32]u8,",
            "    dense_slots: []const u8,",
            "    dense: []const u8,",
            "};",
            "",
            "const MultiTable = struct {",
            "    records: []const MultiRecord,",
            "    components: []const u21,",
            "    index: []const u16,",
            "    slots: []const u8,",
            "    masks: []const [32]u8,",
            "    dense_slots: []const u8,",
            "    dense: []const u8,",
            "};",
            "",
            "const lower_table = SingleTable{ .records = &lower_records, .index = &lower_index, .slots = &lower_slots, .masks = &lower_masks, .dense_slots = &lower_dense_slots, .dense = &lower_dense };",
            "const upper_table = SingleTable{ .records = &upper_records, .index = &upper_index, .slots = &upper_slots, .masks = &upper_masks, .dense_slots = &upper_dense_slots, .dense = &upper_dense };",
            "const title_table = SingleTable{ .records = &title_records, .index = &title_index, .slots = &title_slots, .masks = &title_masks, .dense_slots = &title_dense_slots, .dense = &title_dense };",
            "const simple_fold_table = SingleTable{ .records = &simple_fold_records, .index = &simple_fold_index, .slots = &simple_fold_slots, .masks = &simple_fold_masks, .dense_slots = &simple_fold_dense_slots, .dense = &simple_fold_dense };",
            "const full_fold_table = MultiTable{ .records = &full_fold_records, .components = &full_fold_components, .index = &full_fold_index, .slots = &full_fold_slots, .masks = &full_fold_masks, .dense_slots = &full_fold_dense_slots, .dense = &full_fold_dense };",
            "",
            "inline fn mappedInPage(slots: []const u8, masks: []const [32]u8, codepoint: u21) bool {",
            "    const page = codepoint >> 8;",
            "    if (page >= page_limit) return false;",
            "    const slot = slots[page];",
            "    if (slot == 0xFF) return false;",
            "    const low = codepoint & 0xFF;",
            "    return (masks[slot][low >> 3] & (@as(u8, 1) << @intCast(low & 7))) != 0;",
            "}",
            "",
            "fn lookupSingle(table: SingleTable, codepoint: u21) ?u21 {",
            "    const page = codepoint >> 8;",
            "    if (page < page_limit) {",
            "        const slot = table.dense_slots[page];",
            "        if (slot != 0xFF) {",
            "            const local = table.dense[(@as(usize, slot) << 8) | (codepoint & 0xFF)];",
            "            if (local == 0) return null;",
            "            return table.records[table.index[page] + local - 1].mapped;",
            "        }",
            "    }",
            "    if (!mappedInPage(table.slots, table.masks, codepoint)) return null;",
            "    var low: usize = table.index[page];",
            "    var high: usize = if (page + 1 < page_limit) table.index[page + 1] else table.records.len;",
            "    while (low < high) {",
            "        const mid = low + (high - low) / 2;",
            "        const record = table.records[mid];",
            "        if (codepoint < record.codepoint) high = mid else if (codepoint > record.codepoint) low = mid + 1 else return record.mapped;",
            "    }",
            "    return null;",
            "}",
            "",
            "fn lookupMulti(table: MultiTable, codepoint: u21) ?[]const u21 {",
            "    const page = codepoint >> 8;",
            "    if (page < page_limit) {",
            "        const slot = table.dense_slots[page];",
            "        if (slot != 0xFF) {",
            "            const local = table.dense[(@as(usize, slot) << 8) | (codepoint & 0xFF)];",
            "            if (local == 0) return null;",
            "            const record = table.records[table.index[page] + local - 1];",
            "            return table.components[record.offset .. record.offset + record.len];",
            "        }",
            "    }",
            "    if (!mappedInPage(table.slots, table.masks, codepoint)) return null;",
            "    var low: usize = table.index[page];",
            "    var high: usize = if (page + 1 < page_limit) table.index[page + 1] else table.records.len;",
            "    while (low < high) {",
            "        const mid = low + (high - low) / 2;",
            "        const record = table.records[mid];",
            "        if (codepoint < record.codepoint) high = mid else if (codepoint > record.codepoint) low = mid + 1 else return table.components[record.offset .. record.offset + record.len];",
            "    }",
            "    return null;",
            "}",
            "",
            "pub fn simpleLower(codepoint: u21) u21 {",
            "    return lookupSingle(lower_table, codepoint) orelse codepoint;",
            "}",
            "",
            "pub fn simpleUpper(codepoint: u21) u21 {",
            "    return lookupSingle(upper_table, codepoint) orelse codepoint;",
            "}",
            "",
            "pub fn simpleTitle(codepoint: u21) u21 {",
            "    return lookupSingle(title_table, codepoint) orelse codepoint;",
            "}",
            "",
            "/// Simple case folding for caseless matching.",
            "pub fn simpleFold(codepoint: u21) u21 {",
            "    return lookupSingle(simple_fold_table, codepoint) orelse codepoint;",
            "}",
            "",
            "/// Full case folding. Returns null when the scalar folds to itself.",
            "pub fn fullFold(codepoint: u21) ?[]const u21 {",
            "    return lookupMulti(full_fold_table, codepoint);",
            "}",
            "",
            'test "generated case mappings" {',
            '    const testing = @import("std").testing;',
            "    try testing.expectEqual(@as(u21, 'a'), simpleLower('A'));",
            "    try testing.expectEqual(@as(u21, 'A'), simpleUpper('a'));",
            "    try testing.expectEqual(@as(u21, 0x00df), simpleLower(0x1e9e));",
            "    try testing.expectEqual(@as(u21, 's'), simpleFold(0x017f));",
            "    try testing.expectEqualSlices(u21, &.{ 0x0073, 0x0073 }, fullFold(0x00df).?);",
            "    try testing.expectEqualSlices(u21, &.{ 0x0069, 0x0307 }, fullFold(0x0130).?);",
            "    try testing.expectEqualSlices(u21, &.{'a'}, fullFold('A').?);",
            "    try testing.expect(fullFold('a') == null);",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            f"usage: {Path(sys.argv[0]).name} UnicodeData.txt CaseFolding.txt output.zig"
        )
    unicode_text = checked_text(Path(sys.argv[1]), UNICODE_DATA_SHA256)
    case_text = checked_text(Path(sys.argv[2]), CASE_FOLDING_SHA256)
    lower, upper, title = parse_unicode_data(unicode_text)
    simple_fold, full_fold = parse_case_folding(case_text)
    if not lower or not upper or not simple_fold or not full_fold:
        raise SystemExit("missing Unicode 17 case mappings")
    Path(sys.argv[3]).write_text(
        render(lower, upper, title, simple_fold, full_fold),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
