//! Test-only fragmented UTF-8 source with independent cursor chunk caches.

const std = @import("std");
const Scalar = @import("../scalar/cursor.zig").Scalar;

pub const Metrics = struct {
    scalar_reads: usize = 0,
    decoded_bytes: usize = 0,
    next_calls: usize = 0,
    chunk_steps: usize = 0,
    forks: usize = 0,
};

pub const ChunkCursor = struct {
    pub const Error = error{ InvalidUtf8, StaleSource, SourceFailure };

    chunks: []const []const u8,
    metrics: *Metrics,
    domain_end: usize,
    offset: usize = 0,
    chunk_index: usize = 0,
    chunk_offset: usize = 0,
    epoch: ?*usize = null,
    expected_epoch: usize = 0,
    failure_offset: ?usize = null,
    failure_once: bool = false,

    pub fn init(chunks: []const []const u8, metrics: *Metrics) ChunkCursor {
        var length: usize = 0;
        for (chunks) |chunk| length += chunk.len;
        return .{ .chunks = chunks, .metrics = metrics, .domain_end = length };
    }

    pub fn position(self: ChunkCursor) usize {
        return self.offset;
    }

    pub fn end(self: ChunkCursor) usize {
        return self.domain_end;
    }

    pub fn fork(self: ChunkCursor) ChunkCursor {
        self.metrics.forks += 1;
        return self;
    }

    pub fn next(self: *ChunkCursor) Error!?Scalar {
        self.metrics.next_calls += 1;
        if (self.epoch) |epoch| {
            if (epoch.* != self.expected_epoch) return error.StaleSource;
        }
        if (self.failure_offset) |offset| {
            if (self.offset >= offset) {
                if (self.failure_once) self.failure_offset = null;
                return error.SourceFailure;
            }
        }
        if (self.offset == self.domain_end) return null;
        const start = self.offset;
        var bytes: [4]u8 = undefined;
        bytes[0] = try self.nextByte();
        const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return error.InvalidUtf8;
        for (1..length) |index| bytes[index] = try self.nextByte();
        const codepoint = std.unicode.utf8Decode(bytes[0..length]) catch return error.InvalidUtf8;
        self.metrics.scalar_reads += 1;
        return .{ .codepoint = codepoint, .byte_start = start, .byte_end = self.offset };
    }

    fn nextByte(self: *ChunkCursor) Error!u8 {
        while (self.chunk_index < self.chunks.len and self.chunk_offset == self.chunks[self.chunk_index].len) {
            self.chunk_index += 1;
            self.chunk_offset = 0;
            self.metrics.chunk_steps += 1;
        }
        if (self.chunk_index == self.chunks.len) return error.InvalidUtf8;
        const byte = self.chunks[self.chunk_index][self.chunk_offset];
        self.chunk_offset += 1;
        self.offset += 1;
        self.metrics.decoded_bytes += 1;
        return byte;
    }
};

/// Every byte seam (including seams inside UTF-8), one byte per chunk, and
/// deterministic random chunks all exercise the scalar-cursor source boundary.
pub fn expectAllChunkings(comptime Streaming: anytype, comptime Continuous: anytype, text: []const u8) !void {
    for (0..text.len + 1) |seam| {
        const chunks = [_][]const u8{ text[0..seam], text[seam..] };
        try expectEquivalent(Streaming, Continuous, text, &chunks);
    }
    var chunks: [1024][]const u8 = undefined;
    std.debug.assert(text.len <= chunks.len);
    for (text, 0..) |_, index| chunks[index] = text[index..][0..1];
    try expectEquivalent(Streaming, Continuous, text, chunks[0..text.len]);
    var random = std.Random.DefaultPrng.init(0x7529_17);
    for (0..4) |_| {
        var offset: usize = 0;
        var chunk_count: usize = 0;
        while (offset < text.len) {
            const length = @min(text.len - offset, random.random().uintLessThan(usize, 9) + 1);
            chunks[chunk_count] = text[offset..][0..length];
            chunk_count += 1;
            offset += length;
        }
        try expectEquivalent(Streaming, Continuous, text, chunks[0..chunk_count]);
    }
}

pub fn expectEquivalent(comptime Streaming: anytype, comptime Continuous: anytype, text: []const u8, chunks: []const []const u8) !void {
    var metrics = Metrics{};
    var stream = try Streaming(ChunkCursor).init(ChunkCursor.init(chunks, &metrics));
    var slice = Continuous(text);
    var expected_start: usize = 0;
    while (slice.next()) |expected| {
        const actual = try stream.next() orelse return error.MissingCursorSegment;
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual(expected_start, actual.byte_start);
        try std.testing.expect(actual.byte_len > 0);
        expected_start += actual.byte_len;
    }
    try std.testing.expectEqual(text.len, expected_start);
    try std.testing.expectEqual(null, try stream.next());
    try expectLinearMetrics(text, chunks.len, metrics);
}

