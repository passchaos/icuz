//! Unicode 17 normalization for UTF-8 text.
//!
//! This module implements the four UAX #15 forms: NFC, NFD, NFKC, and NFKD.
//! Canonical forms use recursive canonical decomposition and canonical
//! combining-class ordering; compatibility forms additionally apply
//! compatibility mappings. NFC and NFKC then perform canonical composition,
//! including algorithmic Hangul handling. The module deliberately does not
//! perform display-specific or language-specific reordering.

const std = @import("std");
const scalar = @import("../scalar/root.zig");
const combining_class = @import("../canonical/combining_class.zig");
const decomposition = @import("../canonical/decomposition.zig");
const data = @import("data.zig");
const inert = @import("inert.zig");
const utf16 = @import("../utf16.zig");

const conformance = @embedFile("conformance.bin");

pub const unicode_version = [3]u8{ 17, 0, 0 };
pub const Error = error{ InvalidUtf8, OutOfMemory };
pub const QuickCheck = data.QuickCheck;
pub const Form = data.Form;
pub const nfkcCasefoldAlloc = @import("casefold.zig").nfkcCasefoldAlloc;
pub const nfkcSimpleCasefoldAlloc = @import("casefold.zig").nfkcSimpleCasefoldAlloc;

/// Canonical decomposition mapping for one scalar, or null when it has none.
/// Hangul syllables decompose algorithmically; use `decomposeInto` for those.
pub fn decompositionFor(codepoint: u21) ?[]const u21 {
    return decomposition.forCodepoint(codepoint);
}

/// Compatibility decomposition mapping for one scalar, or null.
pub fn compatibilityDecompositionFor(codepoint: u21) ?[]const u21 {
    return decomposition.compatibilityForCodepoint(codepoint);
}

/// Canonical combining class for one scalar.
pub fn combiningClass(codepoint: u21) u8 {
    return combining_class.forCodepoint(codepoint);
}

/// Return Unicode's per-scalar NFC_Quick_Check value.
pub const quickCheckCodepoint = data.nfcQuickCheck;

/// Return Unicode's per-scalar quick-check value for one normalization form.
pub fn quickCheckFormCodepoint(codepoint: u21, form: Form) QuickCheck {
    return data.quickCheck(codepoint, form);
}

/// Return an allocator-owned NFC string when `text` must change, or `null`
/// when it is already NFC. ASCII and all other normalized input allocate
/// nothing. Invalid UTF-8 is rejected before any allocation.
pub fn normalizeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfc);
}

pub fn normalizeNfdAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfd);
}

pub fn normalizeNfkcAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfkc);
}

pub fn normalizeNfkdAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) Error!?[]u8 {
    return normalizeFormAlloc(allocator, text, .nfkd);
}

/// Validate UTF-8, copy stable spans verbatim, and normalize only the spans
/// that can change, all in one pass. Returns whether any edit was applied.
/// Output is untouched when the text is already normalized.
/// True when every scalar in U+4000..U+9FFF is on a simple page in both
/// canonical and compatibility normalization. Canonical composition pairs do
/// not start in this range, so the scans can skip decoding these CJK scalars
/// and treat them as starters.
const cjk_lead_simple = blk: {
    @setEvalBranchQuota(100_000);
    for (0x40..0xa0) |page| {
        const codepoint: u21 = @intCast(page * 256);
        if (!data.isSimplePage(codepoint, false)) break :blk false;
        if (!data.isSimplePage(codepoint, true)) break :blk false;
    }
    break :blk true;
};

/// True for the CJK punctuation and fullwidth blocks that are inert under the
/// canonical forms and start no composition pair.
inline fn isInertCjkPunctuation(unit: u21) bool {
    return (unit >= 0x3000 and unit <= 0x303f and
        (unit < 0x302a or unit > 0x302f)) or
        (unit >= 0xff00 and unit <= 0xffef);
}

/// True when `codepoint` is inert for `form`: unchanged and unable to compose
/// with a preceding starter.
fn latin1Inert(form: Form, codepoint: u21) bool {
    if (data.quickCheck(codepoint, form) != .yes) return false;
    return combining_class.forCodepoint(codepoint) == 0;
}

const Latin1Run = enum {
    /// No Latin-1 scalar joins a run.
    none,
    /// Every Latin-1 scalar joins a run.
    all,
    /// Only the scalars marked in `latin1_inert_by_form` join a run.
    some,
};

fn latin1RunMode(comptime form: Form) Latin1Run {
    @setEvalBranchQuota(100_000);
    var any = false;
    var all = true;
    for (0x80..0x100) |codepoint| {
        if (latin1Inert(form, @intCast(codepoint))) {
            any = true;
        } else {
            all = false;
        }
    }
    return if (all) .all else if (any) .some else .none;
}

/// Per-scalar inertness of the Latin-1 block, used by the scans that take a
/// runtime form and by the `some` run mode.
const latin1_inert_by_form: [4][0x80]bool = blk: {
    @setEvalBranchQuota(200_000);
    var table: [4][0x80]bool = undefined;
    for (0..4) |form_index| {
        const form: Form = @enumFromInt(form_index);
        for (0x80..0x100) |codepoint| {
            table[form_index][codepoint - 0x80] = latin1Inert(
                form,
                @intCast(codepoint),
            );
        }
    }
    break :blk table;
};

const latin1_mode_by_form = [4]Latin1Run{
    latin1RunMode(.nfc),
    latin1RunMode(.nfd),
    latin1RunMode(.nfkc),
    latin1RunMode(.nfkd),
};

/// `jamoRunInert` for the scans that take a runtime form.
const jamo_run_inert_by_form = [4]bool{
    jamoRunInert(.nfc),
    jamoRunInert(.nfd),
    jamoRunInert(.nfkc),
    jamoRunInert(.nfkd),
};

/// True when every Hangul jamo scalar is inert for `form`. The decomposed
/// forms leave the block untouched; the composed forms treat V and T as
/// composition seconds.
fn jamoRunInert(comptime form: Form) bool {
    @setEvalBranchQuota(100_000);
    for (0x1100..0x1200) |codepoint| {
        const value: u21 = @intCast(codepoint);
        if (data.quickCheck(value, form) != .yes) return false;
        if (combining_class.forCodepoint(value) != 0) return false;
    }
    return true;
}

const ScanRun = struct {
    /// Offset one past the run.
    end: usize,
    /// Last scalar of the run and its byte offset.
    last_codepoint: u21,
    last_offset: usize,
};

/// Scan one run of ASCII scalars and, when `mode` allows, two-byte Latin-1
/// scalars, merging alternations of the two so a prose span is one run.
/// `start` must point at an ASCII byte or a Latin-1 lead. Returns an empty
/// run when the first scalar is Latin-1 and not inert.
inline fn scanAsciiLatin1Run(
    text: []const u8,
    start: usize,
    comptime mode: Latin1Run,
    mask: *const [0x80]bool,
) ScanRun {
    var end = start;
    var last_codepoint: u21 = undefined;
    var last_offset: usize = start;
    while (true) {
        const ascii_start = end;
        // Prose runs are short, so after the first two ASCII bytes find the
        // next non-ASCII byte eight bytes at a time. Single-byte runs (a
        // space between jamo or CJK scalars) cost the same two checks as the
        // scalar loop.
        if (end < text.len and text[end] < 0x80) {
            end += 1;
            if (end < text.len and text[end] < 0x80) {
                while (end + 8 <= text.len) {
                    const word = std.mem.readInt(
                        u64,
                        text[end..][0..8],
                        .little,
                    );
                    const high = word & 0x8080_8080_8080_8080;
                    if (high != 0) {
                        end += @ctz(high) / 8;
                        break;
                    }
                    end += 8;
                }
                while (end < text.len and text[end] < 0x80) end += 1;
            }
        }
        if (end > ascii_start) {
            last_codepoint = text[end - 1];
            last_offset = end - 1;
        }
        if (mode == .none or end + 1 >= text.len or
            (text[end] != 0xc2 and text[end] != 0xc3) or
            (text[end + 1] & 0xc0) != 0x80)
        {
            break;
        }
        const codepoint = (@as(u21, text[end] & 0x1f) << 6) |
            (text[end + 1] & 0x3f);
        if (mode == .some and !mask[codepoint - 0x80]) break;
        last_codepoint = codepoint;
        last_offset = end;
        end += 2;
    }
    return .{
        .end = end,
        .last_codepoint = last_codepoint,
        .last_offset = last_offset,
    };
}

