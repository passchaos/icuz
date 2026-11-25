//! UTS #46 IDNA 16.0.0 processing.
//!
//! Implements ToASCII, ToUnicode, mapping, NFC, punycode, hyphen checks,
//! RFC 5893 bidi rules, ContextJ joiners, and the common ContextO rules.

const std = @import("std");
const normalization = @import("normalization/root.zig");
const bidi = @import("bidi/paragraph.zig");
const joining = @import("joining.zig");
const combining_class = @import("canonical/combining_class.zig");
const script = @import("script/root.zig");
const properties = @import("properties.zig");
const scalar = @import("scalar/root.zig");

pub const idna_version = [3]u8{ 16, 0, 0 };

pub const Options = struct {
    transitional: bool = false,
    use_std3_ascii_rules: bool = false,
    check_hyphens: bool = false,
    check_bidi: bool = true,
    check_joiners: bool = true,
};

pub const Error = error{
    InvalidLabel,
    LabelTooLong,
    DomainTooLong,
    InvalidUtf8,
    OutOfMemory,
};

const Status = enum(u8) {
    valid = 0,
    ignored = 1,
    mapped = 2,
    deviation = 3,
    disallowed = 4,
};

const data = @embedFile("idna/data.bin");
const header_len = 20;
const index_count = readU16(8);
const page_count = readU16(10);
const mapping_count = readU32(12);
const pool_count = readU32(16);
const index_offset = header_len;
const pages_offset = index_offset + @as(usize, index_count) * 2;
const mappings_offset = pages_offset + @as(usize, page_count) * 256;
const pool_offset = mappings_offset + @as(usize, mapping_count) * 10;

comptime {
    if (data.len < header_len or !std.mem.eql(u8, data[0..4], "CJID") or
        data[4] != 1 or data[5] != 16 or data[6] != 0 or data[7] != 0)
    {
        @compileError("invalid UTS #46 IDNA data");
    }
    if (index_count != 0x1100 or
        pool_offset + @as(usize, pool_count) * 4 != data.len)
    {
        @compileError("invalid UTS #46 IDNA data lengths");
    }
}

fn statusForPage(codepoint: u21) Status {
    if (codepoint > 0x10ffff) return .disallowed;
    const page = @as(usize, codepoint) >> 8;
    const slot = readU16(index_offset + page * 2);
    return @enumFromInt(data[
        pages_offset + @as(usize, slot) * 256 +
            (@as(usize, codepoint) & 0xff)
    ]);
}

/// ASCII statuses are one load instead of two dependent ones; mixed labels
/// are mostly ASCII.
const ascii_status = blk: {
    @setEvalBranchQuota(200_000);
    var table: [128]Status = undefined;
    for (0..128) |codepoint| {
        table[codepoint] = statusForPage(@intCast(codepoint));
    }
    break :blk table;
};

inline fn statusFor(codepoint: u21) Status {
    if (codepoint < 0x80) return ascii_status[codepoint];
    return statusForPage(codepoint);
}

fn mappingFor(codepoint: u21) ?[]const u8 {
    var low: usize = 0;
    var high: usize = mapping_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record_offset = mappings_offset + mid * 10;
        const record_codepoint = readU32(record_offset);
        if (record_codepoint < codepoint) {
            low = mid + 1;
        } else if (record_codepoint > codepoint) {
            high = mid;
        } else {
            const offset = readU32(record_offset + 4);
            const length = data[record_offset + 8];
            return data[pool_offset + @as(usize, offset) * 4 ..][0 .. @as(usize, length) * 4];
        }
    }
    return null;
}

fn appendMapping(
    allocator: std.mem.Allocator,
    mapped: *std.ArrayList(u21),
    mapping: []const u8,
) Error!void {
    var offset: usize = 0;
    while (offset < mapping.len) : (offset += 4) {
        try mapped.append(
            allocator,
            @intCast(std.mem.readInt(u32, mapping[offset..][0..4], .little)),
        );
    }
}

pub const Result = struct {
    text: []u8,
    had_error: bool,
};

/// Convert a domain to its ASCII A-label form, reporting UTS #46 errors.
pub fn toAsciiResultAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
) Error!Result {
    return convertAlloc(allocator, domain, options, true);
}

/// Convert a domain to its Unicode U-label form, reporting UTS #46 errors.
pub fn toUnicodeResultAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
) Error!Result {
    return convertAlloc(allocator, domain, options, false);
}