pub fn expectLinearMetrics(text: []const u8, chunk_count: usize, metrics: Metrics) !void {
    const scalar_count = try std.unicode.utf8CountCodepoints(text);
    try std.testing.expect(metrics.scalar_reads <= scalar_count * 2);
    try std.testing.expect(metrics.decoded_bytes <= text.len * 2);
    try std.testing.expect(metrics.next_calls <= scalar_count * 2 + 4);
    try std.testing.expect(metrics.chunk_steps <= chunk_count * 2);
    try std.testing.expectEqual(@as(usize, 1), metrics.forks);
}

/// Decode the existing committed Unicode 17 fixtures and check the native
/// cursor boundaries directly against the oracle, plus every chunk seam.
pub fn expectConformance(comptime Streaming: anytype, comptime Continuous: anytype, fixture: []const u8, magic: []const u8, case_count: u32) !void {
    try std.testing.expectEqualStrings(magic, fixture[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 17, 0, 0 }, fixture[4..8]);
    try std.testing.expectEqual(case_count, std.mem.readInt(u32, fixture[8..12], .little));
    var offset: usize = 12;
    for (0..case_count) |_| {
        const count = fixture[offset];
        offset += 1;
        const expected = fixture[offset..][0 .. @as(usize, count) + 1];
        offset += @as(usize, count) + 1;
        const codepoints = fixture[offset..][0 .. @as(usize, count) * 4];
        offset += @as(usize, count) * 4;
        var utf8: [1024]u8 = undefined;
        var utf8_len: usize = 0;
        var expected_ends: [256]usize = undefined;
        var expected_count: usize = 0;
        try std.testing.expectEqual(@as(u8, 1), expected[0]);
        for (0..count) |index| {
            const codepoint: u21 = @intCast(std.mem.readInt(u32, codepoints[index * 4 ..][0..4], .little));
            utf8_len += try std.unicode.utf8Encode(codepoint, utf8[utf8_len..]);
            if (expected[index + 1] != 0) {
                expected_ends[expected_count] = utf8_len;
                expected_count += 1;
            }
        }
        const text = utf8[0..utf8_len];
        const chunks = [_][]const u8{text};
        var metrics = Metrics{};
        var stream = try Streaming(ChunkCursor).init(ChunkCursor.init(&chunks, &metrics));
        for (expected_ends[0..expected_count]) |expected_end| {
            const segment = try stream.next() orelse return error.MissingConformanceSegment;
            try std.testing.expectEqual(expected_end, segment.byte_start + segment.byte_len);
        }
        try std.testing.expectEqual(null, try stream.next());
        try expectAllChunkings(Streaming, Continuous, text);
    }
    try std.testing.expectEqual(fixture.len, offset);
}

pub fn expectSourceErrors(comptime Streaming: anytype) !void {
    const text = "a. , ,lower 👩‍💻\r\nNext.";
    const chunks = [_][]const u8{text};
    var metrics = Metrics{};
    var epoch: usize = 0;
    var cursor = ChunkCursor.init(&chunks, &metrics);
    cursor.epoch = &epoch;
    var stream = try Streaming(ChunkCursor).init(cursor);
    epoch += 1;
    try std.testing.expectError(error.StaleSource, stream.next());
    epoch -= 1;
    const stale_reads = metrics.next_calls;
    try std.testing.expectError(error.StaleSource, stream.next());
    try std.testing.expectEqual(stale_reads, metrics.next_calls);

    // A stale source stays observable after a returned segment or real EOF.
    cursor.expected_epoch = epoch;
    stream = try Streaming(ChunkCursor).init(cursor);
    _ = try stream.next();
    epoch += 1;
    try std.testing.expectError(error.StaleSource, stream.next());

    const empty = [_][]const u8{""};
    cursor = ChunkCursor.init(&empty, &metrics);
    cursor.epoch = &epoch;
    cursor.expected_epoch = epoch;
    stream = try Streaming(ChunkCursor).init(cursor);
    try std.testing.expectEqual(null, try stream.next());
    epoch += 1;
    try std.testing.expectError(error.StaleSource, stream.next());

    cursor = ChunkCursor.init(&chunks, &metrics);
    cursor.failure_offset = 5;
    stream = try Streaming(ChunkCursor).init(cursor);
    var failed = false;
    while (true) {
        const segment = stream.next() catch |err| {
            try std.testing.expectEqual(error.SourceFailure, err);
            failed = true;
            break;
        };
        if (segment == null) break;
    }
    try std.testing.expect(failed);

    // The read that closes a segment must propagate errors at domain end.
    const closing = [_][]const u8{"a"};
    cursor = ChunkCursor.init(&closing, &metrics);
    cursor.failure_offset = 1;
    cursor.failure_once = true;
    stream = try Streaming(ChunkCursor).init(cursor);
    try std.testing.expectError(error.SourceFailure, stream.next());
    const closing_reads = metrics.next_calls;
    try std.testing.expectError(error.SourceFailure, stream.next());
    try std.testing.expectError(error.SourceFailure, stream.next());
    try std.testing.expectEqual(closing_reads, metrics.next_calls);

    const invalid = [_][]const u8{ "a", "\xf0", "\x9f" };
    stream = try Streaming(ChunkCursor).init(ChunkCursor.init(&invalid, &metrics));
    try std.testing.expectError(error.InvalidUtf8, stream.next());
}