fn normalizeFusedInto(
    comptime form: Form,
    allocator: std.mem.Allocator,
    text: []const u8,
    output: *std.ArrayList(u8),
) Error!bool {
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return false;

    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    const latin1_mode = comptime latin1RunMode(form);
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = comptime jamoRunInert(form);
    var engine = SegmentEngine(Utf8Sink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = compatibility,
        .compose = compose,
    };
    defer engine.deinit();
    var stable_start: usize = 0;
    var changed = false;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var starter_offset: usize = if (ascii_end > 0) ascii_end - 1 else 0;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80 or
            (latin1_mode != .none and
                (text[index] == 0xc2 or text[index] == 0xc3) and
                index + 1 < text.len and (text[index + 1] & 0xc0) == 0x80))
        {
            const run = switch (latin1_mode) {
                .none => scanAsciiLatin1Run(text, index, .none, latin1_mask),
                .all => scanAsciiLatin1Run(text, index, .all, latin1_mask),
                .some => scanAsciiLatin1Run(text, index, .some, latin1_mask),
            };
            if (run.end > index) {
                starter = run.last_codepoint;
                starter_offset = run.last_offset;
                previous_input_class = 0;
                index = run.end;
                continue;
            }
        }
        // A decomposable Latin-1 starter that neither joins the previous
        // segment nor is continued by the next one is emitted directly under
        // the decomposed forms.
        if (!compose and latin1_mode == .some and previous_input_class == 0 and
            (text[index] == 0xc2 or text[index] == 0xc3) and
            index + 1 < text.len and (text[index + 1] & 0xc0) == 0x80)
        {
            const codepoint = (@as(u21, text[index] & 0x1f) << 6) |
                (text[index + 1] & 0x3f);
            if (!latin1_mask[codepoint - 0x80] and
                !continuesSegment(codepoint, compatibility) and
                nextStartsSegment(text, index + 2, compatibility))
            {
                if (!changed) {
                    try output.ensureTotalCapacityPrecise(allocator, text.len);
                    changed = true;
                }
                if (index > stable_start) {
                    try appendBytes(
                        allocator,
                        output,
                        text[stable_start..index],
                    );
                }
                var storage: [64]u21 = undefined;
                const count = decomposeInto(
                    &storage,
                    codepoint,
                    compatibility,
                );
                try engine.sink.appendCodepoints(storage[0..count]);
                stable_start = index + 2;
                index += 2;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
        }
        // A fullwidth scalar with a single-component decomposition gets the
        // same treatment under the compatibility forms.
        if (compatibility and previous_input_class == 0 and
            text[index] == 0xef and index + 2 < text.len and
            (text[index + 1] & 0xfc) == 0xbc and
            (text[index + 2] & 0xc0) == 0x80)
        {
            const codepoint = (@as(u21, 0x0f) << 12) |
                (@as(u21, text[index + 1] & 0x3f) << 6) |
                (text[index + 2] & 0x3f);
            if (fullwidth_compatibility_decomposition[codepoint - 0xff00]) |components| {
                if (components.len == 1 and
                    !continuesSegment(codepoint, compatibility) and
                    nextStartsSegment(text, index + 3, compatibility))
                {
                    if (!changed) {
                        try output.ensureTotalCapacityPrecise(
                            allocator,
                            text.len,
                        );
                        changed = true;
                    }
                    if (index > stable_start) {
                        try appendBytes(
                            allocator,
                            output,
                            text[stable_start..index],
                        );
                    }
                    try engine.sink.appendCodepoints(components);
                    stable_start = index + 3;
                    index += 3;
                    starter = null;
                    starter_offset = index;
                    previous_input_class = 0;
                    continue;
                }
            }
        }
        const start = index;
        if (jamo_run and text[index] == 0xe1 and index + 2 < text.len and
            (text[index + 1] & 0xfc) == 0x84 and
            (text[index + 2] & 0xc0) == 0x80)
        {
            // The decomposed forms leave the jamo block untouched, so a run
            // of it is skipped like ASCII.
            var end = index;
            while (end + 2 < text.len and text[end] == 0xe1 and
                (text[end + 1] & 0xfc) == 0x84 and
                (text[end + 2] & 0xc0) == 0x80)
            {
                end += 3;
            }
            starter = (@as(u21, text[end - 3] & 0x0f) << 12) |
                (@as(u21, text[end - 2] & 0x3f) << 6) |
                (text[end - 1] & 0x3f);
            starter_offset = end - 3;
            previous_input_class = 0;
            index = end;
            continue;
        }
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            // CJK prose dominates this scan. Every scalar in the run is a
            // simple starter, so advance two scalars per check and commit the
            // scan state once when the run ends. Inert punctuation and
            // fullwidth forms between ideographs join the run.
            var cursor = index;
            while (true) {
                while (cursor + 6 <= text.len and
                    text[cursor] >= 0xe4 and text[cursor] <= 0xe9 and
                    text[cursor + 3] >= 0xe4 and text[cursor + 3] <= 0xe9 and
                    ((text[cursor + 1] | text[cursor + 2] |
                        text[cursor + 4] | text[cursor + 5]) & 0xc0) == 0x80)
                {
                    cursor += 6;
                }
                if (cursor < text.len and text[cursor] >= 0xe4 and
                    text[cursor] <= 0xe9)
                {
                    if (cursor + 3 > text.len) return error.InvalidUtf8;
                    if (text[cursor + 1] & 0xc0 != 0x80 or
                        text[cursor + 2] & 0xc0 != 0x80)
                    {
                        return error.InvalidUtf8;
                    }
                    cursor += 3;
                    continue;
                }
                if (!compatibility and cursor + 3 <= text.len and
                    (text[cursor] | 0x0c) == 0xef)
                {
                    const second = text[cursor + 1];
                    const third = text[cursor + 2];
                    if ((text[cursor] == 0xe3 and second == 0x80 and
                        (third < 0xaa or third > 0xaf)) or
                        (text[cursor] == 0xef and second == 0xbc))
                    {
                        if (third & 0xc0 != 0x80) return error.InvalidUtf8;
                        cursor += 3;
                        continue;
                    }
                }
                break;
            }
            starter = null;
            starter_offset = start;
            previous_input_class = 0;
            index = cursor;
            continue;
        }
        // CJK punctuation and fullwidth forms are inert under the canonical
        // forms and start no composition pair, so their blocks skip the table
        // lookups. The compatibility forms decompose them and keep the
        // generic path; U+302A..U+302F are tone marks with non-zero
        // combining classes and also stay generic.
        if (!compatibility) {
            const lead = text[index];
            if ((lead | 0x0c) == 0xef and index + 3 <= text.len) {
                @branchHint(.unlikely);
                const second = text[index + 1];
                const third = text[index + 2];
                if ((lead == 0xe3 and second == 0x80 and
                    (third < 0xaa or third > 0xaf)) or
                    (lead == 0xef and second == 0xbc))
                {
                    if (third & 0xc0 != 0x80) return error.InvalidUtf8;
                    starter = null;
                    starter_offset = start;
                    previous_input_class = 0;
                    index += 3;
                    continue;
                }
            }
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);

        // Compose L+V+T jamo directly: the syllable index is arithmetic, so
        // the generic segment machinery (decompose, order, compose, encode)
        // has nothing to add. A preceding mark keeps the generic path, which
        // tracks ordering against the earlier starter.
        if (compose and previous_input_class == 0 and
            codepoint >= hangul_l_base and
            codepoint < hangul_l_base + hangul_l_count)
        {
            var syllable_end: usize = undefined;
            if (hangulSyllableAt(
                text,
                codepoint,
                index,
                &syllable_end,
            )) |composed| {
                if (!changed) {
                    try output.ensureTotalCapacityPrecise(
                        allocator,
                        text.len,
                    );
                    changed = true;
                }
                if (start > stable_start) {
                    try appendBytes(
                        allocator,
                        output,
                        text[stable_start..start],
                    );
                }
                // A composed syllable is always U+AC00..U+D7A3, so it
                // encodes to exactly three bytes; write them in place.
                const slot = try output.addManyAsSlice(allocator, 3);
                slot[0] = @intCast(0xe0 | (composed >> 12));
                slot[1] = @intCast(0x80 | ((composed >> 6) & 0x3f));
                slot[2] = @intCast(0x80 | (composed & 0x3f));
                index = syllable_end;
                stable_start = index;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
        }

        if (codepoint >= 0x80 and inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        const current_class = combining_class.forCodepoint(codepoint);
        const edit = quick_check == .no or
            (current_class != 0 and previous_input_class > current_class) or
            (quick_check == .maybe and starter != null and
                (previous_input_class == 0 or
                    previous_input_class < current_class) and
                pairChangesUnderForm(starter.?, codepoint, form));
        if (edit) {
            if (!changed) {
                try output.ensureTotalCapacityPrecise(allocator, text.len);
                changed = true;
            }
            // A starter that does not continue the previous segment begins a
            // new one; every scalar before it is stable and can be copied
            // verbatim instead of reopening the previous starter's segment.
            const segment_start = if (current_class == 0 and
                previous_input_class == 0 and
                !continuesSegment(codepoint, compatibility))
                start
            else
                starter_offset;
            if (segment_start > stable_start) {
                try appendBytes(
                    allocator,
                    output,
                    text[stable_start..segment_start],
                );
            }
            // A starter that no following scalar continues is its own
            // segment, so it can skip the generic segment machinery.
            if (segment_start == start and
                nextStartsSegment(text, index, compatibility))
            {
                try emitSingleScalar(
                    &engine.sink,
                    codepoint,
                    compatibility,
                    compose,
                );
                stable_start = index;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
            const end = (try normalizeSegmentFastAt(
                allocator,
                text,
                segment_start,
                form,
                output,
            )) orelse blk: {
                const fallback_end = segmentEnd(
                    text,
                    segment_start,
                    compatibility,
                );
                try normalizeSegmentInto(
                    &engine,
                    text[segment_start..fallback_end],
                );
                break :blk fallback_end;
            };
            stable_start = end;
            index = end;
            starter = null;
            starter_offset = end;
            previous_input_class = 0;
            continue;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    if (!changed) return false;
    try appendBytes(allocator, output, text[stable_start..]);
    return true;
}

/// Specialize the fused scan per form so quick-check shifts, inert slots,
/// and the compose/compatibility switches fold to constants.
fn normalizeFused(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!bool {
    return switch (form) {
        inline else => |specialized| normalizeFusedInto(
            specialized,
            allocator,
            text,
            output,
        ),
    };
}

/// Return an allocator-owned string in `form` when `text` must change, or
/// `null` when it is already normalized. Invalid UTF-8 is rejected before any
/// allocation.
pub fn normalizeFormAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
) Error!?[]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    if (!try normalizeFused(allocator, text, form, &output)) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

/// Append the normalized form of `text` to `output`.
///
/// Returns whether the normalized text differs from the input. The output
/// receives the normalized text in both cases, so callers can reuse one buffer
/// across calls.
pub fn normalizeFormInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!bool {
    const before = output.items.len;
    const changed = normalizeFused(allocator, text, form, output) catch |err| {
        output.shrinkRetainingCapacity(before);
        return err;
    };
    if (!changed) try output.appendSlice(allocator, text);
    return changed;
}

/// Normalize a code-point slice. Returns null when the slice is unchanged.
pub fn normalizeCodepointsAlloc(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    form: Form,
) error{OutOfMemory}!?[]u21 {
    if (isNormalizedCodepoints(codepoints, form)) return null;

    var output = std.ArrayList(u21).empty;
    errdefer output.deinit(allocator);
    try normalizeCodepointsInto(allocator, codepoints, form, &output);
    const result = try output.toOwnedSlice(allocator);
    if (std.mem.eql(u21, result, codepoints)) {
        allocator.free(result);
        return null;
    }
    return result;
}

/// Outcome of `normalizeCodepointsTryInto`.
pub const CodepointNormalization = union(enum) {
    /// The input is already in the requested form.
    unchanged,
    /// The normalized form was written into the caller's buffer.
    written: []const u21,
    /// The buffer was too small; callers should fall back to the allocating
    /// API.
    overflow,
};

/// Normalize already decoded code points into a caller-owned buffer without
/// heap allocation when the result fits. Short sort keys and search
/// candidates use this to avoid a per-call allocation.
pub fn normalizeCodepointsTryInto(
    buffer: []u21,
    codepoints: []const u21,
    form: Form,
) CodepointNormalization {
    if (isNormalizedCodepoints(codepoints, form)) return .unchanged;
    return normalizeCodepointsTryIntoChanged(buffer, codepoints, form);
}

/// `normalizeCodepointsTryInto` for input already known to need changes,
/// so callers that checked quick-check status do not scan it twice.
pub fn normalizeCodepointsTryIntoChanged(
    buffer: []u21,
    codepoints: []const u21,
    form: Form,
) CodepointNormalization {
    var fixed = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(buffer));
    var output = std.ArrayList(u21).empty;
    normalizeCodepointsInto(fixed.allocator(), codepoints, form, &output) catch
        return .overflow;
    return .{ .written = output.items };
}

/// Append the recursive canonical decomposition of a single code point to
/// `output` without reordering it against surrounding text. ICU's identical
/// collation strength compares this per-code-point decomposition.
pub fn appendCanonicalDecompositionInto(
    allocator: std.mem.Allocator,
    codepoint: u21,
    output: *std.ArrayList(u21),
) error{OutOfMemory}!void {
    try appendDecomposition(allocator, output, codepoint, false);
}

/// Combining Diacritical Marks with no canonical decomposition. The
/// generated decomposition lookup is page-indexed, but its binary search
/// still costs more than a bitmap test for the marks that dominate segment
/// normalization.
const mark_decomposition_limit = 0x370;
const mark_has_decomposition: [mark_decomposition_limit - 0x300]bool = blk: {
    @setEvalBranchQuota(200_000);
    var table: [mark_decomposition_limit - 0x300]bool = undefined;
    for (0x300..mark_decomposition_limit) |codepoint| {
        table[codepoint - 0x300] =
            decomposition.forCodepoint(@intCast(codepoint)) != null;
    }
    break :blk table;
};
const mark_has_compatibility_decomposition: [mark_decomposition_limit - 0x300]bool = blk: {
    @setEvalBranchQuota(200_000);
    var table: [mark_decomposition_limit - 0x300]bool = undefined;
    for (0x300..mark_decomposition_limit) |codepoint| {
        table[codepoint - 0x300] =
            decomposition.compatibilityForCodepoint(@intCast(codepoint)) != null;
    }
    break :blk table;
};

/// Direct decomposition table for one 256-scalar block. Blocks that carry
/// ordinary prose mappings skip the generated page lookup's binary search.
fn blockDecomposition(
    comptime base: u21,
    comptime compatibility: bool,
) [0x100]?[]const u21 {
    @setEvalBranchQuota(200_000);
    var table: [0x100]?[]const u21 = [_]?[]const u21{null} ** 0x100;
    for (0..0x100) |offset| {
        const codepoint = base + offset;
        if (codepoint > 0x10ffff) break;
        table[offset] = if (compatibility)
            decomposition.compatibilityForCodepoint(@intCast(codepoint))
        else
            decomposition.forCodepoint(@intCast(codepoint));
    }
    return table;
}

/// Latin-1 decomposition mappings indexed directly by scalar. Precomposed
/// Latin letters dominate decomposed prose.
const latin1_decomposition = blockDecomposition(0x00, false);
const latin1_compatibility_decomposition = blockDecomposition(0x00, true);
/// Fullwidth and halfwidth forms decompose under the compatibility forms and
/// dominate CJK prose.
const fullwidth_compatibility_decomposition = blockDecomposition(0xff00, true);

/// Decompose one code point into `buffer` and return the component count.
pub fn decomposeInto(
    buffer: *[64]u21,
    codepoint: u21,
    compatibility: bool,
) usize {
    if (codepoint < 0x80) {
        buffer[0] = codepoint;
        return 1;
    }
    if (codepoint < 0x100) {
        const mapping = if (compatibility)
            latin1_compatibility_decomposition[codepoint]
        else
            latin1_decomposition[codepoint];
        if (mapping) |components| {
            @memcpy(buffer[0..components.len], components);
            return components.len;
        }
        buffer[0] = codepoint;
        return 1;
    }
    if (compatibility and codepoint >= 0xff00 and codepoint < 0x10000) {
        if (fullwidth_compatibility_decomposition[codepoint - 0xff00]) |components| {
            @memcpy(buffer[0..components.len], components);
            return components.len;
        }
    }
    if (decomposeHangul(codepoint)) |parts| {
        const slice = parts.slice();
        @memcpy(buffer[0..slice.len], slice);
        return slice.len;
    }
    if (codepoint >= 0x300 and codepoint < mark_decomposition_limit and
        !(if (compatibility)
            mark_has_compatibility_decomposition[codepoint - 0x300]
        else
            mark_has_decomposition[codepoint - 0x300]))
    {
        buffer[0] = codepoint;
        return 1;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        @memcpy(buffer[0..components.len], components);
        return components.len;
    }
    buffer[0] = codepoint;
    return 1;
}

/// Incremental starter-segment normalizer. Canonical ordering and
/// composition run per starter segment instead of over the whole string, and
/// one-code-point segments (ASCII prose, CJK, and so on) skip both passes.
/// Output sink for the segment engine: code points or UTF-8 bytes.
const CodepointSink = struct {
    list: *std.ArrayList(u21),
    allocator: std.mem.Allocator,

    fn appendCodepoints(
        self: *CodepointSink,
        codepoints: []const u21,
    ) error{OutOfMemory}!void {
        try self.list.appendSlice(self.allocator, codepoints);
    }

    fn appendOne(
        self: *CodepointSink,
        codepoint: u21,
    ) error{OutOfMemory}!void {
        try self.list.append(self.allocator, codepoint);
    }
};

/// Append bytes without routing one- to four-byte spans through memcpy.
inline fn appendBytes(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    bytes: []const u8,
) error{OutOfMemory}!void {
    if (list.unusedCapacitySlice().len < bytes.len) {
        try list.ensureUnusedCapacity(allocator, bytes.len);
    }
    const dest = list.unusedCapacitySlice();
    switch (bytes.len) {
        0 => return,
        1 => dest[0] = bytes[0],
        2 => {
            dest[0] = bytes[0];
            dest[1] = bytes[1];
        },
        3 => {
            dest[0] = bytes[0];
            dest[1] = bytes[1];
            dest[2] = bytes[2];
        },
        4 => {
            dest[0] = bytes[0];
            dest[1] = bytes[1];
            dest[2] = bytes[2];
            dest[3] = bytes[3];
        },
        else => @memcpy(dest[0..bytes.len], bytes),
    }
    list.items.len += bytes.len;
}

/// Encode one scalar into the reserved tail of an output buffer.
///
/// Reservations are sized to the exact encoded length, so the last scalar may
/// leave fewer than four bytes of room. The common case still writes straight
/// into the buffer; the short tail falls back to a stack buffer.
inline fn encodeScalarInto(dest: []u8, written: usize, codepoint: u21) usize {
    const room = dest[written..];
    if (room.len >= 4) return scalar.encodeUtf8(room[0..4], codepoint);
    var encoded: [4]u8 = undefined;
    const length = scalar.encodeUtf8(&encoded, codepoint);
    @memcpy(room[0..length], encoded[0..length]);
    return length;
}

const Utf8Sink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn appendCodepoints(
        self: *Utf8Sink,
        codepoints: []const u21,
    ) error{OutOfMemory}!void {
        // Size the request by the encoded length, not four bytes per scalar:
        // an over-request on a small edit forces a grow and then a shrink
        // copy in toOwnedSlice.
        var needed: usize = 0;
        for (codepoints) |codepoint| {
            needed += if (codepoint < 0x80)
                1
            else if (codepoint < 0x800)
                2
            else if (codepoint < 0x10000)
                3
            else
                4;
        }
        if (self.list.unusedCapacitySlice().len < needed) {
            try self.list.ensureTotalCapacityPrecise(
                self.allocator,
                self.list.items.len + needed,
            );
        }
        const dest = self.list.unusedCapacitySlice();
        var written: usize = 0;
        for (codepoints) |codepoint| {
            written += encodeScalarInto(dest, written, codepoint);
        }
        self.list.items.len += written;
    }

    fn appendOne(
        self: *Utf8Sink,
        codepoint: u21,
    ) error{OutOfMemory}!void {
        var encoded: [4]u8 = undefined;
        const length = scalar.encodeUtf8(&encoded, codepoint);
        try appendBytes(self.allocator, self.list, encoded[0..length]);
    }

    fn appendAsciiBytes(
        self: *Utf8Sink,
        bytes: []const u8,
    ) error{OutOfMemory}!void {
        try appendBytes(self.allocator, self.list, bytes);
    }
};

/// Incremental starter-segment normalizer. Canonical ordering and
/// composition run per starter segment instead of over the whole string, and
/// one-code-point segments (ASCII prose, CJK, and so on) skip both passes.
fn SegmentEngine(comptime Sink: type) type {
    return struct {
        allocator: std.mem.Allocator,
        sink: Sink,
        segment: std.ArrayList(u21) = .empty,
        /// Starter that may still receive combining marks; written to the
        /// output only once the next starter proves that it has none.
        pending: ?u21 = null,
        form: Form,
        compatibility: bool,
        compose: bool,

        const Self = @This();

        fn deinit(self: *Self) void {
            self.segment.deinit(self.allocator);
        }

        fn feed(self: *Self, codepoint: u21) error{OutOfMemory}!void {
            // Inert scalars are unchanged by the form and cannot compose with
            // a previous starter. Under the composed forms they can still
            // decompose when a following mark joins their segment, so keep
            // them pending until that is known.
            if (codepoint >= 0x80 and inert.isInert(codepoint, self.form)) {
                try self.settle();
                self.pending = codepoint;
                return;
            }
            try self.feedDecomposed(codepoint);
        }

        /// Decompose `codepoint` and feed its components. A pending starter is
        /// decomposed too: a composed scalar such as `à` is inert on its own
        /// but must expand before a lower-class mark can reorder past its
        /// decomposition.
        fn feedDecomposed(
            self: *Self,
            codepoint: u21,
        ) error{OutOfMemory}!void {
            // Unicode 17's longest recursive compatibility decomposition has
            // 18 components; 64 leaves generous headroom.
            var parts: [64]u21 = undefined;
            const count = decomposeInto(&parts, codepoint, self.compatibility);
            for (parts[0..count]) |part| {
                // A segment ends at a starter that cannot compose with the
                // previous character. Spacing marks such as U+0DCF have
                // combining class 0 but are composition seconds, so they stay
                // inside the segment.
                const starter = part < 0x80 or inert.isInert(part, self.form);
                if (starter) {
                    try self.settle();
                    self.pending = part;
                } else {
                    if (self.pending) |pending| {
                        self.pending = null;
                        try self.feedDecomposed(pending);
                        if (self.pending) |last_starter| {
                            self.pending = null;
                            try self.segment.append(
                                self.allocator,
                                last_starter,
                            );
                        }
                    }
                    try self.segment.append(self.allocator, part);
                }
            }
        }

        /// Emit the pending starter or the accumulated mark segment.
        fn settle(self: *Self) error{OutOfMemory}!void {
            const items = self.segment.items;
            if (items.len > 0) {
                canonicalOrder(items);
                const len = if (self.compose) composeSlice(items) else items.len;
                try self.sink.appendCodepoints(items[0..len]);
                self.segment.clearRetainingCapacity();
                return;
            }
            if (self.pending) |pending| {
                try self.sink.appendOne(pending);
                self.pending = null;
            }
        }

        fn flush(self: *Self) error{OutOfMemory}!void {
            try self.settle();
        }
    };
}

/// Append the normalized form of a code-point slice to `output`.
pub fn normalizeCodepointsInto(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    form: Form,
    output: *std.ArrayList(u21),
) error{OutOfMemory}!void {
    // Decomposition rarely grows text beyond the input; reserve once so the
    // per-code-point append does not trigger repeated reallocation.
    try output.ensureUnusedCapacity(allocator, codepoints.len);
    var engine = SegmentEngine(CodepointSink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = form == .nfkc or form == .nfkd,
        .compose = form == .nfc or form == .nfkc,
    };
    defer engine.deinit();
    var index: usize = 0;
    while (index < codepoints.len) {
        // Bulk-copy inert starters; only the final one may still receive
        // combining marks, so it stays pending.
        const run_start = index;
        while (index < codepoints.len and
            (codepoints[index] < 0x80 or
                inert.isInert(codepoints[index], form)))
        {
            index += 1;
        }
        if (index > run_start) {
            try engine.settle();
            const run = codepoints[run_start..index];
            if (run.len > 1) {
                try engine.sink.appendCodepoints(run[0 .. run.len - 1]);
            }
            engine.pending = run[run.len - 1];
            continue;
        }
        try engine.feed(codepoints[index]);
        index += 1;
    }
    try engine.flush();
}

/// Report whether a code-point slice is in `form` without allocating.
pub fn isNormalizedCodepoints(
    codepoints: []const u21,
    form: Form,
) bool {
    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    for (codepoints) |codepoint| {
        if (codepoint < 0x80) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        if (inert.isInert(codepoint, form)) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) return false;
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class) return false;
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return false;
        }
        if (current_class == 0) starter = codepoint;
        previous_input_class = current_class;
    }
    return true;
}