/// Convert a domain to its ASCII A-label form, failing on any UTS #46 error.
pub fn toAsciiAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
) Error![]u8 {
    const result = try toAsciiResultAlloc(allocator, domain, options);
    if (result.had_error) {
        allocator.free(result.text);
        return error.InvalidLabel;
    }
    return result.text;
}

/// Convert a domain to its Unicode U-label form, failing on any UTS #46 error.
pub fn toUnicodeAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
) Error![]u8 {
    const result = try toUnicodeResultAlloc(allocator, domain, options);
    if (result.had_error) {
        allocator.free(result.text);
        return error.InvalidLabel;
    }
    return result.text;
}

/// Validate a domain without returning the converted form.
pub fn validate(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
) Error!void {
    const result = try toAsciiResultAlloc(allocator, domain, options);
    defer allocator.free(result.text);
    if (result.had_error) return error.InvalidLabel;
}

const Label = struct {
    unicode: []const u21,
    ascii: ?[]const u21,
    owned: ?[]u21,
};

fn convertAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
    ascii_output: bool,
) Error!Result {
    // Domains are short, so run the general path against a stack arena and
    // hand back one exact allocation. Longer inputs retry on the heap.
    var stack: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    if (convertInner(fixed.allocator(), domain, options, ascii_output)) |result| {
        return .{
            .text = try allocator.dupe(u8, result.text),
            .had_error = result.had_error,
        };
    } else |err| switch (err) {
        error.OutOfMemory => {},
        else => return err,
    }
    return convertInner(allocator, domain, options, ascii_output);
}