/// True when the scalar is inert under NFD: ASCII, or no canonical
/// decomposition with a zero combining class.
pub inline fn isNfdInert(codepoint: u21) bool {
    if (codepoint < 0x80) return true;
    return inert.isInert(codepoint, .nfd);
}

/// Streaming NFD quick-check state. Callers that already decode UTF-8 can
/// feed each scalar as it is produced instead of scanning the decoded array
/// again; the state matches `isNormalizedCodepoints(codepoints, .nfd)`.
///
/// NFD's quick check only reports Yes or No, so the starter scalar is not
/// needed for a Maybe pair test; only the previous combining class and the
/// failure flag matter.
pub const NfdScan = struct {
    previous_class: u8 = 0,
    ok: bool = true,

    pub inline fn feed(self: *NfdScan, codepoint: u21) void {
        if (!self.ok) return;
        if (codepoint < 0x80) {
            self.previous_class = 0;
            return;
        }
        if (inert.isInert(codepoint, .nfd)) {
            self.previous_class = 0;
            return;
        }
        if (data.quickCheck(codepoint, .nfd) == .no) {
            self.ok = false;
            return;
        }
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            self.previous_class > current_class)
        {
            self.ok = false;
            return;
        }
        self.previous_class = current_class;
    }

    /// Reset the class after a run of ASCII starters.
    pub inline fn feedAsciiRun(self: *NfdScan) void {
        if (!self.ok) return;
        self.previous_class = 0;
    }
};

/// Append the normalized form of a UTF-16 slice to `output`.
///
/// Returns whether the normalized text differs from the input. The output
/// receives the normalized text in both cases, so callers can reuse one buffer
/// across calls.
pub fn normalizeUtf16Into(
    allocator: std.mem.Allocator,
    units: []const u16,
    form: Form,
    output: *std.ArrayList(u16),
) error{ InvalidUtf16, OutOfMemory }!bool {
    const before = output.items.len;
    const changed = switch (form) {
        inline else => |specialized| normalizeUtf16IntoForm(
            specialized,
            allocator,
            units,
            output,
        ),
    } catch |err| {
        output.shrinkRetainingCapacity(before);
        return err;
    };
    return changed;
}

/// Normalize a UTF-16 slice. Returns null when it is already normalized.
pub fn normalizeUtf16Alloc(
    allocator: std.mem.Allocator,
    units: []const u16,
    form: Form,
) error{ InvalidUtf16, OutOfMemory }!?[]u16 {
    return switch (form) {
        inline else => |specialized| normalizeUtf16AllocForm(
            specialized,
            allocator,
            units,
        ),
    };
}

const Utf16Sink = struct {
    list: *std.ArrayList(u16),
    allocator: std.mem.Allocator,

    fn appendCodepoints(
        self: *Utf16Sink,
        codepoints: []const u21,
    ) error{OutOfMemory}!void {
        const needed = codepoints.len * 2;
        if (self.list.unusedCapacitySlice().len < needed) {
            try self.list.ensureUnusedCapacity(self.allocator, needed);
        }
        for (codepoints) |codepoint| {
            if (codepoint <= 0xFFFF) {
                self.list.appendAssumeCapacity(@intCast(codepoint));
                continue;
            }
            const value = codepoint - 0x10000;
            self.list.appendAssumeCapacity(
                @intCast(0xD800 + (value >> 10)),
            );
            self.list.appendAssumeCapacity(
                @intCast(0xDC00 + (value & 0x3FF)),
            );
        }
    }

    fn appendOne(
        self: *Utf16Sink,
        codepoint: u21,
    ) error{OutOfMemory}!void {
        if (codepoint > 0xFFFF) {
            if (self.list.unusedCapacitySlice().len < 2) {
                try self.list.ensureUnusedCapacity(self.allocator, 2);
            }
            const value = codepoint - 0x10000;
            self.list.appendAssumeCapacity(
                @intCast(0xD800 + (value >> 10)),
            );
            self.list.appendAssumeCapacity(
                @intCast(0xDC00 + (value & 0x3FF)),
            );
            return;
        }
        if (self.list.unusedCapacitySlice().len == 0) {
            try self.list.ensureUnusedCapacity(self.allocator, 1);
        }
        self.list.appendAssumeCapacity(@intCast(codepoint));
    }
};

/// Compose the L jamo `l` with the UTF-16 units after `after_l`.
fn hangulSyllableAt16(
    units: []const u16,
    l: u21,
    after_l: usize,
    end: *usize,
) ?u21 {
    if (after_l >= units.len) return null;
    const v = units[after_l];
    if (v < 0x1161 or v > 0x1175) return null;
    const lv = composeHangul(l, v) orelse return null;
    const after_v = after_l + 1;
    if (after_v < units.len) {
        const t = units[after_v];
        if (t >= 0x11a8 and t <= 0x11c2) {
            if (composeHangulT(lv, t)) |lvt| {
                end.* = after_v + 1;
                return lvt;
            }
        }
    }
    end.* = after_v;
    return lv;
}

/// True when `codepoint` belongs to the preceding starter segment. A scalar
/// with combining class 0 normally starts a new segment, but composition
/// seconds, Hangul V/T jamo, and scalars whose decomposition begins with a
/// mark or jamo (such as the halfwidth voiced-sound mark U+FF9E under the
/// compatibility forms) still belong to the previous starter.
fn continuesSegment(codepoint: u21, compatibility: bool) bool {
    // ASCII scalars are always starters with no decomposition, and this check
    // runs at every segment boundary, where the next scalar is usually ASCII.
    if (codepoint < 0x80) return false;
    // Latin-1 prose hits this check at nearly every segment boundary, so the
    // block is answered from a table built with the same rule. The table also
    // covers U+00B5, whose compatibility decomposition begins in a page that
    // holds composition seconds.
    if (codepoint < 0x100) {
        return latin1_continues_segment[@intFromBool(compatibility)][codepoint - 0x80];
    }
    return continuesSegmentLookup(codepoint, compatibility);
}

/// General `continuesSegment` rule; also builds the Latin-1 table.
fn continuesSegmentLookup(codepoint: u21, compatibility: bool) bool {
    if (combining_class.forCodepoint(codepoint) != 0) return true;
    if (data.isCompositionSecond(codepoint)) return true;
    if (isHangulVOrT(codepoint)) return true;
    if (data.isSimplePage(codepoint, compatibility)) return false;
    const mapping = if (compatibility and codepoint >= 0xff00 and
        codepoint < 0x10000)
        fullwidth_compatibility_decomposition[codepoint - 0xff00]
    else if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    const components = mapping orelse return false;
    const first = components[0];
    return combining_class.forCodepoint(first) != 0 or
        isHangulVOrT(first) or
        data.isCompositionSecond(first);
}

const latin1_continues_segment = blk: {
    @setEvalBranchQuota(200_000);
    var table: [2][0x80]bool = undefined;
    for (0..2) |form_index| {
        const compatibility = form_index == 1;
        for (0x80..0x100) |codepoint| {
            table[form_index][codepoint - 0x80] = continuesSegmentLookup(
                @intCast(codepoint),
                compatibility,
            );
        }
    }
    break :blk table;
};

/// Inline fast path for the segment scans: marks and ASCII dominate segment
/// bodies, and both are answered without the general mapping lookup.
inline fn segmentContinues(codepoint: u21, compatibility: bool) bool {
    if (codepoint < 0x80) return false;
    if (combining_class.forCodepoint(codepoint) != 0) return true;
    return continuesSegment(codepoint, compatibility);
}

/// True when the scalar at `index` begins a new starter segment: the text
/// ends or the next scalar does not continue the current one. Invalid UTF-8
/// reports false so the main scan surfaces the error.
fn nextStartsSegment(
    text: []const u8,
    index: usize,
    compatibility: bool,
) bool {
    if (index >= text.len) return true;
    if (text[index] < 0x80) return true;
    const decoded = scalar.decodeValidatingPacked(text, index);
    if (decoded == scalar.packed_invalid) return false;
    return !continuesSegment(scalar.packedCodepoint(decoded), compatibility);
}

/// UTF-16 counterpart of `nextStartsSegment`.
fn nextStartsSegment16(
    units: []const u16,
    index: usize,
    compatibility: bool,
) bool {
    if (index >= units.len) return true;
    const decoded = utf16.decodePacked(units, index);
    if (decoded == utf16.packed_invalid) return false;
    return !continuesSegment(utf16.packedCodepoint(decoded), compatibility);
}

/// Emit the normalization of a segment that holds exactly one scalar.
/// Recursive decompositions are already canonically ordered, so only the
/// composed forms need a composition pass.
fn emitSingleScalar(
    sink: anytype,
    codepoint: u21,
    comptime compatibility: bool,
    comptime compose: bool,
) error{OutOfMemory}!void {
    var storage: [64]u21 = undefined;
    if (!compose) {
        const count = decomposeInto(&storage, codepoint, compatibility);
        try sink.appendCodepoints(storage[0..count]);
        return;
    }
    var classes: [64]u8 = undefined;
    const count = decomposeInto(&storage, codepoint, compatibility);
    for (storage[0..count], 0..) |part, index| {
        classes[index] = combining_class.forCodepoint(part);
    }
    const final_len = composeSliceWithClasses(
        storage[0..count],
        classes[0..count],
    );
    try sink.appendCodepoints(storage[0..final_len]);
}

/// Normalize one starter segment of UTF-16 units using stack storage.
/// Returns the unit offset just past the segment, or null when the
/// decomposed segment exceeds the stack buffer.
fn normalizeSegmentFastAt16(
    units: []const u16,
    start: usize,
    form: Form,
    sink: *Utf16Sink,
) error{ OutOfMemory, InvalidUtf16 }!?usize {
    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    var storage: [64]u21 = undefined;
    var classes: [64]u8 = undefined;
    var length: usize = 0;
    var index = start;
    var first = true;
    while (index < units.len) {
        const decoded = utf16.decodePacked(units, index);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        const codepoint = utf16.packedCodepoint(decoded);
        const sequence_len = utf16.packedLength(decoded);
        if (!first and !segmentContinues(codepoint, compatibility)) break;
        first = false;
        index += sequence_len;
        if (codepoint < 0x80) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        if (data.isSimplePage(codepoint, compatibility)) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        if (codepoint >= 0x300 and codepoint < mark_decomposition_limit and
            !(if (compatibility)
                mark_has_compatibility_decomposition[codepoint - 0x300]
            else
                mark_has_decomposition[codepoint - 0x300]))
        {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = combining_class.forCodepoint(codepoint);
            length += 1;
            continue;
        }
        var parts: [64]u21 = undefined;
        const count = decomposeInto(&parts, codepoint, compatibility);
        if (length + count > storage.len) return null;
        for (parts[0..count]) |part| {
            storage[length] = part;
            classes[length] = combining_class.forCodepoint(part);
            length += 1;
        }
    }
    canonicalOrderWithClasses(storage[0..length], classes[0..length]);
    const final_len = if (compose)
        composeSliceWithClasses(storage[0..length], classes[0..length])
    else
        length;
    try sink.appendCodepoints(storage[0..final_len]);
    return index;
}

/// Unit offset of the next segment start at or after `index`.
fn segmentEnd16(
    units: []const u16,
    index: usize,
    compatibility: bool,
) error{InvalidUtf16}!usize {
    var cursor = index;
    var first = true;
    while (cursor < units.len) {
        const decoded = utf16.decodePacked(units, cursor);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        const codepoint = utf16.packedCodepoint(decoded);
        if (!first and !segmentContinues(codepoint, compatibility)) {
            return cursor;
        }
        first = false;
        cursor += utf16.packedLength(decoded);
    }
    return units.len;
}

fn normalizeSegmentFallback16(
    allocator: std.mem.Allocator,
    units: []const u16,
    start: usize,
    end: usize,
    form: Form,
    sink: *Utf16Sink,
) error{ OutOfMemory, InvalidUtf16 }!void {
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try codepoints.ensureTotalCapacity(allocator, end - start);
    var cursor = start;
    while (cursor < end) {
        const decoded = utf16.decodePacked(units, cursor);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        codepoints.appendAssumeCapacity(utf16.packedCodepoint(decoded));
        cursor += utf16.packedLength(decoded);
    }
    var normalized = std.ArrayList(u21).empty;
    defer normalized.deinit(allocator);
    try normalizeCodepointsInto(allocator, codepoints.items, form, &normalized);
    try sink.appendCodepoints(normalized.items);
}