fn convertInner(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
    ascii_output: bool,
) Error!Result {
    // ASCII domains dominate real traffic and need no decoding, NFC, or
    // punycode. A-label labels still take the general path so their punycode
    // is decoded and revalidated.
    const ascii_domain = isAsciiDomain(domain);
    if (ascii_domain and !hasAlabel(domain)) {
        return convertAsciiAlloc(allocator, domain, options, ascii_output);
    }
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, domain.len);
    // The packed decoder validates each sequence, so one pass replaces the
    // separate UTF-8 validation scan.
    var cursor: usize = 0;
    while (cursor < domain.len) {
        const first = domain[cursor];
        // Greek and Cyrillic labels are entirely two-byte sequences. Those
        // leads can never be overlong or a surrogate, so a run decodes
        // without the general length ladder.
        if (first >= 0xc2 and first <= 0xdf and cursor + 2 <= domain.len) {
            while (cursor + 2 <= domain.len) {
                const lead = domain[cursor];
                if (lead < 0xc2 or lead > 0xdf) break;
                const second = domain[cursor + 1];
                if (second & 0xc0 != 0x80) return error.InvalidUtf8;
                codepoints.appendAssumeCapacity(
                    (@as(u21, lead & 0x1f) << 6) | (second & 0x3f),
                );
                cursor += 2;
            }
            continue;
        }
        // Three-byte runs cover the CJK and Indic labels; the overlong and
        // surrogate checks are the same ones the general decoder applies.
        if (first >= 0xe0 and first < 0xf0 and cursor + 3 <= domain.len) {
            while (cursor + 3 <= domain.len) {
                const lead = domain[cursor];
                if (lead < 0xe0 or lead >= 0xf0) break;
                const second = domain[cursor + 1];
                const third = domain[cursor + 2];
                if (((second | third) & 0xc0) != 0x80) {
                    return error.InvalidUtf8;
                }
                const codepoint = (@as(u21, lead & 0x0f) << 12) |
                    (@as(u21, second & 0x3f) << 6) |
                    (third & 0x3f);
                if (codepoint < 0x800 or
                    (codepoint & 0xf800) == 0xd800)
                {
                    return error.InvalidUtf8;
                }
                codepoints.appendAssumeCapacity(codepoint);
                cursor += 3;
            }
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(domain, cursor);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        codepoints.appendAssumeCapacity(scalar.packedCodepoint(decoded));
        cursor += scalar.packedLength(decoded);
    }

    var mapped = std.ArrayList(u21).empty;
    defer mapped.deinit(allocator);
    // True when every scalar keeps its value, so a later no-op check can
    // trust that the mapped array matches the decoded input. ASCII domains
    // never take that path, so they skip the tracking.
    const track_clean = !ascii_domain;
    var status_clean = true;
    // Copy on first change: a domain whose scalars all keep their value needs
    // no mapped buffer at all, which is the common case.
    var copied = false;
    for (codepoints.items, 0..) |codepoint, index| {
        const status = statusFor(codepoint);
        if (status == .valid) {
            if (copied) try mapped.append(allocator, codepoint);
            continue;
        }
        // A deviation scalar keeps its value unless transitional processing
        // maps it.
        const keeps_value = status == .deviation and !options.transitional;
        if (!keeps_value and track_clean) status_clean = false;
        if (!copied) {
            copied = true;
            try mapped.ensureTotalCapacity(allocator, codepoints.items.len);
            try mapped.appendSlice(allocator, codepoints.items[0..index]);
        }
        switch (status) {
            .valid => unreachable,
            .disallowed => try mapped.append(allocator, codepoint),
            .ignored => {},
            .mapped => {
                if (codepoint < 0x80) {
                    // Only A-Z map inside ASCII.
                    try mapped.append(allocator, codepoint + ('a' - 'A'));
                    continue;
                }
                if (options.transitional and codepoint == 0x1e9e) {
                    try mapped.append(allocator, 's');
                    try mapped.append(allocator, 's');
                    continue;
                }
                const mapping = mappingFor(codepoint) orelse {
                    try mapped.append(allocator, codepoint);
                    continue;
                };
                try appendMapping(allocator, &mapped, mapping);
            },
            .deviation => {
                if (options.transitional) {
                    const mapping = mappingFor(codepoint) orelse continue;
                    try appendMapping(allocator, &mapped, mapping);
                } else {
                    try mapped.append(allocator, codepoint);
                }
            },
        }
    }

    const mapped_items = if (copied) mapped.items else codepoints.items;
    const normalized = try normalization.normalizeCodepointsAlloc(
        allocator,
        mapped_items,
        .nfc,
    );
    defer if (normalized) |owned| allocator.free(owned);
    const source = normalized orelse mapped_items;

    var labels = std.ArrayList(Label).empty;
    defer {
        for (labels.items) |label| {
            if (label.owned) |owned| allocator.free(owned);
        }
        labels.deinit(allocator);
    }

    var had_error = false;
    var trailing_dot = false;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        const at_end = index == source.len;
        if (!at_end and source[index] != '.') continue;

        const raw = source[start..index];
        if (raw.len == 0) {
            if (at_end) {
                if (labels.items.len > 0) trailing_dot = true;
                break;
            }
            had_error = true;
            try labels.append(allocator, .{
                .unicode = &.{},
                .ascii = null,
                .owned = null,
            });
            start = index + 1;
            continue;
        }

        if (isAlabel(raw)) {
            const decoded = decodePunycode(allocator, raw[4..]) catch {
                had_error = true;
                try labels.append(allocator, .{
                    .unicode = raw,
                    .ascii = raw,
                    .owned = null,
                });
                start = index + 1;
                continue;
            };
            var all_ascii = true;
            for (decoded) |codepoint| {
                if (codepoint >= 0x80) {
                    all_ascii = false;
                    break;
                }
            }
            if (decoded.len == 0 or all_ascii) had_error = true;
            try labels.append(allocator, .{
                .unicode = decoded,
                .ascii = raw,
                .owned = decoded,
            });
        } else {
            try labels.append(allocator, .{
                .unicode = raw,
                .ascii = null,
                .owned = null,
            });
        }
        start = index + 1;
    }

    if (labels.items.len == 0) had_error = true;

    const domain_has_rtl = blk: {
        for (labels.items) |label| {
            for (label.unicode) |codepoint| {
                switch (bidi.classForCodepoint(codepoint)) {
                    .r, .al, .an => break :blk true,
                    else => {},
                }
            }
        }
        break :blk false;
    };

    // A non-ASCII domain without A-labels whose scalars are already NFC and
    // need no mapping converts to itself: the output is the input bytes, so
    // only the label validation remains.
    if (!ascii_output and status_clean and normalized == null) {
        var any_decoded = false;
        for (labels.items) |label| {
            if (label.owned != null) {
                any_decoded = true;
                break;
            }
        }
        if (!any_decoded) {
            for (labels.items) |label| {
                if (label.unicode.len > 0 and
                    !validateLabel(
                        label.unicode,
                        options,
                        domain_has_rtl,
                        false,
                        true,
                    ))
                {
                    had_error = true;
                }
            }
            return .{
                .text = try allocator.dupe(u8, domain),
                .had_error = had_error,
            };
        }
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (labels.items, 0..) |label, label_index| {
        if (label_index > 0) try output.append(allocator, '.');
        if (label.unicode.len > 0 and
            !validateLabel(
                label.unicode,
                options,
                domain_has_rtl,
                label.owned != null,
                false,
            ))
        {
            had_error = true;
        }
        if (ascii_output) {
            if (label.ascii) |ascii_label| {
                if (ascii_label.len > 63) had_error = true;
                appendAsciiLabel(allocator, &output, ascii_label) catch {
                    had_error = true;
                    try appendUtf8(allocator, &output, label.unicode);
                };
            } else {
                appendEncodedAsciiLabel(
                    allocator,
                    &output,
                    label.unicode,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        had_error = true;
                        try appendUtf8(allocator, &output, label.unicode);
                        continue;
                    },
                };
            }
        } else {
            try appendUtf8(allocator, &output, label.unicode);
        }
    }
    if (trailing_dot) {
        if (ascii_output) had_error = true;
        try output.append(allocator, '.');
    }
    if (ascii_output and output.items.len > 253) had_error = true;
    return .{
        .text = try output.toOwnedSlice(allocator),
        .had_error = had_error,
    };
}

inline fn asciiLowerByte(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isAsciiDomain(text: []const u8) bool {
    const high_bits: u64 = 0x8080_8080_8080_8080;
    var index: usize = 0;
    while (index + 8 <= text.len) : (index += 8) {
        const quad = std.mem.readInt(u64, text[index..][0..8], .little);
        if (quad & high_bits != 0) return false;
    }
    while (index < text.len) : (index += 1) {
        if (text[index] >= 0x80) return false;
    }
    return true;
}

/// True when any label carries the ACE prefix; those need punycode handling.
fn hasAlabel(domain: []const u8) bool {
    var start: usize = 0;
    var index: usize = 0;
    while (index <= domain.len) : (index += 1) {
        if (index != domain.len and domain[index] != '.') continue;
        const raw = domain[start..index];
        if (raw.len >= 4 and asciiLowerByte(raw[0]) == 'x' and
            asciiLowerByte(raw[1]) == 'n' and raw[2] == '-' and raw[3] == '-')
        {
            return true;
        }
        start = index + 1;
    }
    return false;
}

/// UTS #46 for an all-ASCII domain without A-labels.
///
/// Every ASCII scalar other than A-Z is `valid` in the mapping table, so the
/// conversion reduces to lowercasing, the per-label checks that can apply to
/// ASCII, and joining with dots. ToUnicode and ToASCII produce the same text
/// here because no label needs punycode.
fn convertAsciiAlloc(
    allocator: std.mem.Allocator,
    domain: []const u8,
    options: Options,
    ascii_output: bool,
) Error!Result {
    var had_error = false;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    // The output is the lowercased input, so its length is exactly
    // `domain.len`; an exact reservation keeps toOwnedSlice from copying.
    try output.ensureTotalCapacityPrecise(allocator, domain.len);

    var label_count: usize = 0;
    var trailing_dot = false;
    var first_label = true;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= domain.len) : (index += 1) {
        const at_end = index == domain.len;
        if (!at_end and domain[index] != '.') continue;
        const raw = domain[start..index];
        if (raw.len == 0 and at_end) {
            if (label_count > 0) trailing_dot = true;
            break;
        }
        if (!first_label) output.appendAssumeCapacity('.');
        first_label = false;
        if (raw.len == 0) {
            had_error = true;
            label_count += 1;
            start = index + 1;
            continue;
        }
        if (options.check_hyphens) {
            if (raw[0] == '-' or raw[raw.len - 1] == '-') had_error = true;
            if (raw.len >= 4 and raw[2] == '-' and raw[3] == '-' and
                !(asciiLowerByte(raw[0]) == 'x' and
                    asciiLowerByte(raw[1]) == 'n'))
            {
                had_error = true;
            }
        }
        if (ascii_output and raw.len > 63) had_error = true;
        for (raw) |byte| {
            output.appendAssumeCapacity(asciiLowerByte(byte));
        }
        label_count += 1;
        start = index + 1;
    }
    if (label_count == 0) had_error = true;
    if (trailing_dot) {
        if (ascii_output) had_error = true;
        output.appendAssumeCapacity('.');
    }
    if (ascii_output and output.items.len > 253) had_error = true;
    return .{
        .text = try output.toOwnedSlice(allocator),
        .had_error = had_error,
    };
}

fn appendAsciiLabel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u21,
) Error!void {
    for (label) |codepoint| {
        if (codepoint >= 0x80) return error.InvalidLabel;
        try output.append(allocator, @intCast(codepoint));
    }
}