/// One past the last UTF-16 unit of the run starting at `start` whose units
/// are all below `limit`. ASCII and Latin-1 prose dominate UTF-16 input, so
/// the scan tests sixteen units per step instead of one.
inline fn unitRunEnd16(
    units: []const u16,
    start: usize,
    comptime limit: u16,
) usize {
    var end = start;
    const bound: @Vector(16, u16) = @splat(limit);
    while (end + 16 <= units.len) {
        const chunk: @Vector(16, u16) = units[end..][0..16].*;
        if (@reduce(.Or, chunk >= bound)) break;
        end += 16;
    }
    while (end < units.len and units[end] < limit) end += 1;
    return end;
}

/// Fused UTF-16 normalizer: the scan mirrors the UTF-8 path but decodes and
/// emits UTF-16 units directly, avoiding a codepoint intermediate.
///
/// Callers may pass a sub-slice that starts at a segment boundary; the state
/// there is empty, so the scan is identical to resuming a full pass.
fn normalizeFusedUtf16Into(
    comptime form: Form,
    allocator: std.mem.Allocator,
    units: []const u16,
    output: *std.ArrayList(u16),
) error{ OutOfMemory, InvalidUtf16 }!bool {
    if (units.len == 0) return false;
    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    const latin1_mode = comptime latin1RunMode(form);
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = comptime jamoRunInert(form);
    var sink = Utf16Sink{ .list = output, .allocator = allocator };
    var stable_start: usize = 0;
    var changed = false;
    var starter: ?u21 = null;
    var starter_offset: usize = 0;
    var previous_input_class: u8 = 0;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit < 0x80 or (latin1_mode != .none and unit < 0x100 and
            (latin1_mode == .all or latin1_mask[unit - 0x80])))
        {
            var end = index;
            if (latin1_mode == .none) {
                while (end < units.len and units[end] < 0x80) end += 1;
            } else if (latin1_mode == .all) {
                end = unitRunEnd16(units, end, 0x100);
            } else {
                while (end < units.len) {
                    const value = units[end];
                    if (value < 0x80 or
                        (value < 0x100 and latin1_mask[value - 0x80]))
                    {
                        end += 1;
                        continue;
                    }
                    break;
                }
            }
            starter = units[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            index = end;
            continue;
        }
        const start = index;
        // A decomposable Latin-1 starter that neither joins the previous
        // segment nor is continued by the next one is emitted directly under
        // the decomposed forms.
        if (!compose and latin1_mode == .some and previous_input_class == 0 and
            unit >= 0x80 and unit < 0x100)
        {
            if (!latin1_mask[unit - 0x80] and
                !continuesSegment(unit, compatibility) and
                nextStartsSegment16(units, index + 1, compatibility))
            {
                if (!changed) {
                    try output.ensureUnusedCapacity(allocator, units.len + 16);
                    changed = true;
                }
                if (index > stable_start) {
                    try output.appendSlice(
                        allocator,
                        units[stable_start..index],
                    );
                }
                var storage: [64]u21 = undefined;
                const count = decomposeInto(
                    &storage,
                    @intCast(unit),
                    compatibility,
                );
                try sink.appendCodepoints(storage[0..count]);
                stable_start = index + 1;
                index += 1;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
        }
        // A fullwidth scalar with a single-component decomposition gets the
        // same treatment under the compatibility forms.
        if (compatibility and previous_input_class == 0 and unit >= 0xff00) {
            if (fullwidth_compatibility_decomposition[unit - 0xff00]) |components| {
                if (components.len == 1 and
                    !continuesSegment(unit, compatibility) and
                    nextStartsSegment16(units, index + 1, compatibility))
                {
                    if (!changed) {
                        try output.ensureUnusedCapacity(
                            allocator,
                            units.len + 16,
                        );
                        changed = true;
                    }
                    if (index > stable_start) {
                        try output.appendSlice(
                            allocator,
                            units[stable_start..index],
                        );
                    }
                    try sink.appendCodepoints(components);
                    stable_start = index + 1;
                    index += 1;
                    starter = null;
                    starter_offset = index;
                    previous_input_class = 0;
                    continue;
                }
            }
        }
        if (jamo_run and unit >= 0x1100 and unit <= 0x11ff) {
            // The decomposed forms leave the jamo block untouched, so a run
            // of it is skipped like ASCII.
            var end = index + 1;
            while (end < units.len and units[end] >= 0x1100 and
                units[end] <= 0x11ff)
            {
                end += 1;
            }
            starter = units[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            index = end;
            continue;
        }
        if (unit >= 0x4e00 and unit <= 0x9fff) {
            var cursor = index + 1;
            while (cursor < units.len and
                units[cursor] >= 0x4e00 and units[cursor] <= 0x9fff)
            {
                cursor += 1;
            }
            starter = null;
            starter_offset = start;
            previous_input_class = 0;
            index = cursor;
            continue;
        }
        if (!compatibility) {
            const inert_punctuation = isInertCjkPunctuation(unit);
            if (inert_punctuation) {
                starter = null;
                starter_offset = start;
                previous_input_class = 0;
                index += 1;
                continue;
            }
        }
        const decoded = utf16.decodePacked(units, index);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        const codepoint = utf16.packedCodepoint(decoded);
        index += utf16.packedLength(decoded);

        if (compose and previous_input_class == 0 and
            codepoint >= hangul_l_base and
            codepoint < hangul_l_base + hangul_l_count)
        {
            var syllable_end: usize = undefined;
            if (hangulSyllableAt16(
                units,
                codepoint,
                index,
                &syllable_end,
            )) |composed| {
                if (!changed) {
                    try output.ensureUnusedCapacity(allocator, units.len + 16);
                    changed = true;
                }
                if (start > stable_start) {
                    try output.appendSlice(
                        allocator,
                        units[stable_start..start],
                    );
                }
                try sink.appendOne(composed);
                index = syllable_end;
                stable_start = index;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
        }

        if (codepoint >= 0x80 and inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        const current_class = combining_class.forCodepoint(codepoint);
        const edit = quick_check == .no or
            (current_class != 0 and previous_input_class > current_class) or
            (quick_check == .maybe and starter != null and
                (previous_input_class == 0 or
                    previous_input_class < current_class) and
                pairChangesUnderForm(starter.?, codepoint, form));
        if (edit) {
            if (!changed) {
                try output.ensureUnusedCapacity(allocator, units.len + 16);
                changed = true;
            }
            // A starter that does not continue the previous segment begins a
            // new one; every unit before it is stable and can be copied
            // verbatim instead of reopening the previous starter's segment.
            const segment_start = if (current_class == 0 and
                previous_input_class == 0 and
                !continuesSegment(codepoint, compatibility))
                start
            else
                starter_offset;
            if (segment_start > stable_start) {
                try output.appendSlice(
                    allocator,
                    units[stable_start..segment_start],
                );
            }
            // A starter that no following scalar continues is its own
            // segment, so it can skip the generic segment machinery.
            if (segment_start == start and
                nextStartsSegment16(units, index, compatibility))
            {
                try emitSingleScalar(
                    &sink,
                    codepoint,
                    compatibility,
                    compose,
                );
                stable_start = index;
                starter = null;
                starter_offset = index;
                previous_input_class = 0;
                continue;
            }
            const end = (try normalizeSegmentFastAt16(
                units,
                segment_start,
                form,
                &sink,
            )) orelse blk: {
                const fallback_end = try segmentEnd16(
                    units,
                    segment_start,
                    compatibility,
                );
                try normalizeSegmentFallback16(
                    allocator,
                    units,
                    segment_start,
                    fallback_end,
                    form,
                    &sink,
                );
                break :blk fallback_end;
            };
            stable_start = end;
            index = end;
            starter = null;
            starter_offset = end;
            previous_input_class = 0;
            continue;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    if (!changed) return false;
    try output.appendSlice(allocator, units[stable_start..]);
    return true;
}

/// True when the first unit begins CJK prose: the kana, CJK punctuation,
/// ideograph, and CJK extension blocks. The quick-check run paths are much
/// cheaper than the fused segment machinery there, while Latin-leading text
/// already stays inside its own run fast paths.
fn cjkLeading(units: []const u16) bool {
    if (units.len == 0) return false;
    const first = units[0];
    return (first >= 0x3000 and first <= 0x30ff) or
        (first >= 0x3400 and first <= 0x9fff);
}

/// Quick-check the slice, then run the fused normalizer from the first
/// unstable segment. Normalized text only pays for the cheap scan and a copy;
/// partially normalized text never rescans its stable prefix.
fn normalizeUtf16IntoForm(
    comptime form: Form,
    allocator: std.mem.Allocator,
    units: []const u16,
    output: *std.ArrayList(u16),
) error{ OutOfMemory, InvalidUtf16 }!bool {
    if (!cjkLeading(units)) {
        const changed = try normalizeFusedUtf16Into(
            form,
            allocator,
            units,
            output,
        );
        if (!changed) try output.appendSlice(allocator, units);
        return changed;
    }
    const restart = (try quickCheckUtf16(units, form)) orelse {
        try output.appendSlice(allocator, units);
        return false;
    };
    try output.appendSlice(allocator, units[0..restart]);
    // The tail starts at a segment boundary, so the fused scan can treat it as
    // a standalone slice and never see the stable prefix.
    if (!try normalizeFusedUtf16Into(form, allocator, units[restart..], output)) {
        // The quick check promised a change; keep the output exact anyway.
        try output.appendSlice(allocator, units[restart..]);
        return false;
    }
    return true;
}

fn normalizeUtf16AllocForm(
    comptime form: Form,
    allocator: std.mem.Allocator,
    units: []const u16,
) error{ OutOfMemory, InvalidUtf16 }!?[]u16 {
    if (!cjkLeading(units)) {
        var output = std.ArrayList(u16).empty;
        errdefer output.deinit(allocator);
        if (!try normalizeFusedUtf16Into(form, allocator, units, &output)) {
            output.deinit(allocator);
            return null;
        }
        return try output.toOwnedSlice(allocator);
    }
    const restart = (try quickCheckUtf16(units, form)) orelse return null;
    var output = std.ArrayList(u16).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, units[0..restart]);
    if (!try normalizeFusedUtf16Into(form, allocator, units[restart..], &output)) {
        output.deinit(allocator);
        return null;
    }
    return try output.toOwnedSlice(allocator);
}

/// Report whether a UTF-16 slice is in `form` without allocating.
pub fn isNormalizedUtf16(
    units: []const u16,
    form: Form,
) error{InvalidUtf16}!bool {
    const latin1_mode = latin1_mode_by_form[@intFromEnum(form)];
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = jamo_run_inert_by_form[@intFromEnum(form)];
    var starter: ?u21 = null;
    var previous_input_class: u8 = 0;
    var cursor: usize = 0;
    while (cursor < units.len) {
        const unit = units[cursor];
        if (unit < 0x80 or (latin1_mode != .none and unit < 0x100 and
            (latin1_mode == .all or latin1_mask[unit - 0x80])))
        {
            var end = cursor;
            if (latin1_mode == .none) {
                while (end < units.len and units[end] < 0x80) end += 1;
            } else if (latin1_mode == .all) {
                end = unitRunEnd16(units, end, 0x100);
            } else {
                while (end < units.len) {
                    const value = units[end];
                    if (value < 0x80 or
                        (value < 0x100 and latin1_mask[value - 0x80]))
                    {
                        end += 1;
                        continue;
                    }
                    break;
                }
            }
            starter = units[end - 1];
            previous_input_class = 0;
            cursor = end;
            continue;
        }
        if (jamo_run and unit >= 0x1100 and unit <= 0x11ff) {
            var end = cursor + 1;
            while (end < units.len and units[end] >= 0x1100 and
                units[end] <= 0x11ff)
            {
                end += 1;
            }
            starter = units[end - 1];
            previous_input_class = 0;
            cursor = end;
            continue;
        }
        // CJK ideographs are simple starters in both canonical forms; the
        // same run fast path keeps the UTF-8 scan out of the tables. Inert
        // punctuation and fullwidth forms between ideographs join the run so
        // mixed Chinese prose stays in one loop.
        if (unit >= 0x4e00 and unit <= 0x9fff) {
            const canonical = form == .nfc or form == .nfd;
            cursor += 1;
            while (cursor < units.len) {
                const value = units[cursor];
                if (value >= 0x4e00 and value <= 0x9fff) {
                    cursor += 1;
                    continue;
                }
                if (canonical and
                    ((value >= 0x3000 and value <= 0x303f and
                        (value < 0x302a or value > 0x302f)) or
                        (value >= 0xff00 and value <= 0xffef)))
                {
                    cursor += 1;
                    continue;
                }
                break;
            }
            starter = null;
            previous_input_class = 0;
            continue;
        }
        const decoded = utf16.decodePacked(units, cursor);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        const codepoint = utf16.packedCodepoint(decoded);
        cursor += utf16.packedLength(decoded);
        if (inert.isInert(codepoint, form)) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) {
            return invalidSuffixOrFalse(units, cursor);
        }
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class)
        {
            return invalidSuffixOrFalse(units, cursor);
        }
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return invalidSuffixOrFalse(units, cursor);
        }
        if (current_class == 0) starter = codepoint;
        previous_input_class = current_class;
    }
    return true;
}

/// Report "not normalized" after checking that the unscanned UTF-16 suffix is
/// still valid, preserving the API's InvalidUtf16 contract.
inline fn invalidSuffixOrFalse(
    units: []const u16,
    index: usize,
) error{InvalidUtf16}!bool {
    if (!utf16.validate(units[index..])) return error.InvalidUtf16;
    return false;
}

/// Scan UTF-16 units for the first scalar that `form` would change.
///
/// Returns the unit offset of the segment a fused normalizer must reopen, or
/// null when the text is already normalized. Resuming at that segment start
/// with empty state reproduces the state of a full scan, so the stable prefix
/// is never scanned twice. The scan mirrors `normalizeFusedUtf16Into`, plus a
/// kana run for the composed forms, which keeps kana prose out of the tables.
fn quickCheckUtf16(
    units: []const u16,
    form: Form,
) error{InvalidUtf16}!?usize {
    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    const canonical = form == .nfc or form == .nfd;
    // U+30FF is inert under the canonical forms only.
    const kana_hi: u16 = if (compatibility) 0x30fe else 0x30ff;
    const latin1_mode = latin1_mode_by_form[@intFromEnum(form)];
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = jamo_run_inert_by_form[@intFromEnum(form)];
    var starter: ?u21 = null;
    var starter_offset: usize = 0;
    var previous_input_class: u8 = 0;
    var cursor: usize = 0;
    while (cursor < units.len) {
        const unit = units[cursor];
        if (unit < 0x80 or (latin1_mode != .none and unit < 0x100 and
            (latin1_mode == .all or latin1_mask[unit - 0x80])))
        {
            var end = cursor;
            if (latin1_mode == .none) {
                while (end < units.len and units[end] < 0x80) end += 1;
            } else if (latin1_mode == .all) {
                while (end < units.len and units[end] < 0x100) end += 1;
            } else {
                while (end < units.len) {
                    const value = units[end];
                    if (value < 0x80 or
                        (value < 0x100 and latin1_mask[value - 0x80]))
                    {
                        end += 1;
                        continue;
                    }
                    break;
                }
            }
            starter = units[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            cursor = end;
            continue;
        }
        if (jamo_run and unit >= 0x1100 and unit <= 0x11ff) {
            var end = cursor + 1;
            while (end < units.len and units[end] >= 0x1100 and
                units[end] <= 0x11ff)
            {
                end += 1;
            }
            starter = units[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            cursor = end;
            continue;
        }
        // CJK ideographs are simple starters in both canonical forms. Inert
        // punctuation and fullwidth forms between ideographs join the run so
        // mixed Chinese prose stays in one loop.
        if (unit >= 0x4e00 and unit <= 0x9fff) {
            const run_start = cursor;
            cursor += 1;
            while (cursor < units.len) {
                const value = units[cursor];
                if (value >= 0x4e00 and value <= 0x9fff) {
                    cursor += 1;
                    continue;
                }
                if (canonical and
                    ((value >= 0x3000 and value <= 0x303f and
                        (value < 0x302a or value > 0x302f)) or
                        (value >= 0xff00 and value <= 0xffef)))
                {
                    cursor += 1;
                    continue;
                }
                break;
            }
            starter = null;
            starter_offset = run_start;
            previous_input_class = 0;
            continue;
        }
        // Kana are inert starters under the composed forms, so a run of them
        // is skipped like the Han block. Unlike ideographs they can compose
        // with a following voiced sound mark, so the last unit stays the
        // starter. U+3094..U+309F holds the marks and digraphs that break the
        // run; the compatibility forms also decompose U+30FF.
        if (compose and ((unit >= 0x3040 and unit <= 0x3093) or
            (unit >= 0x30a0 and unit <= kana_hi)))
        {
            var end = cursor + 1;
            while (end < units.len) {
                const value = units[end];
                if (!((value >= 0x3040 and value <= 0x3093) or
                    (value >= 0x30a0 and value <= kana_hi))) break;
                end += 1;
            }
            starter = units[end - 1];
            starter_offset = end - 1;
            previous_input_class = 0;
            cursor = end;
            continue;
        }
        // CJK punctuation and fullwidth forms are inert under the canonical
        // forms and start no composition pair, matching the fused scan.
        if (!compatibility and isInertCjkPunctuation(unit)) {
            starter = null;
            starter_offset = cursor;
            previous_input_class = 0;
            cursor += 1;
            continue;
        }
        // A leading jamo that composes with the next unit is a change at the
        // jamo itself; answering it here keeps jamo runs out of the general
        // pair test.
        if (compose and previous_input_class == 0 and
            unit >= hangul_l_base and unit < hangul_l_base + hangul_l_count)
        {
            var syllable_end: usize = undefined;
            if (hangulSyllableAt16(units, unit, cursor + 1, &syllable_end) != null) {
                return cursor;
            }
        }
        const start = cursor;
        const decoded = utf16.decodePacked(units, cursor);
        if (decoded == utf16.packed_invalid) return error.InvalidUtf16;
        const codepoint = utf16.packedCodepoint(decoded);
        cursor += utf16.packedLength(decoded);
        if (inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        const current_class = combining_class.forCodepoint(codepoint);
        const change = quick_check == .no or
            (current_class != 0 and previous_input_class > current_class) or
            (quick_check == .maybe and starter != null and
                (previous_input_class == 0 or
                    previous_input_class < current_class) and
                pairChangesUnderForm(starter.?, codepoint, form));
        if (change) {
            return if (current_class == 0 and previous_input_class == 0 and
                !continuesSegment(codepoint, compatibility))
                start
            else
                starter_offset;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    return null;
}

/// Incremental normalizer for chunked UTF-8 input.
///
/// Each `feed` chunk must be valid UTF-8 and end on a code-point boundary. The
/// normalizer holds only the unstable suffix (one starter, its marks, and any
/// Hangul composition chain), so memory does not grow with the total input.
pub const Normalizer = struct {
    allocator: std.mem.Allocator,
    form: Form,
    pending: std.ArrayList(u21),
    normalized: std.ArrayList(u21),

    pub fn init(allocator: std.mem.Allocator, form: Form) Normalizer {
        return .{
            .allocator = allocator,
            .form = form,
            .pending = .empty,
            .normalized = .empty,
        };
    }

    pub fn deinit(self: *Normalizer) void {
        self.pending.deinit(self.allocator);
        self.normalized.deinit(self.allocator);
    }

    pub fn feed(
        self: *Normalizer,
        text: []const u8,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            try self.process(codepoint, output);
        }
    }

    pub fn finish(self: *Normalizer, output: *std.ArrayList(u8)) Error!void {
        try self.flush(output);
    }

    fn process(
        self: *Normalizer,
        codepoint: u21,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (self.pending.items.len == 0 or
            continuesSegment(
                codepoint,
                self.form == .nfkc or self.form == .nfkd,
            ))
        {
            try self.pending.append(self.allocator, codepoint);
            return;
        }

        if ((self.form == .nfd or self.form == .nfkd) or
            !self.pendingCanComposeWith(codepoint))
        {
            try self.flush(output);
        }
        try self.pending.append(self.allocator, codepoint);
    }

    fn pendingCanComposeWith(self: *Normalizer, codepoint: u21) bool {
        if (self.form == .nfd or self.form == .nfkd) return false;

        var base: ?u21 = null;
        for (self.pending.items) |item| {
            if (combining_class.forCodepoint(item) != 0) continue;
            if (base == null) {
                base = item;
            } else if (composeHangul(base.?, item)) |composed| {
                base = composed;
            } else {
                base = item;
            }
        }
        if (base == null) return false;
        return composeHangul(base.?, codepoint) != null;
    }

    fn flush(
        self: *Normalizer,
        output: *std.ArrayList(u8),
    ) Error!void {
        if (self.pending.items.len == 0) return;

        self.normalized.clearRetainingCapacity();
        try normalizeCodepointsInto(
            self.allocator,
            self.pending.items,
            self.form,
            &self.normalized,
        );

        var encoded: [4]u8 = undefined;
        try output.ensureUnusedCapacity(
            self.allocator,
            self.normalized.items.len * 4,
        );
        for (self.normalized.items) |codepoint| {
            const len = scalar.encodeUtf8(&encoded, codepoint);
            try output.appendSlice(self.allocator, encoded[0..len]);
        }
        self.pending.clearRetainingCapacity();
    }
};

fn normalizeSegmentInto(
    engine: *SegmentEngine(Utf8Sink),
    text: []const u8,
) Error!void {
    var index: usize = 0;
    while (index < text.len) {
        // Bulk-copy ASCII runs; the final byte stays pending in case a
        // combining mark follows.
        const run_start = index;
        while (index < text.len and text[index] < 0x80) index += 1;
        if (index > run_start) {
            try engine.settle();
            const run = text[run_start..index];
            if (run.len > 1) {
                try engine.sink.appendAsciiBytes(run[0 .. run.len - 1]);
            }
            engine.pending = run[run.len - 1];
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        index += scalar.packedLength(decoded);
        try engine.feed(scalar.packedCodepoint(decoded));
    }
    try engine.flush();
}

/// Normalize one starter segment using stack storage. Returns false when the
/// decomposed segment exceeds the stack buffer, so the caller can fall back to
/// the incremental engine.
/// Normalize the starter segment beginning at `start` using stack storage,
/// decoding the segment once. Returns the byte offset just past the segment,
/// or null when the decomposed segment exceeds the stack buffer.
fn normalizeSegmentFastAt(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
    form: Form,
    output: *std.ArrayList(u8),
) Error!?usize {
    const compatibility = form == .nfkc or form == .nfkd;
    const compose = form == .nfc or form == .nfkc;
    var storage: [64]u21 = undefined;
    var classes: [64]u8 = undefined;
    var length: usize = 0;
    var index = start;
    var first = true;
    while (index < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) return error.InvalidUtf8;
        const codepoint = scalar.packedCodepoint(decoded);
        const sequence_len = scalar.packedLength(decoded);
        if (!first and !segmentContinues(codepoint, compatibility)) break;
        first = false;
        index += sequence_len;
        if (codepoint < 0x80) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        if (data.isSimplePage(codepoint, compatibility)) {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = 0;
            length += 1;
            continue;
        }
        // Combining Diacritical Marks are the dominant decomposition input
        // for accent-heavy text, and almost all of them are their own
        // decomposition. Copying them directly avoids the out-of-line
        // decompose call and its stack parts array.
        if (codepoint >= 0x300 and codepoint < mark_decomposition_limit and
            !(if (compatibility)
                mark_has_compatibility_decomposition[codepoint - 0x300]
            else
                mark_has_decomposition[codepoint - 0x300]))
        {
            if (length == storage.len) return null;
            storage[length] = codepoint;
            classes[length] = combining_class.forCodepoint(codepoint);
            length += 1;
            continue;
        }
        var parts: [64]u21 = undefined;
        const count = decomposeInto(&parts, codepoint, compatibility);
        if (length + count > storage.len) return null;
        for (parts[0..count]) |part| {
            storage[length] = part;
            classes[length] = combining_class.forCodepoint(part);
            length += 1;
        }
    }
    canonicalOrderWithClasses(storage[0..length], classes[0..length]);
    const final_len = if (compose)
        composeSliceWithClasses(storage[0..length], classes[0..length])
    else
        length;
    // Size the reservation by the encoded length, not four bytes per scalar:
    // an over-request on a small edit forces a grow here and then a shrink
    // copy in toOwnedSlice. When four bytes per scalar already fit, the exact
    // count cannot change the reservation, so skip the extra pass.
    if (output.unusedCapacitySlice().len < final_len * 4) {
        var needed: usize = 0;
        for (storage[0..final_len]) |codepoint| {
            needed += if (codepoint < 0x80)
                1
            else if (codepoint < 0x800)
                2
            else if (codepoint < 0x10000)
                3
            else
                4;
        }
        if (output.unusedCapacitySlice().len < needed) {
            try output.ensureTotalCapacityPrecise(
                allocator,
                output.items.len + needed,
            );
        }
    }
    const dest = output.unusedCapacitySlice();
    var written: usize = 0;
    for (storage[0..final_len]) |codepoint| {
        written += encodeScalarInto(dest, written, codepoint);
    }
    output.items.len += written;
    return index;
}

fn normalizeChangedFormInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!void {
    // Reserve the input size once; decomposition may grow the output but
    // rarely reallocates more than once.
    try output.ensureUnusedCapacity(allocator, text.len + 16);
    var engine = SegmentEngine(Utf8Sink){
        .allocator = allocator,
        .sink = .{ .list = output, .allocator = allocator },
        .form = form,
        .compatibility = form == .nfkc or form == .nfkd,
        .compose = form == .nfc or form == .nfkc,
    };
    defer engine.deinit();
    try normalizeSegmentInto(&engine, text);
}

/// Normalize `text`, copying stable spans verbatim and running the segment
/// engine only on the spans that can change. `text` must be valid UTF-8.
fn normalizeWithEditsInto(
    allocator: std.mem.Allocator,
    text: []const u8,
    form: Form,
    output: *std.ArrayList(u8),
) Error!void {
    // Reserve once for the common case so the per-segment reservations do
    // not each grow the list.
    try output.ensureUnusedCapacity(allocator, text.len + 16);
    var position: usize = 0;
    while (position < text.len) {
        const span = spanQuickCheckYesUnchecked(text[position..], form);
        if (span > 0) {
            try output.appendSlice(
                allocator,
                text[position..][0..span],
            );
            position += span;
            if (position == text.len) break;
        }
        const end = segmentEnd(
            text,
            position,
            form == .nfkc or form == .nfkd,
        );
        try normalizeChangedFormInto(
            allocator,
            text[position..end],
            form,
            output,
        );
        position = end;
    }
}

/// Validate UTF-8 and report whether `text` is in NFC without allocating.
pub fn isNormalized(text: []const u8) error{InvalidUtf8}!bool {
    return isNormalizedForm(text, .nfc);
}

/// Validate UTF-8 and report whether `text` is in `form` without allocating.
pub fn isNormalizedForm(text: []const u8, form: Form) error{InvalidUtf8}!bool {
    // The scan validates every scalar it visits. A true result therefore
    // proves the whole string is valid and no second pass is needed. A false
    // result may short-circuit before later invalid bytes, so validate only
    // the unscanned suffix before reporting "not normalized".
    const result = isNormalizedFormScan(text, form);
    if (result.normalized) return true;
    if (!scalar.validate.isValid(text[result.valid_until..])) {
        return error.InvalidUtf8;
    }
    return false;
}

/// Report whether prevalidated UTF-8 is in NFC without allocating.
pub fn isNormalizedAssumeValid(text: []const u8) bool {
    return isNormalizedFormAssumeValid(text, .nfc);
}

/// Report whether prevalidated UTF-8 is in `form` without allocating.
pub fn isNormalizedFormAssumeValid(text: []const u8, form: Form) bool {
    scalar.assertValidUtf8(text);
    return isNormalizedFormUnchecked(text, form);
}

const ScanResult = struct {
    normalized: bool,
    /// Byte offset through which the scan validated UTF-8. Bytes before this
    /// offset are valid even when `normalized` is false.
    valid_until: usize,
};

fn isNormalizedFormScan(text: []const u8, form: Form) ScanResult {
    // ASCII is Quick_Check=Yes with Canonical_Combining_Class=0 in every
    // normalization form, so a pure-ASCII prefix cannot affect the state
    // machine. Skipping it turns the common prose case into a byte scan.
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) {
        return .{ .normalized = true, .valid_until = text.len };
    }

    const latin1_mode = latin1_mode_by_form[@intFromEnum(form)];
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = jamo_run_inert_by_form[@intFromEnum(form)];
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80 or
            (latin1_mode != .none and
                (text[index] == 0xc2 or text[index] == 0xc3) and
                index + 1 < text.len and (text[index + 1] & 0xc0) == 0x80))
        {
            const run = switch (latin1_mode) {
                .none => scanAsciiLatin1Run(text, index, .none, latin1_mask),
                .all => scanAsciiLatin1Run(text, index, .all, latin1_mask),
                .some => scanAsciiLatin1Run(text, index, .some, latin1_mask),
            };
            if (run.end > index) {
                starter = run.last_codepoint;
                previous_input_class = 0;
                index = run.end;
                continue;
            }
        }
        const start = index;
        if (jamo_run and text[index] == 0xe1 and index + 2 < text.len and
            (text[index + 1] & 0xfc) == 0x84 and
            (text[index + 2] & 0xc0) == 0x80)
        {
            var end = index;
            while (end + 2 < text.len and text[end] == 0xe1 and
                (text[end + 1] & 0xfc) == 0x84 and
                (text[end + 2] & 0xc0) == 0x80)
            {
                end += 3;
            }
            starter = (@as(u21, text[end - 3] & 0x0f) << 12) |
                (@as(u21, text[end - 2] & 0x3f) << 6) |
                (text[end - 1] & 0x3f);
            previous_input_class = 0;
            index = end;
            continue;
        }
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            const canonical = form == .nfc or form == .nfd;
            var cursor = index;
            while (true) {
                while (cursor + 6 <= text.len and
                    text[cursor] >= 0xe4 and text[cursor] <= 0xe9 and
                    text[cursor + 3] >= 0xe4 and text[cursor + 3] <= 0xe9 and
                    ((text[cursor + 1] | text[cursor + 2] |
                        text[cursor + 4] | text[cursor + 5]) & 0xc0) == 0x80)
                {
                    cursor += 6;
                }
                if (cursor < text.len and text[cursor] >= 0xe4 and
                    text[cursor] <= 0xe9)
                {
                    if (cursor + 3 > text.len or
                        text[cursor + 1] & 0xc0 != 0x80 or
                        text[cursor + 2] & 0xc0 != 0x80)
                    {
                        return .{ .normalized = false, .valid_until = cursor };
                    }
                    cursor += 3;
                    continue;
                }
                // Inert CJK punctuation and fullwidth forms between
                // ideographs join the run.
                if (canonical and cursor + 3 <= text.len and
                    (text[cursor] | 0x0c) == 0xef)
                {
                    const second = text[cursor + 1];
                    const third = text[cursor + 2];
                    if ((text[cursor] == 0xe3 and second == 0x80 and
                        (third < 0xaa or third > 0xaf)) or
                        (text[cursor] == 0xef and second == 0xbc))
                    {
                        if (third & 0xc0 != 0x80) {
                            return .{
                                .normalized = false,
                                .valid_until = cursor,
                            };
                        }
                        cursor += 3;
                        continue;
                    }
                }
                break;
            }
            starter = null;
            previous_input_class = 0;
            index = cursor;
            continue;
        }
        // CJK punctuation and fullwidth forms are inert under the canonical
        // forms, so the scan skips them without a decoder or table probe,
        // matching the fused normalizer's fast path.
        if (form == .nfc or form == .nfd) {
            const lead = text[index];
            if ((lead | 0x0c) == 0xef and index + 3 <= text.len) {
                const second = text[index + 1];
                const third = text[index + 2];
                if ((lead == 0xe3 and second == 0x80 and
                    (third < 0xaa or third > 0xaf)) or
                    (lead == 0xef and second == 0xbc))
                {
                    if (third & 0xc0 != 0x80) {
                        return .{ .normalized = false, .valid_until = start };
                    }
                    starter = null;
                    previous_input_class = 0;
                    index += 3;
                    continue;
                }
            }
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) {
            return .{ .normalized = false, .valid_until = start };
        }
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        if (inert.isInert(codepoint, form)) {
            starter = codepoint;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) {
            return .{ .normalized = false, .valid_until = start };
        }
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and previous_input_class > current_class) {
            return .{ .normalized = false, .valid_until = start };
        }
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return .{ .normalized = false, .valid_until = start };
        }
        if (current_class == 0) starter = codepoint;
        previous_input_class = current_class;
    }
    return .{ .normalized = true, .valid_until = text.len };
}