fn validateLabel(
    label: []const u21,
    options: Options,
    domain_has_rtl: bool,
    check_nfc: bool,
    status_known_ok: bool,
) bool {
    if (label.len == 0) return false;
    // Labels cut from the mapped domain are already NFC: either the domain
    // passed the quick check or it was normalized. Only decoded A-labels can
    // still decompose.
    if (check_nfc and !normalization.isNormalizedCodepoints(label, .nfc)) {
        return false;
    }
    // A label cut from the mapped domain cannot contain '.', and a clean
    // mapping pass already proved every scalar's status.
    if (!status_known_ok) {
        for (label) |codepoint| {
            if (codepoint == '.') return false;
            switch (statusFor(codepoint)) {
                .valid, .deviation => {},
                else => return false,
            }
        }
    }
    if (options.check_hyphens) {
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        if (label.len >= 4 and label[2] == '-' and label[3] == '-') {
            if (!(asciiLower(label[0]) == 'x' and asciiLower(label[1]) == 'n')) {
                return false;
            }
        }
    } else if (label.len >= 4 and
        asciiLower(label[0]) == 'x' and asciiLower(label[1]) == 'n' and
        label[2] == '-' and label[3] == '-')
    {
        return false;
    }
    if (properties.matchesCategoryMask(label[0], 0xe0)) return false;
    if (options.check_bidi and domain_has_rtl and !checkBidi(label)) {
        return false;
    }
    if (options.check_joiners and !checkJoiners(label)) return false;
    return checkContextO(label);
}

fn isAlabel(label: []const u21) bool {
    if (label.len < 4) return false;
    return asciiLower(label[0]) == 'x' and
        asciiLower(label[1]) == 'n' and
        label[2] == '-' and label[3] == '-';
}

fn asciiLower(codepoint: u21) u21 {
    if (codepoint >= 'A' and codepoint <= 'Z') {
        return codepoint + ('a' - 'A');
    }
    return codepoint;
}

fn asciiLabelAlloc(
    allocator: std.mem.Allocator,
    label: []const u21,
) Error![]u8 {
    const output = try allocator.alloc(u8, label.len);
    errdefer allocator.free(output);
    for (label, 0..) |codepoint, index| {
        if (codepoint >= 0x80) return error.InvalidLabel;
        output[index] = @intCast(codepoint);
    }
    return output;
}

/// Append one A-label directly to the result. On an over-long label the
/// appended bytes are rolled back so the caller can fall back to the
/// Unicode form.
fn appendEncodedAsciiLabel(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u21,
) Error!void {
    const start = output.items.len;
    var all_ascii = true;
    for (label) |codepoint| {
        if (codepoint >= 0x80) {
            all_ascii = false;
            break;
        }
    }
    if (all_ascii) {
        try output.ensureUnusedCapacity(allocator, label.len);
        for (label) |codepoint| {
            output.appendAssumeCapacity(@intCast(codepoint));
        }
    } else {
        try output.appendSlice(allocator, "xn--");
        try appendPunycode(allocator, output, label);
    }
    if (output.items.len - start > 63) {
        output.items.len = start;
        return error.LabelTooLong;
    }
}

fn appendUtf8(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoints: []const u21,
) Error!void {
    var encoded: [4]u8 = undefined;
    for (codepoints) |codepoint| {
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch
            return error.InvalidLabel;
        try output.appendSlice(allocator, encoded[0..length]);
    }
}

fn checkBidi(codepoints: []const u21) bool {
    var has_rtl = false;
    for (codepoints) |codepoint| {
        switch (bidi.classForCodepoint(codepoint)) {
            .r, .al, .an => has_rtl = true,
            else => {},
        }
    }

    if (!has_rtl) {
        const first = bidi.classForCodepoint(codepoints[0]);
        if (first != .l) return false;
        const last = lastNonNsmClass(codepoints) orelse return false;
        if (!(last == .l or last == .en)) return false;
        for (codepoints) |codepoint| {
            const class = bidi.classForCodepoint(codepoint);
            if (!(class == .l or class == .en or class == .es or
                class == .cs or class == .et or class == .on or
                class == .bn or class == .nsm)) return false;
        }
        return true;
    }

    const first = bidi.classForCodepoint(codepoints[0]);
    if (!(first == .r or first == .al)) return false;
    const last = lastNonNsmClass(codepoints) orelse return false;
    if (!(last == .r or last == .al or last == .en or last == .an)) return false;

    var has_en = false;
    var has_an = false;
    for (codepoints) |codepoint| {
        const class = bidi.classForCodepoint(codepoint);
        if (class == .en) has_en = true;
        if (class == .an) has_an = true;
        if (!(class == .r or class == .al or class == .an or
            class == .en or class == .es or class == .cs or
            class == .et or class == .on or class == .bn or
            class == .nsm)) return false;
    }
    return !(has_en and has_an);
}

fn lastNonNsmClass(codepoints: []const u21) ?bidi.Class {
    var index = codepoints.len;
    while (index > 0) {
        index -= 1;
        const class = bidi.classForCodepoint(codepoints[index]);
        if (class != .nsm) return class;
    }
    return null;
}

fn checkJoiners(codepoints: []const u21) bool {
    for (codepoints, 0..) |codepoint, index| {
        if (codepoint == 0x200c) {
            if (index > 0 and
                combining_class.forCodepoint(codepoints[index - 1]) == 9)
            {
                continue;
            }
            if (index > 0 and index + 1 < codepoints.len and
                joinsBefore(codepoints, index) and
                joinsAfter(codepoints, index))
            {
                continue;
            }
            return false;
        }
        if (codepoint == 0x200d) {
            if (index > 0 and
                combining_class.forCodepoint(codepoints[index - 1]) == 9)
            {
                continue;
            }
            return false;
        }
    }
    return true;
}

fn joinsBefore(codepoints: []const u21, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const kind = joining.typeForCodepoint(codepoints[cursor]);
        if (kind == .transparent) continue;
        return kind == .left or kind == .dual;
    }
    return false;
}

fn joinsAfter(codepoints: []const u21, index: usize) bool {
    var cursor = index + 1;
    while (cursor < codepoints.len) : (cursor += 1) {
        const kind = joining.typeForCodepoint(codepoints[cursor]);
        if (kind == .transparent) continue;
        return kind == .right or kind == .dual;
    }
    return false;
}

fn checkContextO(codepoints: []const u21) bool {
    var has_arabic_indic = false;
    var has_extended_arabic_indic = false;
    for (codepoints, 0..) |codepoint, index| {
        switch (codepoint) {
            0x00b7 => {
                if (!(index > 0 and index + 1 < codepoints.len and
                    codepoints[index - 1] == 'l' and
                    codepoints[index + 1] == 'l')) return false;
            },
            0x0375 => {
                if (index + 1 >= codepoints.len or
                    script.forCodepoint(codepoints[index + 1]) != .greek)
                {
                    return false;
                }
            },
            0x05f3, 0x05f4 => {
                if (index == 0 or
                    script.forCodepoint(codepoints[index - 1]) != .hebrew)
                {
                    return false;
                }
            },
            0x30fb => {
                var found = false;
                for (codepoints) |other| {
                    const other_script = script.forCodepoint(other);
                    if (other_script == .hiragana or
                        other_script == .katakana or other_script == .han)
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            },
            0x0660...0x0669 => has_arabic_indic = true,
            0x06f0...0x06f9 => has_extended_arabic_indic = true,
            else => {},
        }
    }
    return !(has_arabic_indic and has_extended_arabic_indic);
}

// RFC 3492 Punycode

const base: u32 = 36;
const tmin: u32 = 1;
const tmax: u32 = 26;
const skew: u32 = 38;
const damp: u32 = 700;
const initial_bias: u32 = 72;
const initial_n: u32 = 128;

fn adapt(delta_input: u64, numpoints: u64, first_time: bool) u32 {
    var delta = if (first_time) delta_input / damp else delta_input / 2;
    delta += delta / numpoints;
    var k: u32 = 0;
    while (delta > ((base - tmin) * tmax) / 2) {
        delta /= base - tmin;
        k += base;
    }
    return k + @as(u32, @intCast((base - tmin + 1) * delta /
        (delta + skew)));
}

fn digitValue(byte: u8) ?u32 {
    if (byte >= 'a' and byte <= 'z') return byte - 'a';
    if (byte >= 'A' and byte <= 'Z') return byte - 'A';
    if (byte >= '0' and byte <= '9') return byte - '0' + 26;
    return null;
}

fn digitChar(value: u32) u8 {
    return if (value < 26) @intCast('a' + value) else @intCast('0' + (value - 26));
}

fn encodePunycode(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
) Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try appendPunycode(allocator, &output, codepoints);
    return output.toOwnedSlice(allocator);
}