fn isNormalizedFormUnchecked(text: []const u8, form: Form) bool {
    return isNormalizedFormScan(text, form).normalized;
}

/// Return the length of the longest prefix that is definitely normalized.
///
/// The result is a safe byte offset at or before the first scalar that can
/// change under `form`, or `text.len` when the whole string is normalized.
/// When a combining mark could compose with or reorder against the preceding
/// starter, the offset of that starter is returned so the caller can
/// normalize the suffix independently.
pub fn spanQuickCheckYes(
    text: []const u8,
    form: Form,
) error{InvalidUtf8}!usize {
    const span = try spanQuickCheckYesImpl(true, text, form);
    // A full-length span proves the scan visited every scalar. Otherwise the
    // scan stopped at the first change and the suffix is still unvalidated.
    if (span == text.len) return span;
    if (!scalar.validate.isValid(text)) return error.InvalidUtf8;
    return span;
}

fn spanQuickCheckYesUnchecked(text: []const u8, form: Form) usize {
    return spanQuickCheckYesImpl(false, text, form);
}

fn spanQuickCheckYesImpl(
    comptime validating: bool,
    text: []const u8,
    form: Form,
) if (validating) error{InvalidUtf8}!usize else usize {
    const ascii_end = asciiPrefixLen(text);
    if (ascii_end == text.len) return text.len;

    const latin1_mode = latin1_mode_by_form[@intFromEnum(form)];
    const latin1_mask = &latin1_inert_by_form[@intFromEnum(form)];
    const jamo_run = jamo_run_inert_by_form[@intFromEnum(form)];
    var starter_offset: usize = if (ascii_end > 0) ascii_end - 1 else 0;
    var starter: ?u21 = if (ascii_end > 0) text[ascii_end - 1] else null;
    var previous_input_class: u8 = 0;
    var index: usize = ascii_end;
    while (index < text.len) {
        if (text[index] < 0x80 or
            (latin1_mode != .none and
                (text[index] == 0xc2 or text[index] == 0xc3) and
                index + 1 < text.len and (text[index + 1] & 0xc0) == 0x80))
        {
            const run = switch (latin1_mode) {
                .none => scanAsciiLatin1Run(text, index, .none, latin1_mask),
                .all => scanAsciiLatin1Run(text, index, .all, latin1_mask),
                .some => scanAsciiLatin1Run(text, index, .some, latin1_mask),
            };
            if (run.end > index) {
                starter = run.last_codepoint;
                starter_offset = run.last_offset;
                previous_input_class = 0;
                index = run.end;
                continue;
            }
        }
        const start = index;
        if (jamo_run and text[index] == 0xe1 and index + 2 < text.len and
            (text[index + 1] & 0xfc) == 0x84 and
            (text[index + 2] & 0xc0) == 0x80)
        {
            var end = index;
            while (end + 2 < text.len and text[end] == 0xe1 and
                (text[end + 1] & 0xfc) == 0x84 and
                (text[end + 2] & 0xc0) == 0x80)
            {
                end += 3;
            }
            starter = (@as(u21, text[end - 3] & 0x0f) << 12) |
                (@as(u21, text[end - 2] & 0x3f) << 6) |
                (text[end - 1] & 0x3f);
            previous_input_class = 0;
            index = end;
            continue;
        }
        if (cjk_lead_simple and text[index] >= 0xe4 and
            text[index] <= 0xe9)
        {
            var cursor = index;
            while (cursor + 6 <= text.len and
                text[cursor] >= 0xe4 and text[cursor] <= 0xe9 and
                text[cursor + 3] >= 0xe4 and text[cursor + 3] <= 0xe9 and
                ((text[cursor + 1] | text[cursor + 2] |
                    text[cursor + 4] | text[cursor + 5]) & 0xc0) == 0x80)
            {
                cursor += 6;
            }
            if (cursor < text.len and text[cursor] >= 0xe4 and
                text[cursor] <= 0xe9)
            {
                if (cursor + 3 > text.len or
                    text[cursor + 1] & 0xc0 != 0x80 or
                    text[cursor + 2] & 0xc0 != 0x80)
                {
                    if (validating) return error.InvalidUtf8;
                    return text.len;
                }
                cursor += 3;
            }
            starter = null;
            starter_offset = start;
            previous_input_class = 0;
            index = cursor;
            continue;
        }
        const decoded = scalar.decodeValidatingPacked(text, index);
        if (decoded == scalar.packed_invalid) {
            if (validating) return error.InvalidUtf8;
            return text.len;
        }
        const codepoint = scalar.packedCodepoint(decoded);
        index += scalar.packedLength(decoded);
        if (codepoint >= 0x80 and inert.isInert(codepoint, form)) {
            starter = codepoint;
            starter_offset = start;
            previous_input_class = 0;
            continue;
        }
        const quick_check = data.quickCheck(codepoint, form);
        if (quick_check == .no) return starter_offset;
        const current_class = combining_class.forCodepoint(codepoint);
        if (current_class != 0 and
            previous_input_class > current_class) return starter_offset;
        if (quick_check == .maybe and starter != null and
            (previous_input_class == 0 or
                previous_input_class < current_class) and
            pairChangesUnderForm(starter.?, codepoint, form))
        {
            return starter_offset;
        }
        if (current_class == 0) {
            starter = codepoint;
            starter_offset = start;
        }
        previous_input_class = current_class;
    }
    return text.len;
}