fn appendPunycode(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoints: []const u21,
) Error!void {
    var basic_count: usize = 0;
    for (codepoints) |codepoint| {
        if (codepoint < 0x80) {
            try output.append(allocator, @intCast(codepoint));
            basic_count += 1;
        }
    }
    var handled = basic_count;
    if (basic_count > 0) try output.append(allocator, '-');

    var n: u32 = initial_n;
    var delta: u64 = 0;
    var bias: u32 = initial_bias;
    while (handled < codepoints.len) {
        var m: u32 = 0x10ffff;
        for (codepoints) |codepoint| {
            if (codepoint >= n and codepoint < m) m = codepoint;
        }
        delta += @as(u64, m - n) * @as(u64, handled + 1);
        n = m;

        for (codepoints) |codepoint| {
            if (codepoint < n) delta += 1;
            if (codepoint == n) {
                var q = delta;
                var k: u32 = base;
                while (true) {
                    const t = if (k <= bias) tmin else if (k >= bias + tmax)
                        tmax
                    else
                        k - bias;
                    if (q < t) break;
                    try output.append(
                        allocator,
                        digitChar(t + @as(u32, @intCast((q - t) % (base - t)))),
                    );
                    q = (q - t) / (base - t);
                    k += base;
                }
                try output.append(allocator, digitChar(@intCast(q)));
                bias = adapt(delta, handled + 1, handled == basic_count);
                delta = 0;
                handled += 1;
            }
        }
        delta += 1;
        n += 1;
    }
}

fn decodePunycode(
    allocator: std.mem.Allocator,
    input: []const u21,
) Error![]u21 {
    var output = std.ArrayList(u21).empty;
    errdefer output.deinit(allocator);

    var delimiter: ?usize = null;
    for (input, 0..) |codepoint, index| {
        if (codepoint == '-') delimiter = index;
    }
    const basic_end = delimiter orelse 0;
    for (input[0..basic_end]) |codepoint| {
        if (codepoint >= 0x80) return error.InvalidLabel;
        try output.append(allocator, codepoint);
    }

    var index = if (delimiter != null) basic_end + 1 else 0;
    var n: u32 = initial_n;
    var i: u32 = 0;
    var bias: u32 = initial_bias;

    while (index < input.len) {
        const old_i = i;
        var weight: u64 = 1;
        var k: u32 = base;
        while (true) {
            if (index >= input.len) return error.InvalidLabel;
            const codepoint = input[index];
            if (codepoint >= 0x80) return error.InvalidLabel;
            const digit = digitValue(@intCast(codepoint)) orelse
                return error.InvalidLabel;
            index += 1;
            i += digit * @as(u32, @intCast(weight));
            const t = if (k <= bias) tmin else if (k >= bias + tmax)
                tmax
            else
                k - bias;
            if (digit < t) break;
            weight *= base - t;
            k += base;
        }

        const out_len = output.items.len + 1;
        bias = adapt(@as(u64, i - old_i), @as(u64, out_len), old_i == 0);
        n += i / @as(u32, @intCast(out_len));
        i %= @as(u32, @intCast(out_len));
        if (n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff)) {
            return error.InvalidLabel;
        }
        try output.insert(allocator, @as(usize, i), @intCast(n));
        i += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn readU16(offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "punycode round trip" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const encoded = try encodePunycode(allocator, &.{ 'b', 0x00fc, 'c', 'h', 'e', 'r' });
    defer allocator.free(encoded);
    try testing.expectEqualStrings("bcher-kva", encoded);

    const decoded = try decodePunycode(allocator, &.{ 'b', 'c', 'h', 'e', 'r', '-', 'k', 'v', 'a' });
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u21, &.{ 'b', 0x00fc, 'c', 'h', 'e', 'r' }, decoded);
}

test "ToASCII and ToUnicode" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const ascii = try toAsciiAlloc(allocator, "b\u{00fc}cher.de", .{});
    defer allocator.free(ascii);
    try testing.expectEqualStrings("xn--bcher-kva.de", ascii);

    const unicode = try toUnicodeAlloc(allocator, "xn--bcher-kva.de", .{});
    defer allocator.free(unicode);
    try testing.expectEqualStrings("b\u{00fc}cher.de", unicode);
}

test "transitional deviation handling" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const nontransitional = try toAsciiAlloc(allocator, "fa\u{00df}.de", .{});
    defer allocator.free(nontransitional);
    try testing.expectEqualStrings("xn--fa-hia.de", nontransitional);

    const transitional = try toAsciiAlloc(
        allocator,
        "fa\u{00df}.de",
        .{ .transitional = true },
    );
    defer allocator.free(transitional);
    try testing.expectEqualStrings("fass.de", transitional);
}

const conformance = @embedFile("idna/conformance.bin");

fn fixtureU16(slice: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, slice[offset..][0..2], .little);
}