/// Return the byte offset of the next segment start at or after `index`.
/// A segment starts at a starter that cannot compose with or reorder
/// against the preceding character; normalizing `[index, result)` in
/// isolation is safe.
fn segmentEnd(
    text: []const u8,
    index: usize,
    compatibility: bool,
) usize {
    var cursor = index;
    var first = true;
    while (cursor < text.len) {
        const decoded = scalar.decodeValidatingPacked(text, cursor);
        if (decoded == scalar.packed_invalid) return text.len;
        const codepoint = scalar.packedCodepoint(decoded);
        const length = scalar.packedLength(decoded);
        if (!first and !segmentContinues(codepoint, compatibility)) {
            return cursor;
        }
        first = false;
        cursor += length;
    }
    return text.len;
}

/// End offset of the ASCII run that starts at `start`.
fn asciiRunEnd(text: []const u8, start: usize) usize {
    const high_bits: u64 = 0x8080_8080_8080_8080;
    var index = start;
    while (index + 8 <= text.len) : (index += 8) {
        const word = std.mem.readInt(u64, text[index..][0..8], .little);
        if (word & high_bits != 0) break;
    }
    while (index < text.len and text[index] < 0x80) : (index += 1) {}
    return index;
}

fn asciiPrefixLen(text: []const u8) usize {
    return asciiRunEnd(text, 0);
}

fn appendDecomposition(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u21),
    codepoint: u21,
    compatibility: bool,
) error{OutOfMemory}!void {
    if (codepoint < 0x80) {
        try output.append(allocator, codepoint);
        return;
    }
    if (decomposeHangul(codepoint)) |parts| {
        try output.appendSlice(allocator, parts.slice());
        return;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        try output.appendSlice(allocator, components);
        return;
    }
    try output.append(allocator, codepoint);
}

/// Canonical ordering with precomputed combining classes.
fn canonicalOrderWithClasses(codepoints: []u21, classes: []u8) void {
    std.debug.assert(codepoints.len == classes.len);
    var sequence_start: usize = 0;
    for (classes, 0..) |class, index| {
        if (class == 0) {
            sortMarksWithClasses(
                codepoints[sequence_start..index],
                classes[sequence_start..index],
            );
            sequence_start = index + 1;
        }
    }
    sortMarksWithClasses(
        codepoints[sequence_start..],
        classes[sequence_start..],
    );
}

fn sortMarksWithClasses(codepoints: []u21, classes: []u8) void {
    var index: usize = 1;
    while (index < codepoints.len) : (index += 1) {
        const codepoint = codepoints[index];
        const class = classes[index];
        var move = index;
        while (move > 0 and classes[move - 1] > class) : (move -= 1) {
            codepoints[move] = codepoints[move - 1];
            classes[move] = classes[move - 1];
        }
        codepoints[move] = codepoint;
        classes[move] = class;
    }
}

/// Composition using precomputed combining classes.
fn composeSliceWithClasses(items: []u21, classes: []const u8) usize {
    std.debug.assert(items.len == classes.len);
    if (items.len < 2) return items.len;
    var output_len: usize = 1;
    var starter_index: usize = 0;
    var starter = items[0];
    var previous_class: u8 = 0;
    for (items[1..], classes[1..]) |codepoint, class| {
        const composite = if ((data.isCompositionSecond(codepoint) or
            isHangulVOrT(codepoint)) and
            (previous_class == 0 or previous_class < class))
            composePair(starter, codepoint)
        else
            null;
        if (composite) |value| {
            items[starter_index] = value;
            starter = value;
            continue;
        }
        items[output_len] = codepoint;
        if (class == 0) {
            starter_index = output_len;
            starter = codepoint;
        }
        previous_class = class;
        output_len += 1;
    }
    return output_len;
}

/// Sort the marks of every starter segment into canonical order.
pub fn canonicalOrder(codepoints: []u21) void {
    var sequence_start: usize = 0;
    for (codepoints, 0..) |codepoint, index| {
        if (combining_class.forCodepoint(codepoint) == 0) {
            stableSortMarks(codepoints[sequence_start..index]);
            sequence_start = index + 1;
        }
    }
    stableSortMarks(codepoints[sequence_start..]);
}

fn stableSortMarks(codepoints: []u21) void {
    std.sort.insertion(u21, codepoints, {}, struct {
        fn lessThan(_: void, lhs: u21, rhs: u21) bool {
            return combining_class.forCodepoint(lhs) <
                combining_class.forCodepoint(rhs);
        }
    }.lessThan);
}

fn composeSlice(items: []u21) usize {
    if (items.len < 2) return items.len;
    var output_len: usize = 1;
    var starter_index: usize = 0;
    var starter = items[0];
    var previous_class: u8 = 0;

    for (items[1..]) |codepoint| {
        const current_class = combining_class.forCodepoint(codepoint);
        // A starter only composes with a following non-starter mark or a
        // Hangul V/T jamo. Skipping the table lookup for ordinary starters
        // keeps ASCII prose on a linear scan.
        const composite = if ((data.isCompositionSecond(codepoint) or
            isHangulVOrT(codepoint)) and
            (previous_class == 0 or previous_class < current_class))
            composePair(starter, codepoint)
        else
            null;
        if (composite) |value| {
            items[starter_index] = value;
            starter = value;
            continue;
        }

        items[output_len] = codepoint;
        if (current_class == 0) {
            starter_index = output_len;
            starter = codepoint;
        }
        previous_class = current_class;
        output_len += 1;
    }
    return output_len;
}

fn pairChangesUnderForm(starter: u21, current: u21, form: Form) bool {
    if (form == .nfc or form == .nfkc) {
        // A direct composition always changes the pair; this avoids the
        // general decompose-order-compose path for the common composing-mark
        // case.
        if (composePair(starter, current) != null) return true;
        // When neither scalar decomposes the ordered pair is simply
        // [starter, current], so the direct composition check above already
        // answered. Hangul syllables decompose algorithmically, but their
        // only pair compositions are L+V/T, which `composePair` covers.
        if (!decomposition.hasCanonical(starter) and
            !decomposition.hasCanonical(current))
        {
            return false;
        }
    }
    // Unicode 17's longest recursive compatibility decomposition has 18
    // components; 64 leaves room for both the starter and the current scalar.
    // A Maybe scalar only needs the current starter: any intervening input
    // mark either blocks it or has a lower combining class.
    var storage: [64]u21 = undefined;
    var len: usize = 0;
    const compatibility = form == .nfkc or form == .nfkd;
    appendDecompositionFixed(&storage, &len, starter, compatibility);
    appendDecompositionFixed(&storage, &len, current, compatibility);
    canonicalOrder(storage[0..len]);
    const normalized_len = if (form == .nfc or form == .nfkc)
        composeSlice(storage[0..len])
    else
        len;
    return normalized_len != 2 or storage[0] != starter or
        storage[1] != current;
}

fn appendDecompositionFixed(
    output: *[64]u21,
    len: *usize,
    codepoint: u21,
    compatibility: bool,
) void {
    if (decomposeHangul(codepoint)) |parts| {
        std.debug.assert(len.* + parts.len <= output.len);
        for (parts.slice()) |component| {
            output[len.*] = component;
            len.* += 1;
        }
        return;
    }
    const mapping = if (compatibility)
        decomposition.compatibilityForCodepoint(codepoint)
    else
        decomposition.forCodepoint(codepoint);
    if (mapping) |components| {
        std.debug.assert(len.* + components.len <= output.len);
        for (components) |component| {
            output[len.*] = component;
            len.* += 1;
        }
        return;
    }
    output[len.*] = codepoint;
    len.* += 1;
}

fn isHangulVOrT(codepoint: u21) bool {
    return (codepoint >= 0x1161 and codepoint <= 0x1175) or
        (codepoint >= 0x11a8 and codepoint <= 0x11c2);
}