test "UTS #46 IDNA 16 conformance" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    if (conformance.len < 12 or
        !std.mem.eql(u8, conformance[0..4], "CJIT") or
        conformance[4] != 1 or conformance[5] != 16 or
        conformance[6] != 0 or conformance[7] != 0)
    {
        return error.InvalidFixture;
    }

    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    // The fixture contains all 6,389 UTS #46 cases. The default sampled run
    // keeps `zig build test` fast; set this to true for a full pass.
    const full_conformance = false;
    const stride: usize = if (full_conformance) 1 else 4;
    var offset: usize = 12;
    for (0..case_count) |case_index| {
        if (offset + 9 > conformance.len) return error.InvalidFixture;
        const source_len = fixtureU16(conformance, offset);
        const unicode_len = fixtureU16(conformance, offset + 2);
        const ascii_len = fixtureU16(conformance, offset + 4);
        const ascii_t_len = fixtureU16(conformance, offset + 6);
        const flags = conformance[offset + 8];
        offset += 9;

        const total = @as(usize, source_len) + unicode_len +
            ascii_len + ascii_t_len;
        if (offset + total > conformance.len) return error.InvalidFixture;

        const source = conformance[offset..][0..source_len];
        offset += source_len;
        const expected_unicode = conformance[offset..][0..unicode_len];
        offset += unicode_len;
        const expected_ascii = conformance[offset..][0..ascii_len];
        offset += ascii_len;
        const expected_ascii_t = conformance[offset..][0..ascii_t_len];
        offset += ascii_t_len;

        if (case_index % stride != 0) continue;

        const unicode_error = (flags & 1) != 0;
        if (unicode_error) {
            const result = toUnicodeAlloc(allocator, source, .{});
            if (result) |owned| {
                defer allocator.free(owned);
                std.debug.print(
                    "IDNA case {d}: expected ToUnicode error, got {s}\n",
                    .{ case_index, owned },
                );
                return error.TestUnexpectedResult;
            } else |_| {}
        } else {
            const owned = toUnicodeAlloc(allocator, source, .{}) catch |err| {
                std.debug.print(
                    "IDNA case {d}: ToUnicode error {any} for {x}\n",
                    .{ case_index, err, source },
                );
                return error.TestUnexpectedResult;
            };
            defer allocator.free(owned);
            if (!std.mem.eql(u8, owned, expected_unicode)) {
                std.debug.print(
                    "IDNA case {d}: ToUnicode {s} != {s}\n",
                    .{ case_index, owned, expected_unicode },
                );
                return error.TestUnexpectedResult;
            }
        }

        const ascii_error = (flags & 2) != 0;
        if (ascii_error) {
            const result = toAsciiAlloc(allocator, source, .{});
            if (result) |owned| {
                defer allocator.free(owned);
                std.debug.print(
                    "IDNA case {d}: expected ToASCII error, got {s}\n",
                    .{ case_index, owned },
                );
                return error.TestUnexpectedResult;
            } else |_| {}
        } else {
            const owned = toAsciiAlloc(allocator, source, .{}) catch |err| {
                std.debug.print(
                    "IDNA case {d}: ToASCII error {any} for {x}\n",
                    .{ case_index, err, source },
                );
                return error.TestUnexpectedResult;
            };
            defer allocator.free(owned);
            if (!std.mem.eql(u8, owned, expected_ascii)) {
                std.debug.print(
                    "IDNA case {d}: ToASCII {s} != {s}\n",
                    .{ case_index, owned, expected_ascii },
                );
                return error.TestUnexpectedResult;
            }
        }

        const ascii_t_error = (flags & 4) != 0;
        if (ascii_t_error) {
            const result = toAsciiAlloc(
                allocator,
                source,
                .{ .transitional = true },
            );
            if (result) |owned| {
                defer allocator.free(owned);
                std.debug.print(
                    "IDNA case {d}: expected transitional error, got {s}\n",
                    .{ case_index, owned },
                );
                return error.TestUnexpectedResult;
            } else |_| {}
        } else {
            const owned = toAsciiAlloc(
                allocator,
                source,
                .{ .transitional = true },
            ) catch |err| {
                std.debug.print(
                    "IDNA case {d}: transitional error {any} for {x}\n",
                    .{ case_index, err, source },
                );
                return error.TestUnexpectedResult;
            };
            defer allocator.free(owned);
            if (!std.mem.eql(u8, owned, expected_ascii_t)) {
                std.debug.print(
                    "IDNA case {d}: transitional {s} != {s}\n",
                    .{ case_index, owned, expected_ascii_t },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
    if (offset != conformance.len) return error.InvalidFixture;
}