/// Direct composition results for Latin-1 starters, which dominate
/// precomposed Latin text. Every canonical pair with a starter below U+0100
/// uses a combining mark in U+0300..U+0342, so a small table replaces the
/// generated page-indexed binary search in the hottest composition path.
const latin_compose_first_mark: u21 = 0x300;
const latin_compose_mark_count: usize = 0x43;

const latin_compose: [0x100][latin_compose_mark_count]u16 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [0x100][latin_compose_mark_count]u16 =
        [_][latin_compose_mark_count]u16{
            [_]u16{0} ** latin_compose_mark_count,
        } ** 0x100;
    for (0..0x100) |starter| {
        for (0..latin_compose_mark_count) |mark_index| {
            const combining = latin_compose_first_mark + mark_index;
            if (data.composePair(@intCast(starter), @intCast(combining))) |composed| {
                table[starter][mark_index] = @intCast(composed);
            }
        }
    }
    break :blk table;
};

pub inline fn composePair(starter: u21, combining: u21) ?u21 {
    if (starter < 0x100 and combining >= latin_compose_first_mark and
        combining < latin_compose_first_mark + latin_compose_mark_count)
    {
        const composed = latin_compose[starter][combining - latin_compose_first_mark];
        return if (composed == 0) null else composed;
    }
    return composeHangul(starter, combining) orelse
        data.composePair(starter, combining);
}

const hangul_s_base: u21 = 0xac00;
const hangul_l_base: u21 = 0x1100;
const hangul_v_base: u21 = 0x1161;
const hangul_t_base: u21 = 0x11a7;
const hangul_l_count: u21 = 19;
const hangul_v_count: u21 = 21;
const hangul_t_count: u21 = 28;
const hangul_n_count: u21 = hangul_v_count * hangul_t_count;
const hangul_s_count: u21 = hangul_l_count * hangul_n_count;

const HangulDecomposition = struct {
    values: [3]u21,
    len: usize,

    fn slice(self: *const HangulDecomposition) []const u21 {
        return self.values[0..self.len];
    }
};

fn decomposeHangul(codepoint: u21) ?HangulDecomposition {
    if (codepoint < hangul_s_base or
        codepoint >= hangul_s_base + hangul_s_count) return null;
    const index = codepoint - hangul_s_base;
    const l = hangul_l_base + index / hangul_n_count;
    const v = hangul_v_base + (index % hangul_n_count) / hangul_t_count;
    const t = index % hangul_t_count;
    return if (t == 0)
        .{ .values = .{ l, v, 0 }, .len = 2 }
    else
        .{ .values = .{ l, v, hangul_t_base + t }, .len = 3 };
}

/// Compose the L jamo `l` with the scalars after `after_l`. Returns null
/// when the next scalar is not a V jamo. On success `end` receives the byte
/// offset just past the consumed jamo; returning the composed scalar alone
/// keeps the result in a register instead of an out-of-line struct.
fn hangulSyllableAt(
    text: []const u8,
    l: u21,
    after_l: usize,
    end: *usize,
) ?u21 {
    const v_packed = decodeJamo(text, after_l);
    if (v_packed == scalar.packed_invalid) return null;
    const v = scalar.packedCodepoint(v_packed);
    const lv = composeHangul(l, v) orelse return null;
    const after_v = after_l + scalar.packedLength(v_packed);
    const t_packed = decodeJamo(text, after_v);
    if (t_packed != scalar.packed_invalid) {
        if (composeHangulT(lv, scalar.packedCodepoint(t_packed))) |lvt| {
            end.* = after_v + scalar.packedLength(t_packed);
            return lvt;
        }
    }
    end.* = after_v;
    return lv;
}

/// Decode a three-byte Hangul jamo (U+1100..U+11FF) at `index`, or return
/// `packed_invalid` when the bytes are not a valid jamo sequence.
fn decodeJamo(text: []const u8, index: usize) u32 {
    if (index + 3 > text.len) return scalar.packed_invalid;
    if (text[index] != 0xe1) return scalar.packed_invalid;
    const second = text[index + 1];
    const third = text[index + 2];
    if (second & 0xfc != 0x84 or third & 0xc0 != 0x80) {
        return scalar.packed_invalid;
    }
    const codepoint: u32 = 0x1000 + (@as(u32, second & 0x3f) << 6) +
        (third & 0x3f);
    return ((codepoint + 1) << 3) | 2;
}

fn composeHangul(starter: u21, combining: u21) ?u21 {
    const l_index = starter -% hangul_l_base;
    if (l_index < hangul_l_count) {
        const v_index = combining -% hangul_v_base;
        if (v_index < hangul_v_count) {
            return hangul_s_base +
                (l_index * hangul_v_count + v_index) * hangul_t_count;
        }
    }
    const s_index = starter -% hangul_s_base;
    if (s_index < hangul_s_count and s_index % hangul_t_count == 0) {
        const t_index = combining -% hangul_t_base;
        if (t_index > 0 and t_index < hangul_t_count) {
            return starter + t_index;
        }
    }
    return null;
}

/// Compose a trailing T jamo onto an LV syllable. The caller already
/// established that `lv` is the result of an L+V composition, so its T index
/// is zero and the general range/modulo checks are unnecessary.
inline fn composeHangulT(lv: u21, t: u21) ?u21 {
    const t_index = t -% hangul_t_base;
    if (t_index > 0 and t_index < hangul_t_count) return lv + t_index;
    return null;
}

fn expectFormNormalized(source: []const u8, expected: []const u8, form: Form) !void {
    const output = try normalizeFormAlloc(std.testing.allocator, source, form);
    defer if (output) |owned| std.testing.allocator.free(owned);
    if (std.mem.eql(u8, source, expected)) {
        if (output != null) {
            std.debug.print("{s} unnecessarily changed: source={x} actual={x}\n", .{ @tagName(form), source, output.? });
            return error.TestUnexpectedResult;
        }
    } else {
        const actual = output orelse {
            std.debug.print("{s} unexpectedly unchanged: source={x} expected={x}\n", .{ @tagName(form), source, expected });
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(expected, actual);
    }
    if (!(try isNormalizedForm(expected, form))) {
        std.debug.print("{s} expected output rejected: expected={x}\n", .{ @tagName(form), expected });
        return error.TestUnexpectedResult;
    }
}

fn expectNormalized(source: []const u8, expected: []const u8) !void {
    try expectFormNormalized(source, expected, .nfc);
}

test "normalizer scalar helpers" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(?u21, 0x00e9), composePair('e', 0x0301));
    try testing.expectEqual(@as(?u21, 0xac00), composePair(0x1100, 0x1161));
    try testing.expectEqual(@as(?u21, null), composePair(0x0915, 0x093c));
    const mapping = decompositionFor(0x00e9).?;
    try testing.expectEqualSlices(u21, &.{ 'e', 0x0301 }, mapping);
    try testing.expectEqual(@as(?[]const u21, null), decompositionFor('a'));
    try testing.expectEqual(@as(u8, 230), combiningClass(0x0301));
    try testing.expectEqual(@as(u8, 0), combiningClass('a'));
}

test "normalization keeps ASCII and normalized UTF-8 allocation free" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expect((try normalizeAlloc(
        failing.allocator(),
        "plain ASCII",
    )) == null);
    try std.testing.expect((try normalizeAlloc(
        failing.allocator(),
        "caf\xc3\xa9 \xe4\xb8\xad",
    )) == null);
}

test "NFC performs canonical ordering composition and Hangul composition" {
    try std.testing.expect(!(try isNormalized("A\u{0301}")));
    try std.testing.expect(!(try isNormalized("\u{1100}\u{1161}")));
    try expectNormalized("cafe\xcc\x81", "caf\xc3\xa9");
    try expectNormalized("A\u{0301}\u{0323}", "\u{1ea0}\u{0301}");
    try expectNormalized("\u{1100}\u{1161}\u{11a8}", "\u{ac01}");
    try expectNormalized("\u{212b}", "\u{00c5}");
    try expectNormalized("\u{0958}", "\u{0915}\u{093c}");
    // Voiced kana compose from the unvoiced syllable and a sound mark.
    try expectNormalized("\u{30ab}\u{3099}", "\u{30ac}");
    try expectNormalized("\u{304b}\u{3099}", "\u{304c}");
}

test "Hangul jamo runs compose directly" {
    // LV and LVT, with trailing text and marks that must stay intact.
    try expectNormalized("\u{1100}\u{1161}", "\u{ac00}");
    try expectNormalized("\u{1100}\u{1161}\u{11a8}", "\u{ac01}");
    try expectNormalized(
        "\u{1100}\u{1161}\u{11a8} x",
        "\u{ac01} x",
    );
    try expectNormalized(
        "\u{1100}\u{1161}\u{0301}",
        "\u{ac00}\u{0301}",
    );
    try expectNormalized(
        "\u{1100}\u{1161}\u{11a8}\u{0301}",
        "\u{ac01}\u{0301}",
    );
    // A lone L jamo and an L followed by another V start fresh.
    try expectNormalized("\u{1100}", "\u{1100}");
    try expectNormalized("\u{1100}\u{1161}\u{1161}", "\u{ac00}\u{1161}");
    // NFD still decomposes syllables back to jamo.
    try expectFormNormalized(
        "\u{ac01}",
        "\u{1100}\u{1161}\u{11a8}",
        .nfd,
    );
}

test "NFC does not apply display-only Vietnamese mark reordering" {
    try expectNormalized("a\u{0301}\u{0306}", "\u{00e1}\u{0306}");
}

test "NFD decomposes and NFD output is stable" {
    try std.testing.expect(!(try isNormalizedForm("\u{00c5}", .nfd)));
    try expectFormNormalized("\u{00c5}", "A\u{030a}", .nfd);
    try expectFormNormalized("\u{ac01}", "\u{1100}\u{1161}\u{11a8}", .nfd);
    try expectFormNormalized("\u{1ea4}", "A\u{0302}\u{0301}", .nfd);
    try expectFormNormalized("caf\xc3\xa9", "cafe\u{0301}", .nfd);
    // Voiced kana decompose under NFD, so a kana run fast path must keep
    // them on the generic segment path.
    try expectFormNormalized("\u{30ac}", "\u{30ab}\u{3099}", .nfd);
    try expectFormNormalized("\u{304c}", "\u{304b}\u{3099}", .nfd);
}

test "NFKC and NFKD apply compatibility mappings" {
    try std.testing.expect(!(try isNormalizedForm("\u{fb01}", .nfkc)));
    try expectFormNormalized("\u{fb01}", "fi", .nfkc);
    try expectFormNormalized("\u{00a8}", " \u{0308}", .nfkc);
    try expectFormNormalized("\u{2163}", "IV", .nfkc);
    try expectFormNormalized("\u{fb01}", "fi", .nfkd);
    try expectFormNormalized("\u{00c5}", "A\u{030a}", .nfkd);
    try expectFormNormalized("\u{1ea4}", "A\u{0302}\u{0301}", .nfkd);
    try expectFormNormalized("\u{ff21}", "A", .nfkc);
}

test "segments keep composed, mark-leading, and non-CJK scalars" {
    const testing = @import("std").testing;
    // A non-CJK scalar between two ideographic scalars must still decompose.
    try expectFormNormalized(
        "\u{4e12}\u{4e3a}\u{ac0f}\u{4e3c}",
        "\u{4e12}\u{4e3a}\u{1100}\u{1161}\u{11b6}\u{4e3c}",
        .nfd,
    );
    // A composed starter decomposes before a lower-class mark reorders past it.
    try expectFormNormalized("\u{00e0}\u{0325}", "\u{1e01}\u{0300}", .nfc);
    try expectFormNormalized("\u{00e9}\u{0323}", "\u{1eb9}\u{0301}", .nfc);
    try expectFormNormalized("a\u{0325}\u{0300}", "\u{1e01}\u{0300}", .nfc);
    // The halfwidth voiced sound mark decomposes to a mark and must reorder
    // inside the preceding segment.
    try expectFormNormalized(
        "\u{00ec}\u{ff9e}\u{00f3}",
        "i\u{3099}\u{0300}o\u{0301}",
        .nfkd,
    );
    // A compatibility jamo must compose with the preceding L jamo.
    try expectFormNormalized(
        "\u{1128}\u{1100}\u{3152}",
        "\u{1128}\u{ac54}",
        .nfkc,
    );

    // The code-point and UTF-16 paths share the segment engine.
    const input_nfc = [_]u21{ 0x00e0, 0x0325 };
    const expected_nfc = [_]u21{ 0x1e01, 0x0300 };
    const codepoint_result = try normalizeCodepointsAlloc(
        testing.allocator,
        &input_nfc,
        .nfc,
    );
    defer if (codepoint_result) |value| testing.allocator.free(value);
    try testing.expectEqualSlices(u21, &expected_nfc, codepoint_result.?);

    const units = [_]u16{ 0x4e12, 0x4e3a, 0xac0f, 0x4e3c };
    const expected_units = [_]u16{
        0x4e12, 0x4e3a, 0x1100, 0x1161, 0x11b6, 0x4e3c,
    };
    const utf16_result = try normalizeUtf16Alloc(
        testing.allocator,
        &units,
        .nfd,
    );
    defer if (utf16_result) |value| testing.allocator.free(value);
    try testing.expectEqualSlices(u16, &expected_units, utf16_result.?);
}

test "Latin-1 segment fast path matches the general rule" {
    const testing = @import("std").testing;
    // The table shortcut must agree with the general rule for every scalar in
    // the block, including U+00B5, whose compatibility decomposition starts in
    // a page that holds composition seconds.
    for (0x80..0x100) |codepoint| {
        inline for (.{ false, true }) |compatibility| {
            try testing.expectEqual(
                continuesSegmentLookup(@intCast(codepoint), compatibility),
                continuesSegment(@intCast(codepoint), compatibility),
            );
        }
    }
}

test "recursive decompositions are canonically ordered" {
    const testing = @import("std").testing;
    // The single-scalar segment path emits recursive decompositions without
    // running the ordering pass, so every generated mapping must already be
    // ordered. Pages without mappings are skipped by the simple-page bit.
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        inline for (.{ false, true }) |compatibility| {
            if (!data.isSimplePage(codepoint, compatibility)) {
                const mapping = if (compatibility)
                    decomposition.compatibilityForCodepoint(codepoint)
                else
                    decomposition.forCodepoint(codepoint);
                if (mapping) |components| {
                    var previous: u8 = 0;
                    for (components) |component| {
                        const class = combining_class.forCodepoint(component);
                        if (class == 0) {
                            previous = 0;
                            continue;
                        }
                        try testing.expect(previous <= class);
                        previous = class;
                    }
                }
            }
        }
    }
}

test "normalization rejects invalid UTF-8 before allocating" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        normalizeAlloc(failing.allocator(), "valid\xfftail"),
    );
    try std.testing.expectError(error.InvalidUtf8, isNormalized("\xff"));
}

test "normalization appends into a caller-owned buffer" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try std.testing.expect(try normalizeFormInto(
        allocator,
        "cafe\u{0301}",
        .nfc,
        &output,
    ));
    try std.testing.expectEqualStrings("caf\xc3\xa9", output.items);

    try std.testing.expect(!(try normalizeFormInto(
        allocator,
        "abc",
        .nfc,
        &output,
    )));
    try std.testing.expectEqualStrings("caf\xc3\xa9abc", output.items);

    try std.testing.expectError(
        error.InvalidUtf8,
        normalizeFormInto(allocator, "\xff", .nfc, &output),
    );
}

test "spanQuickCheckYes reports the first unstable offset" {
    try std.testing.expectEqual(
        @as(usize, 3),
        try spanQuickCheckYes("abc", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try spanQuickCheckYes("a\u{0301}", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try spanQuickCheckYes("abc\u{0301}", .nfc),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try spanQuickCheckYes("\u{0340}", .nfc),
    );
    // U+0340 is Quick_Check=No with ccc 230, so the preceding starter must
    // stay inside the suffix that gets normalized.
    try std.testing.expectEqual(
        @as(usize, 2),
        try spanQuickCheckYes("abc\u{0340}", .nfc),
    );
    // Invalid bytes after an early stop still surface as InvalidUtf8.
    try std.testing.expectError(
        error.InvalidUtf8,
        spanQuickCheckYes("a\u{0301}\xff", .nfc),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        spanQuickCheckYes("\xff", .nfc),
    );
}

test "normalization copies stable prefixes" {
    const allocator = std.testing.allocator;
    const input = "abcde\u{0301}xyz";
    const expected = "abcd\xc3\xa9xyz";

    const result = (try normalizeAlloc(allocator, input)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try std.testing.expect(try normalizeFormInto(
        allocator,
        input,
        .nfc,
        &output,
    ));
    try std.testing.expectEqualStrings(expected, output.items);
}

test "UTF-16 normalization" {
    const allocator = std.testing.allocator;
    const source = try utf16.utf8ToUtf16Alloc(allocator, "cafe\u{0301}");
    defer allocator.free(source);
    try std.testing.expect(!(try isNormalizedUtf16(source, .nfc)));

    const normalized = (try normalizeUtf16Alloc(allocator, source, .nfc)).?;
    defer allocator.free(normalized);
    try std.testing.expect(try isNormalizedUtf16(normalized, .nfc));

    const text = try utf16.utf16ToUtf8Alloc(allocator, normalized);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("caf\xc3\xa9", text);
}

test "UTF-16 normalization matches the UTF-8 path" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const inputs = [_][]const u8{
        "",
        "plain ASCII",
        "cafe\u{0301}",
        "A\u{0301}\u{0323}B",
        "\u{1100}\u{1161}\u{11a8}",
        "\u{ac00}\u{11a8}",
        "\u{1f600}\u{1f469}\u{200d}\u{1f4bb}",
        "Hello, 世界! café naïve Straße",
        "\u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{0645}\u{0631}\u{062d}\u{0628}\u{0627}",
        "\u{0915}\u{094d}\u{0937}\u{093f}",
        "\u{fb01}\u{212b}\u{1e9b}\u{0323}",
        "e\u{0301}\u{0323} " ** 8,
    };
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };
    for (forms) |form| {
        for (inputs) |input| {
            const units = try utf16.utf8ToUtf16Alloc(allocator, input);
            defer allocator.free(units);

            const expected = try normalizeFormAlloc(allocator, input, form);
            defer if (expected) |owned| allocator.free(owned);
            const expected_utf16 = try utf16.utf8ToUtf16Alloc(
                allocator,
                expected orelse input,
            );
            defer allocator.free(expected_utf16);

            const actual = try normalizeUtf16Alloc(allocator, units, form);
            defer if (actual) |owned| allocator.free(owned);
            try testing.expectEqualSlices(
                u16,
                expected_utf16,
                actual orelse units,
            );

            // The buffer-reuse API appends the same normalized units and
            // reports the same change flag.
            var buffer = std.ArrayList(u16).empty;
            defer buffer.deinit(allocator);
            const changed = try normalizeUtf16Into(
                allocator,
                units,
                form,
                &buffer,
            );
            try testing.expectEqual(expected != null, changed);
            try testing.expectEqualSlices(u16, expected_utf16, buffer.items);
        }
    }
    // Lone surrogates are rejected instead of decoded.
    try testing.expectError(
        error.InvalidUtf16,
        normalizeUtf16Alloc(allocator, &.{0xd800}, .nfc),
    );
    try testing.expectError(
        error.InvalidUtf16,
        normalizeUtf16Alloc(allocator, &.{ 0xdc00, 0x41 }, .nfc),
    );
    var buffer = std.ArrayList(u16).empty;
    defer buffer.deinit(allocator);
    try testing.expectError(
        error.InvalidUtf16,
        normalizeUtf16Into(allocator, &.{ 0xd800, 0x41 }, .nfc, &buffer),
    );
    // `isNormalizedUtf16` stops at the first change; an invalid suffix must
    // still surface as InvalidUtf16.
    try testing.expectError(
        error.InvalidUtf16,
        isNormalizedUtf16(&.{0xd800}, .nfc),
    );
    try testing.expectError(
        error.InvalidUtf16,
        isNormalizedUtf16(&.{ 0x41, 0x301, 0xd800 }, .nfc),
    );
    try testing.expectError(
        error.InvalidUtf16,
        isNormalizedUtf16(&.{ 0x41, 0xdc00 }, .nfc),
    );
    try testing.expect(try isNormalizedUtf16(
        &.{ 0x4e16, 0x754c, 0x41 },
        .nfc,
    ));
}

fn appendUtf16Scalar(
    list: *std.ArrayList(u16),
    allocator: std.mem.Allocator,
    codepoint: u21,
) error{OutOfMemory}!void {
    if (codepoint <= 0xFFFF) {
        try list.append(allocator, @intCast(codepoint));
        return;
    }
    const value = codepoint - 0x10000;
    try list.append(allocator, @intCast(0xD800 + (value >> 10)));
    try list.append(allocator, @intCast(0xDC00 + (value & 0x3FF)));
}

test "UTF-16 normalization agrees with the codepoint path on mixed scripts" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    // Scalars chosen to hit every UTF-16 scan path: runs, marks, kana and
    // jamo composition, Hangul syllables, fullwidth forms, and compatibility
    // mappings. The quick-check pre-pass only runs for CJK-leading text, so
    // the pool also starts sequences with CJK scalars.
    const pool = [_]u21{
        'a',     'e',     'A',     ' ',     0x00e9,
        0x00c5,  0x00df,  0x00b5,  0x00aa,  0x00bc,
        0x0301,  0x0323,  0x0327,  0x0316,  0x0308,
        0x0345,  0x05b0,  0x093c,  0x094d,  0x3042,
        0x304b,  0x304c,  0x3093,  0x3099,  0x309a,
        0x309b,  0x309c,  0x309d,  0x309e,  0x309f,
        0x30a2,  0x30ab,  0x30ac,  0x30f7,  0x30fa,
        0x30fc,  0x30fe,  0x30ff,  0x3040,  0x3097,
        0x4e16,  0x754c,  0x9fff,  0x4e00,  0x3002,
        0x3001,  0x3000,  0x302a,  0x302f,  0x303f,
        0xff01,  0xff21,  0xff66,  0xff9e,  0xffef,
        0xff00,  0x1100,  0x1161,  0x11a8,  0xac00,
        0xac01,  0x1175,  0x11c2,  0x115f,  0x05e9,
        0x0645,  0x0915,  0x0937,  0x093f,  0x0e01,
        0x0e33,  0x1f600, 0x1f469, 0x200d,  0x212b,
        0xfb01,  0x1e9b,  0x2122,  0x00a8,  0x0385,
        0x1d160, 0x0344,  0x0f73,  0x2f800, 0x0340,
    };
    var random = std.Random.DefaultPrng.init(0x1c0ffee);
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };
    var units = std.ArrayList(u16).empty;
    defer units.deinit(allocator);
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    var expected = std.ArrayList(u21).empty;
    defer expected.deinit(allocator);
    var want = std.ArrayList(u16).empty;
    defer want.deinit(allocator);
    var buffer = std.ArrayList(u16).empty;
    defer buffer.deinit(allocator);
    for (0..1000) |_| {
        units.clearRetainingCapacity();
        codepoints.clearRetainingCapacity();
        const length = random.random().uintLessThan(usize, 20);
        for (0..length) |_| {
            const codepoint = pool[random.random().uintLessThan(usize, pool.len)];
            try codepoints.append(allocator, codepoint);
            try appendUtf16Scalar(&units, allocator, codepoint);
        }
        for (forms) |form| {
            expected.clearRetainingCapacity();
            try normalizeCodepointsInto(
                allocator,
                codepoints.items,
                form,
                &expected,
            );
            want.clearRetainingCapacity();
            for (expected.items) |codepoint| {
                try appendUtf16Scalar(&want, allocator, codepoint);
            }
            const changed_expected = !std.mem.eql(u16, want.items, units.items);

            const actual = try normalizeUtf16Alloc(allocator, units.items, form);
            defer if (actual) |owned| allocator.free(owned);
            try testing.expectEqual(changed_expected, actual != null);
            try testing.expectEqualSlices(
                u16,
                want.items,
                actual orelse units.items,
            );

            buffer.clearRetainingCapacity();
            const changed = try normalizeUtf16Into(
                allocator,
                units.items,
                form,
                &buffer,
            );
            try testing.expectEqual(changed_expected, changed);
            try testing.expectEqualSlices(u16, want.items, buffer.items);

            try testing.expectEqual(
                !changed_expected,
                try isNormalizedUtf16(units.items, form),
            );
        }
    }
}

test "streaming normalizer matches one-shot normalization" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        "cafe\u{0301}",
        "A\u{0301}B",
        "\u{1100}\u{1161}\u{11A8}",
        "\u{0301}A",
        "plain ASCII",
        "a\u{0323}\u{0301}b",
        "\u{00e0}\u{0325}",
        "i\u{0300}\u{ff9e}",
        "\u{1128}\u{1100}\u{3152}",
    };
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };

    for (forms) |form| {
        for (inputs) |input| {
            var normalizer = Normalizer.init(allocator, form);
            defer normalizer.deinit();
            var output = std.ArrayList(u8).empty;
            defer output.deinit(allocator);

            var iterator = std.unicode.Utf8Iterator{ .bytes = input, .i = 0 };
            while (iterator.nextCodepoint()) |codepoint| {
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &encoded) catch
                    unreachable;
                try normalizer.feed(encoded[0..len], &output);
            }
            try normalizer.finish(&output);

            const expected = try normalizeFormAlloc(allocator, input, form);
            defer if (expected) |owned| allocator.free(owned);
            try std.testing.expectEqualStrings(
                expected orelse input,
                output.items,
            );
        }
    }
}

test "span editing matches whole-string normalization" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const inputs = [_][]const u8{
        "a\u{0301}b\u{0323}c",
        "e\u{0301}\u{0323}",
        "A\u{030a}\u{0301}",
        "\u{1100}\u{1161}\u{11a8}",
        "\u{ac00}\u{11a8}",
        "\u{ac01}",
        "\u{0301}abc",
        "a\u{0340}b",
        "x\u{0dcf}y",
        "\u{0d15}\u{094d}\u{0937}\u{093f}",
        "aa\u{0301}\u{0323}\u{0302}bb",
        "\u{fb01}\u{212b}",
        "\u{1e9b}\u{0323}",
        "a\u{0301}bcdef\u{0323}g",
        "plain ASCII",
        "",
    };
    const forms = [_]Form{ .nfc, .nfd, .nfkc, .nfkd };
    for (forms) |form| {
        for (inputs) |input| {
            var reference = std.ArrayList(u8).empty;
            defer reference.deinit(allocator);
            try normalizeChangedFormInto(allocator, input, form, &reference);

            var edited = std.ArrayList(u8).empty;
            defer edited.deinit(allocator);
            try normalizeWithEditsInto(allocator, input, form, &edited);

            try testing.expectEqualStrings(reference.items, edited.items);
        }
    }
}

test "Unicode 17 NFC normalization conformance" {
    if (conformance.len < 12 or
        !std.mem.eql(u8, conformance[0..4], "CJNF") or
        conformance[4] != 1 or
        !std.mem.eql(u8, conformance[5..8], &unicode_version))
    {
        return error.InvalidFixture;
    }
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    try std.testing.expectEqual(@as(u32, 20_034), case_count);
    var fixture_offset: usize = 12;
    for (0..case_count) |_| {
        const lengths = conformance[fixture_offset..][0..5].*;
        fixture_offset += 5;
        var columns: [5][72]u8 = undefined;
        var column_lengths: [5]usize = undefined;
        for (lengths, 0..) |scalar_count, column_index| {
            var utf8_len: usize = 0;
            for (0..scalar_count) |_| {
                const codepoint: u21 = @intCast(std.mem.readInt(
                    u32,
                    conformance[fixture_offset..][0..4],
                    .little,
                ));
                fixture_offset += 4;
                utf8_len += try std.unicode.utf8Encode(
                    codepoint,
                    columns[column_index][utf8_len..],
                );
            }
            column_lengths[column_index] = utf8_len;
        }
        const c1 = columns[0][0..column_lengths[0]];
        const c2 = columns[1][0..column_lengths[1]];
        const c3 = columns[2][0..column_lengths[2]];
        const c4 = columns[3][0..column_lengths[3]];
        const c5 = columns[4][0..column_lengths[4]];
        try expectNormalized(c1, c2);
        try expectNormalized(c2, c2);
        try expectNormalized(c3, c2);
        try expectNormalized(c4, c4);
        try expectNormalized(c5, c4);
    }
    try std.testing.expectEqual(conformance.len, fixture_offset);
}

test "isNormalized validates the unscanned suffix" {
    const testing = @import("std").testing;
    try testing.expect(!(try isNormalized("a\u{0301}b")));
    try testing.expectError(
        error.InvalidUtf8,
        isNormalized("a\u{0301}\xff"),
    );
    try testing.expectError(error.InvalidUtf8, isNormalized("\xff"));
}

test "streaming NFD scan matches the array quick check" {
    const testing = @import("std").testing;
    // NFD's quick check is Yes/No only; the streaming scan relies on that.
    var codepoint: u21 = 0;
    while (codepoint <= 0x10ffff) : (codepoint += 1) {
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) continue;
        try testing.expect(data.quickCheck(codepoint, .nfd) != .maybe);
        const single = [_]u21{codepoint};
        var scan = NfdScan{};
        scan.feed(codepoint);
        try testing.expectEqual(
            isNormalizedCodepoints(&single, .nfd),
            scan.ok,
        );
    }
    const cases = [_][]const u8{
        "Hello, world!",
        "caf\u{00e9} na\u{00ef}ve",
        "e\u{0301}\u{0323}",
        "e\u{0323}\u{0301}",
        "\u{1100}\u{1161}\u{11a8}",
        "\u{ac00}\u{11a8}",
        "\u{4e16}\u{754c}",
        "\u{05e9}\u{05dc}\u{05d5}\u{05dd}",
        "Stra\u{00df}e",
        "\u{1f600}\u{1f469}\u{200d}\u{1f4bb}",
    };
    for (cases) |text| {
        const codepoints = try utf8ToCodepointsAlloc(testing.allocator, text);
        defer testing.allocator.free(codepoints);
        var scan = NfdScan{};
        for (codepoints) |value| scan.feed(value);
        try testing.expectEqual(
            isNormalizedCodepoints(codepoints, .nfd),
            scan.ok,
        );
    }
}

fn utf8ToCodepointsAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]u21 {
    var list = std.ArrayList(u21).empty;
    errdefer list.deinit(allocator);
    var view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |value| {
        try list.append(allocator, value);
    }
    return list.toOwnedSlice(allocator);
}
