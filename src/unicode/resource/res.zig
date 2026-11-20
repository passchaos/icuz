//! ICU `.res` resource bundle reader.
//!
//! Supports format versions 1.0 through 3.x, including 16-bit tables and
//! arrays, String-v2 suffix sharing, binary and integer-vector resources,
//! aliases, and optional pool-bundle key/string sharing.

const std = @import("std");

pub const Error = error{
    InvalidFormat,
    UnsupportedFormat,
    TypeMismatch,
    NotFound,
    InvalidPath,
    ExternalAlias,
    InvalidAlias,
    OutOfMemory,
};

pub const Endian = std.builtin.Endian;

const udata_magic1: u8 = 0xda;
const udata_magic2: u8 = 0x27;

const type_string: u32 = 0;
const type_binary: u32 = 1;
const type_table: u32 = 2;
const type_alias: u32 = 3;
const type_table32: u32 = 4;
const type_table16: u32 = 5;
const type_string_v2: u32 = 6;
const type_int: u32 = 7;
const type_array: u32 = 8;
const type_array16: u32 = 9;
const type_int_vector: u32 = 14;

const index_length = 0;
const index_keys_top = 1;
const index_bundle_top = 3;
const index_attributes = 5;
const index_16bit_top = 6;
const index_pool_checksum = 7;

const attribute_no_fallback: i32 = 1;
const attribute_is_pool_bundle: i32 = 2;
const attribute_uses_pool_bundle: i32 = 4;

fn readU16At(bytes: []const u8, offset: usize, endian: Endian) ?u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], endian);
}

fn readU32At(bytes: []const u8, offset: usize, endian: Endian) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], endian);
}

fn readI32At(bytes: []const u8, offset: usize, endian: Endian) ?i32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(i32, bytes[offset..][0..4], endian);
}

/// A borrowed UTF-16 string inside a resource bundle or pool bundle.
pub const StringRef = struct {
    bytes: []const u8,
    unit_offset: usize,
    len: usize,
    endian: Endian,

    pub fn at(self: StringRef, index: usize) ?u16 {
        if (index >= self.len) return null;
        return readU16At(self.bytes, self.unit_offset + index * 2, self.endian);
    }

    pub fn eqlAscii(self: StringRef, ascii: []const u8) bool {
        if (self.len != ascii.len) return false;
        for (ascii, 0..) |byte, index| {
            if (self.at(index).? != byte) return false;
        }
        return true;
    }

    pub fn toUtf8Alloc(
        self: StringRef,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        var index: usize = 0;
        while (index < self.len) {
            const first = self.at(index).?;
            index += 1;
            var codepoint: u21 = first;
            if (first >= 0xD800 and first <= 0xDBFF and index < self.len) {
                const second = self.at(index).?;
                if (second >= 0xDC00 and second <= 0xDFFF) {
                    index += 1;
                    codepoint = 0x10000 +
                        ((@as(u21, first - 0xD800) << 10) |
                            @as(u21, second - 0xDC00));
                }
            }
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &buffer) catch
                std.unicode.utf8Encode(0xFFFD, &buffer) catch unreachable;
            try output.appendSlice(allocator, buffer[0..length]);
        }
        return output.toOwnedSlice(allocator);
    }
};

/// A borrowed vector of 32-bit integers.
pub const IntVectorRef = struct {
    bytes: []const u8,
    offset: usize,
    len: usize,
    endian: Endian,

    pub fn at(self: IntVectorRef, index: usize) ?i32 {
        if (index >= self.len) return null;
        return readI32At(self.bytes, self.offset + index * 4, self.endian);
    }
};

pub const Table = struct {
    bundle: *const ResourceBundle,
    handle: u32,

    pub fn count(self: Table) usize {
        return self.bundle.tableCount(self.handle) orelse 0;
    }

    pub fn keyAt(self: Table, index: usize) ?[]const u8 {
        return self.bundle.tableKeyAt(self.handle, index);
    }

    pub fn valueAt(self: Table, index: usize) ?Value {
        return self.bundle.tableValueAt(self.handle, index);
    }

    pub fn get(self: Table, key: []const u8) ?Value {
        return self.bundle.tableGet(self.handle, key);
    }
};

pub const Array = struct {
    bundle: *const ResourceBundle,
    handle: u32,

    pub fn count(self: Array) usize {
        return self.bundle.arrayCount(self.handle) orelse 0;
    }

    pub fn at(self: Array, index: usize) ?Value {
        return self.bundle.arrayAt(self.handle, index);
    }
};

pub const Value = union(enum) {
    none,
    string: StringRef,
    binary: []const u8,
    table: Table,
    alias: StringRef,
    int: i32,
    uint: u32,
    array: Array,
    int_vector: IntVectorRef,
};

const Pool = struct {
    bytes: []const u8,
    endian: Endian,
    key_start: usize,
    key_end: usize,
    sixteen_start: usize,
    sixteen_end: usize,
    checksum: i32,
};

pub const ResourceBundle = struct {
    bytes: []const u8,
    root_offset: usize,
    endian: Endian,
    root_handle: u32,
    index_count: usize,
    indexes: [8]i32 = [_]i32{0} ** 8,
    key_limit_rel: usize = 0,
    key_start: usize = 0,
    key_end: usize = 0,
    sixteen_start: usize = 0,
    sixteen_end: usize = 0,
    pool: ?Pool = null,
    pool_string_index_limit: i32 = 0,
    pool_string_index16_limit: i32 = 0,
    no_fallback: bool = false,
    is_pool_bundle: bool = false,
    uses_pool_bundle: bool = false,
    pool_checksum: i32 = 0,

    /// Parses a standalone `.res` file.
    pub fn init(bytes: []const u8) Error!ResourceBundle {
        if (bytes.len < 24) return error.InvalidFormat;
        const endian: Endian = if (bytes[8] != 0) .big else .little;
        const header_size = readU16At(bytes, 0, endian) orelse
            return error.InvalidFormat;
        if (bytes[2] != udata_magic1 or bytes[3] != udata_magic2) {
            return error.InvalidFormat;
        }
        if (header_size < 24 or header_size > bytes.len) {
            return error.InvalidFormat;
        }
        const info_size = readU16At(bytes, 4, endian) orelse
            return error.InvalidFormat;
        if (info_size < 20) return error.InvalidFormat;
        if (!std.mem.eql(u8, bytes[12..16], "ResB")) {
            return error.InvalidFormat;
        }
        const version_major = bytes[16];
        const version_minor = bytes[17];
        if (version_major < 1 or version_major > 3) {
            return error.UnsupportedFormat;
        }
        if (bytes[9] != 0) return error.UnsupportedFormat;
        if (bytes[10] != 2) return error.UnsupportedFormat;

        const root_offset: usize = header_size;
        const root_handle = readU32At(bytes, root_offset, endian) orelse
            return error.InvalidFormat;
        const root_type = root_handle >> 28;
        if (root_type != type_table and root_type != type_table32 and
            root_type != type_table16)
        {
            return error.InvalidFormat;
        }

        var bundle = ResourceBundle{
            .bytes = bytes,
            .root_offset = root_offset,
            .endian = endian,
            .root_handle = root_handle,
            .index_count = 0,
        };

        if (version_major == 1 and version_minor == 0) {
            bundle.key_limit_rel = 0x10000;
            bundle.key_start = root_offset + 4;
            bundle.key_end = bytes.len;
            return bundle;
        }

        const index_start = root_offset + 4;
        const first_index = readI32At(bytes, index_start, endian) orelse
            return error.InvalidFormat;
        const count = @as(usize, @intCast(
            @as(u32, @bitCast(first_index)) & 0xff,
        ));
        if (count <= 4) return error.InvalidFormat;
        if (index_start + count * 4 > bytes.len) return error.InvalidFormat;
        bundle.index_count = count;

        var index: usize = 0;
        while (index < count and index < bundle.indexes.len) : (index += 1) {
            bundle.indexes[index] =
                readI32At(bytes, index_start + index * 4, endian) orelse
                return error.InvalidFormat;
        }

        const keys_top = bundle.indexes[index_keys_top];
        const bundle_top = bundle.indexes[index_bundle_top];
        if (keys_top < 0 or bundle_top < 0) return error.InvalidFormat;
        if (root_offset + @as(usize, @intCast(bundle_top)) * 4 > bytes.len) {
            return error.InvalidFormat;
        }
        const keys_top_usize: usize = @intCast(keys_top);
        if (keys_top_usize > 1 + count) {
            bundle.key_limit_rel = keys_top_usize * 4;
        }
        bundle.key_start = root_offset + (1 + count) * 4;
        bundle.key_end = if (bundle.key_limit_rel != 0)
            root_offset + bundle.key_limit_rel
        else
            bundle.key_start;

        if (count > index_16bit_top) {
            const sixteen_top = bundle.indexes[index_16bit_top];
            if (sixteen_top > keys_top and sixteen_top >= 0) {
                bundle.sixteen_start = root_offset + keys_top_usize * 4;
                bundle.sixteen_end = root_offset +
                    @as(usize, @intCast(sixteen_top)) * 4;
                if (bundle.sixteen_end > bytes.len) {
                    return error.InvalidFormat;
                }
            }
        }

        if (version_major >= 3) {
            bundle.pool_string_index_limit = @intCast(
                @as(u32, @bitCast(bundle.indexes[index_length])) >> 8,
            );
        }
        if (count > index_attributes) {
            const attributes = bundle.indexes[index_attributes];
            const attribute_bits: u32 = @bitCast(attributes);
            bundle.no_fallback =
                (attributes & attribute_no_fallback) != 0;
            bundle.is_pool_bundle =
                (attributes & attribute_is_pool_bundle) != 0;
            bundle.uses_pool_bundle =
                (attributes & attribute_uses_pool_bundle) != 0;
            bundle.pool_string_index_limit |=
                @intCast((attribute_bits & 0xf000) << 12);
            bundle.pool_string_index16_limit =
                @intCast(attribute_bits >> 16);
        }
        if ((bundle.is_pool_bundle or bundle.uses_pool_bundle) and
            count <= index_pool_checksum)
        {
            return error.InvalidFormat;
        }
        if (count > index_pool_checksum) {
            bundle.pool_checksum = bundle.indexes[index_pool_checksum];
        }
        return bundle;
    }

    /// Parses a `.res` file that references a pool bundle.
    pub fn initWithPool(
        bytes: []const u8,
        pool_bytes: []const u8,
    ) Error!ResourceBundle {
        var bundle = try init(bytes);
        const pool_bundle = try init(pool_bytes);
        if (!pool_bundle.is_pool_bundle) return error.InvalidFormat;
        if (bundle.pool_checksum != 0 and pool_bundle.pool_checksum != 0 and
            bundle.pool_checksum != pool_bundle.pool_checksum)
        {
            return error.InvalidFormat;
        }
        bundle.pool = .{
            .bytes = pool_bundle.bytes,
            .endian = pool_bundle.endian,
            .key_start = pool_bundle.key_start,
            .key_end = pool_bundle.key_end,
            .sixteen_start = pool_bundle.sixteen_start,
            .sixteen_end = pool_bundle.sixteen_end,
            .checksum = pool_bundle.pool_checksum,
        };
        return bundle;
    }

    pub fn root(self: *const ResourceBundle) Value {
        return self.decode(self.root_handle) catch .none;
    }

    fn u16At(self: *const ResourceBundle, offset: usize) ?u16 {
        return readU16At(self.bytes, offset, self.endian);
    }

    fn u32At(self: *const ResourceBundle, offset: usize) ?u32 {
        return readU32At(self.bytes, offset, self.endian);
    }

    fn i32At(self: *const ResourceBundle, offset: usize) ?i32 {
        return readI32At(self.bytes, offset, self.endian);
    }

    fn sixteenOffset(self: *const ResourceBundle, unit_index: u32) ?usize {
        const index: usize = @intCast(unit_index);
        const offset = self.sixteen_start + index * 2;
        if (offset > self.sixteen_end or self.sixteen_end - offset < 2) {
            return null;
        }
        return offset;
    }

    fn keyAtLocal(self: *const ResourceBundle, key_offset: usize) ?[]const u8 {
        var bytes = self.bytes;
        var start: usize = undefined;
        var limit: usize = undefined;
        if (key_offset < self.key_limit_rel) {
            start = self.root_offset + key_offset;
            limit = self.key_end;
        } else {
            const pool = self.pool orelse return null;
            bytes = pool.bytes;
            start = pool.key_start + (key_offset - self.key_limit_rel);
            limit = pool.key_end;
        }
        if (start >= limit or limit > bytes.len) return null;
        var end = start;
        while (end < limit and bytes[end] != 0) end += 1;
        if (end >= limit) return null;
        return bytes[start..end];
    }

    fn keyAt32(self: *const ResourceBundle, key_offset: i32) ?[]const u8 {
        if (key_offset >= 0) return self.keyAtLocal(@intCast(key_offset));
        const pool = self.pool orelse return null;
        const start = pool.key_start +
            (@as(u32, @bitCast(key_offset)) & 0x7fffffff);
        if (start >= pool.key_end or pool.key_end > pool.bytes.len) {
            return null;
        }
        var end = start;
        while (end < pool.key_end and pool.bytes[end] != 0) end += 1;
        if (end >= pool.key_end) return null;
        return pool.bytes[start..end];
    }

    fn tableCount(self: *const ResourceBundle, handle: u32) ?usize {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_table => {
                if (offset == 0) return 0;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.u16At(base) orelse return null;
                return @as(usize, count);
            },
            type_table16 => {
                const base = self.sixteenOffset(offset) orelse return null;
                const count = self.u16At(base) orelse return null;
                return @as(usize, count);
            },
            type_table32 => {
                if (offset == 0) return 0;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.i32At(base) orelse return null;
                if (count < 0) return null;
                return @intCast(count);
            },
            else => return null,
        }
    }

    fn tableKeyAt(
        self: *const ResourceBundle,
        handle: u32,
        index: usize,
    ) ?[]const u8 {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_table => {
                if (offset == 0) return null;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.u16At(base) orelse return null;
                if (index >= count) return null;
                const key_offset =
                    self.u16At(base + 2 + index * 2) orelse return null;
                return self.keyAtLocal(key_offset);
            },
            type_table16 => {
                const base = self.sixteenOffset(offset) orelse return null;
                const count = self.u16At(base) orelse return null;
                if (index >= count) return null;
                const key_offset =
                    self.u16At(base + 2 + index * 2) orelse return null;
                return self.keyAtLocal(key_offset);
            },
            type_table32 => {
                if (offset == 0) return null;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.i32At(base) orelse return null;
                if (count < 0 or index >= @as(usize, @intCast(count))) {
                    return null;
                }
                const key_offset =
                    self.i32At(base + 4 + index * 4) orelse return null;
                return self.keyAt32(key_offset);
            },
            else => return null,
        }
    }

    fn tableValueAt(
        self: *const ResourceBundle,
        handle: u32,
        index: usize,
    ) ?Value {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_table => {
                if (offset == 0) return null;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.u16At(base) orelse return null;
                if (index >= count) return null;
                const padding: usize = if (count % 2 == 0) 2 else 0;
                const value_offset =
                    base + 2 + @as(usize, count) * 2 + padding + index * 4;
                const value = self.u32At(value_offset) orelse return null;
                return self.decode(value) catch null;
            },
            type_table16 => {
                const base = self.sixteenOffset(offset) orelse return null;
                const count = self.u16At(base) orelse return null;
                if (index >= count) return null;
                const value_offset =
                    base + 2 + @as(usize, count) * 2 + index * 2;
                const value = self.u16At(value_offset) orelse return null;
                return self.decode(self.resourceFrom16(value)) catch null;
            },
            type_table32 => {
                if (offset == 0) return null;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.i32At(base) orelse return null;
                if (count < 0 or index >= @as(usize, @intCast(count))) {
                    return null;
                }
                const value_offset =
                    base + 4 + @as(usize, @intCast(count)) * 4 + index * 4;
                const value = self.u32At(value_offset) orelse return null;
                return self.decode(value) catch null;
            },
            else => return null,
        }
    }

    fn tableGet(
        self: *const ResourceBundle,
        handle: u32,
        key: []const u8,
    ) ?Value {
        const count = self.tableCount(handle) orelse return null;
        var start: usize = 0;
        var limit: usize = count;
        while (start < limit) {
            const mid = start + (limit - start) / 2;
            const table_key = self.tableKeyAt(handle, mid) orelse return null;
            switch (std.mem.order(u8, key, table_key)) {
                .lt => limit = mid,
                .gt => start = mid + 1,
                .eq => return self.tableValueAt(handle, mid),
            }
        }
        return null;
    }

    fn arrayCount(self: *const ResourceBundle, handle: u32) ?usize {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_array => {
                if (offset == 0) return 0;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.i32At(base) orelse return null;
                if (count < 0) return null;
                return @intCast(count);
            },
            type_array16 => {
                const base = self.sixteenOffset(offset) orelse return null;
                const count = self.u16At(base) orelse return null;
                return @as(usize, count);
            },
            else => return null,
        }
    }

    fn arrayAt(self: *const ResourceBundle, handle: u32, index: usize) ?Value {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_array => {
                if (offset == 0) return null;
                const base = self.root_offset + @as(usize, offset) * 4;
                const count = self.i32At(base) orelse return null;
                if (count < 0 or index >= @as(usize, @intCast(count))) {
                    return null;
                }
                const value = self.u32At(base + 4 + index * 4) orelse
                    return null;
                return self.decode(value) catch null;
            },
            type_array16 => {
                const base = self.sixteenOffset(offset) orelse return null;
                const count = self.u16At(base) orelse return null;
                if (index >= count) return null;
                const value = self.u16At(base + 2 + index * 2) orelse
                    return null;
                return self.decode(self.resourceFrom16(value)) catch null;
            },
            else => return null,
        }
    }

    fn resourceFrom16(self: *const ResourceBundle, value: u16) u32 {
        const res16: i32 = value;
        if (res16 < self.pool_string_index16_limit) {
            return (@as(u32, type_string_v2) << 28) |
                @as(u32, @intCast(res16));
        }
        const adjusted = res16 - self.pool_string_index16_limit +
            self.pool_string_index_limit;
        return (@as(u32, type_string_v2) << 28) |
            @as(u32, @intCast(adjusted));
    }

    fn stringAt(
        self: *const ResourceBundle,
        offset: u32,
        comptime expected_type: u32,
    ) Error!StringRef {
        if (offset == 0) {
            return .{
                .bytes = self.bytes,
                .unit_offset = 0,
                .len = 0,
                .endian = self.endian,
            };
        }
        const base = self.root_offset + @as(usize, offset) * 4;
        const length = self.i32At(base) orelse return error.InvalidFormat;
        if (length < 0) return error.InvalidFormat;
        const length_usize: usize = @intCast(length);
        const start = base + 4;
        if (start > self.bytes.len or
            length_usize * 2 > self.bytes.len - start)
        {
            return error.InvalidFormat;
        }
        _ = expected_type;
        return .{
            .bytes = self.bytes,
            .unit_offset = start,
            .len = length_usize,
            .endian = self.endian,
        };
    }

    fn stringV2(self: *const ResourceBundle, offset: u32) Error!StringRef {
        var bytes = self.bytes;
        var start: usize = undefined;
        var limit: usize = undefined;
        const offset_i32: i32 = @intCast(offset);
        if (offset_i32 < self.pool_string_index_limit) {
            const pool = self.pool orelse return error.InvalidFormat;
            bytes = pool.bytes;
            start = pool.sixteen_start + @as(usize, offset) * 2;
            limit = pool.sixteen_end;
        } else {
            const local_index: usize = @intCast(
                offset_i32 - self.pool_string_index_limit,
            );
            start = self.sixteen_start + local_index * 2;
            limit = self.sixteen_end;
        }
        if (start > limit or limit - start < 2) return error.InvalidFormat;

        const first = readU16At(bytes, start, self.endian) orelse
            return error.InvalidFormat;
        if (first < 0xDC00 or first > 0xDFFF) {
            var end = start;
            while (end + 2 <= limit) : (end += 2) {
                const unit = readU16At(bytes, end, self.endian) orelse
                    return error.InvalidFormat;
                if (unit == 0) {
                    return .{
                        .bytes = bytes,
                        .unit_offset = start,
                        .len = (end - start) / 2,
                        .endian = self.endian,
                    };
                }
            }
            return error.InvalidFormat;
        }
        if (first < 0xDFEF) {
            const length: usize = first & 0x3ff;
            const content = start + 2;
            if (content > limit or length * 2 > limit - content) {
                return error.InvalidFormat;
            }
            return .{
                .bytes = bytes,
                .unit_offset = content,
                .len = length,
                .endian = self.endian,
            };
        }
        if (first < 0xDFFF) {
            const second = readU16At(bytes, start + 2, self.endian) orelse
                return error.InvalidFormat;
            const length: usize = (@as(usize, first - 0xDFEF) << 16) | second;
            const content = start + 4;
            if (content > limit or length * 2 > limit - content) {
                return error.InvalidFormat;
            }
            return .{
                .bytes = bytes,
                .unit_offset = content,
                .len = length,
                .endian = self.endian,
            };
        }
        const second = readU16At(bytes, start + 2, self.endian) orelse
            return error.InvalidFormat;
        const third = readU16At(bytes, start + 4, self.endian) orelse
            return error.InvalidFormat;
        const length: usize = (@as(usize, second) << 16) | third;
        const content = start + 6;
        if (content > limit or length * 2 > limit - content) {
            return error.InvalidFormat;
        }
        return .{
            .bytes = bytes,
            .unit_offset = content,
            .len = length,
            .endian = self.endian,
        };
    }

    fn binaryAt(self: *const ResourceBundle, offset: u32) Error![]const u8 {
        if (offset == 0) return &.{};
        const base = self.root_offset + @as(usize, offset) * 4;
        const length = self.i32At(base) orelse return error.InvalidFormat;
        if (length < 0) return error.InvalidFormat;
        const length_usize: usize = @intCast(length);
        const start = base + 4;
        if (start > self.bytes.len or length_usize > self.bytes.len - start) {
            return error.InvalidFormat;
        }
        return self.bytes[start .. start + length_usize];
    }

    fn intVectorAt(
        self: *const ResourceBundle,
        offset: u32,
    ) Error!IntVectorRef {
        if (offset == 0) {
            return .{
                .bytes = self.bytes,
                .offset = 0,
                .len = 0,
                .endian = self.endian,
            };
        }
        const base = self.root_offset + @as(usize, offset) * 4;
        const length = self.i32At(base) orelse return error.InvalidFormat;
        if (length < 0) return error.InvalidFormat;
        const length_usize: usize = @intCast(length);
        const start = base + 4;
        if (start > self.bytes.len or
            length_usize * 4 > self.bytes.len - start)
        {
            return error.InvalidFormat;
        }
        return .{
            .bytes = self.bytes,
            .offset = start,
            .len = length_usize,
            .endian = self.endian,
        };
    }

    fn decode(self: *const ResourceBundle, handle: u32) Error!Value {
        const offset = handle & 0x0fffffff;
        switch (handle >> 28) {
            type_string => {
                return .{ .string = try self.stringAt(offset, type_string) };
            },
            type_binary => return .{ .binary = try self.binaryAt(offset) },
            type_table, type_table32, type_table16 => {
                return .{ .table = .{ .bundle = self, .handle = handle } };
            },
            type_alias => {
                return .{ .alias = try self.stringAt(offset, type_alias) };
            },
            type_string_v2 => {
                return .{ .string = try self.stringV2(offset) };
            },
            type_int => {
                const shifted: u32 = handle << 4;
                const signed: i32 = @bitCast(shifted);
                return .{ .int = signed >> 4 };
            },
            type_array, type_array16 => {
                return .{ .array = .{ .bundle = self, .handle = handle } };
            },
            type_int_vector => {
                return .{ .int_vector = try self.intVectorAt(offset) };
            },
            else => return error.InvalidFormat,
        }
    }

    fn resolveValue(
        self: *const ResourceBundle,
        value: Value,
        depth: usize,
    ) Error!Value {
        if (depth > 16) return error.InvalidAlias;
        return switch (value) {
            .alias => |alias| self.resolveAliasPath(alias, depth + 1),
            else => value,
        };
    }

    fn resolveAliasPath(
        self: *const ResourceBundle,
        alias: StringRef,
        depth: usize,
    ) Error!Value {
        if (depth > 16) return error.InvalidAlias;
        if (alias.len == 0) return error.InvalidAlias;
        var unit_index: usize = 0;
        var absolute = false;
        if (alias.at(0).? == '/') {
            absolute = true;
            unit_index = 1;
        }
        if (alias.len >= unit_index + 6 and
            matchesAscii(alias, unit_index, "LOCALE"))
        {
            unit_index += 6;
            if (unit_index >= alias.len or alias.at(unit_index).? != '/') {
                return error.InvalidAlias;
            }
            unit_index += 1;
            absolute = true;
        }
        if (!absolute) return error.ExternalAlias;

        var current = try self.decode(self.root_handle);
        while (unit_index < alias.len) {
            current = try self.resolveValue(current, depth + 1);
            const segment_start = unit_index;
            while (unit_index < alias.len and alias.at(unit_index).? != '/') {
                unit_index += 1;
            }
            const segment_length = unit_index - segment_start;
            if (segment_length == 0) return error.InvalidAlias;
            switch (current) {
                .table => |table| {
                    var buffer: [256]u8 = undefined;
                    if (segment_length > buffer.len) {
                        return error.InvalidAlias;
                    }
                    for (0..segment_length) |index| {
                        const unit = alias.at(segment_start + index).?;
                        if (unit > 0x7f) return error.InvalidAlias;
                        buffer[index] = @intCast(unit);
                    }
                    current = table.get(buffer[0..segment_length]) orelse
                        return error.NotFound;
                },
                .array => |array| {
                    var index: usize = 0;
                    for (0..segment_length) |offset| {
                        const unit = alias.at(segment_start + offset).?;
                        if (unit < '0' or unit > '9') {
                            return error.InvalidAlias;
                        }
                        index = index * 10 + (unit - '0');
                    }
                    current = array.at(index) orelse return error.NotFound;
                },
                else => return error.TypeMismatch,
            }
            if (unit_index < alias.len) unit_index += 1;
        }
        return self.resolveValue(current, depth + 1);
    }

    /// Resolves a `/`-separated path from the root, following aliases.
    pub fn find(self: *const ResourceBundle, path: []const u8) Error!Value {
        var current = try self.resolveValue(
            try self.decode(self.root_handle),
            0,
        );
        var iterator = std.mem.splitScalar(u8, path, '/');
        while (iterator.next()) |segment| {
            if (segment.len == 0) continue;
            current = try self.resolveValue(current, 0);
            switch (current) {
                .table => |table| {
                    current = table.get(segment) orelse return error.NotFound;
                },
                .array => |array| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch
                        return error.InvalidPath;
                    current = array.at(index) orelse return error.NotFound;
                },
                else => return error.TypeMismatch,
            }
        }
        return self.resolveValue(current, 0);
    }

    pub fn getString(
        self: *const ResourceBundle,
        path: []const u8,
    ) Error!StringRef {
        return switch (try self.find(path)) {
            .string => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getInt(self: *const ResourceBundle, path: []const u8) Error!i32 {
        return switch (try self.find(path)) {
            .int => |value| value,
            .uint => |value| @bitCast(value),
            else => error.TypeMismatch,
        };
    }

    pub fn getUInt(self: *const ResourceBundle, path: []const u8) Error!u32 {
        return switch (try self.find(path)) {
            .int => |value| @bitCast(value),
            .uint => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getBinary(
        self: *const ResourceBundle,
        path: []const u8,
    ) Error![]const u8 {
        return switch (try self.find(path)) {
            .binary => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getIntVector(
        self: *const ResourceBundle,
        path: []const u8,
    ) Error!IntVectorRef {
        return switch (try self.find(path)) {
            .int_vector => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getTable(
        self: *const ResourceBundle,
        path: []const u8,
    ) Error!Table {
        return switch (try self.find(path)) {
            .table => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn getArray(
        self: *const ResourceBundle,
        path: []const u8,
    ) Error!Array {
        return switch (try self.find(path)) {
            .array => |value| value,
            else => error.TypeMismatch,
        };
    }
};

fn matchesAscii(ref: StringRef, start: usize, text: []const u8) bool {
    if (start > ref.len or text.len > ref.len - start) return false;
    for (text, 0..) |byte, index| {
        if (ref.at(start + index).? != byte) return false;
    }
    return true;
}

fn expectRefEquals(
    ref: StringRef,
    expected: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const text = try ref.toUtf8Alloc(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "resource bundle scalar and container values" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const bytes = @embedFile("fixtures/root.res");
    const bundle = try ResourceBundle.init(bytes);

    try expectRefEquals(try bundle.getString("greeting"), "hello", allocator);
    try testing.expectEqual(@as(i32, 42), try bundle.getInt("count"));
    try testing.expectEqual(@as(i32, -7), try bundle.getInt("negative"));
    try testing.expectEqual(
        @as(u32, 123456789),
        try bundle.getUInt("big"),
    );
    try expectRefEquals(
        try bundle.getString("nested/sub"),
        "value",
        allocator,
    );
    try expectRefEquals(
        try bundle.getString("nested/deeper/inner"),
        "deep",
        allocator,
    );

    const strings = try bundle.getArray("strings");
    try testing.expectEqual(@as(usize, 3), strings.count());
    const expected_strings = [_][]const u8{ "a", "b", "c" };
    for (expected_strings, 0..) |expected, index| {
        const value = strings.at(index) orelse return error.TestUnexpectedResult;
        try expectRefEquals(value.string, expected, allocator);
    }
    try testing.expectEqual(@as(?Value, null), strings.at(3));

    const ints = try bundle.getIntVector("ints");
    try testing.expectEqual(@as(usize, 4), ints.len);
    try testing.expectEqual(@as(?i32, 1), ints.at(0));
    try testing.expectEqual(@as(?i32, 2), ints.at(1));
    try testing.expectEqual(@as(?i32, 3), ints.at(2));
    try testing.expectEqual(@as(?i32, -4), ints.at(3));
    try testing.expectEqual(@as(?i32, null), ints.at(4));

    const data = try bundle.getBinary("data");
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x01, 0x02, 0xfe, 0xff },
        data,
    );

    try expectRefEquals(
        try bundle.getString("aliasClient"),
        "aliased",
        allocator,
    );
    try expectRefEquals(
        try bundle.getString("unicode"),
        "\u{e9}\u{65e5}\u{1f600}",
        allocator,
    );
    try expectRefEquals(
        try bundle.getString("shared"),
        "common value",
        allocator,
    );
}

test "resource bundle table iteration and raw aliases" {
    const testing = @import("std").testing;
    const bytes = @embedFile("fixtures/root.res");
    const bundle = try ResourceBundle.init(bytes);

    const root_table = switch (bundle.root()) {
        .table => |table| table,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 12), root_table.count());
    try testing.expectEqualStrings("aliasClient", root_table.keyAt(0).?);
    try testing.expectEqualStrings("aliasTarget", root_table.keyAt(1).?);
    try testing.expectEqualStrings("big", root_table.keyAt(2).?);

    const alias_value = root_table.valueAt(0) orelse
        return error.TestUnexpectedResult;
    switch (alias_value) {
        .alias => |alias| try testing.expect(
            alias.eqlAscii("/LOCALE/aliasTarget"),
        ),
        else => return error.TestUnexpectedResult,
    }

    const count_value = root_table.get("count") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 42), count_value.int);

    const nested = try bundle.getTable("nested");
    try testing.expectEqual(@as(usize, 2), nested.count());
    try testing.expectEqualStrings("deeper", nested.keyAt(0).?);
    try testing.expectEqualStrings("sub", nested.keyAt(1).?);
}

test "resource bundle 16-bit tables and pool bundles" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    const en_bytes = @embedFile("fixtures/en.res");
    const en = try ResourceBundle.init(en_bytes);
    try expectRefEquals(try en.getString("greeting"), "hi", allocator);
    try expectRefEquals(
        try en.getString("extra"),
        "english only",
        allocator,
    );
    try expectRefEquals(
        try en.getString("shared"),
        "common value",
        allocator,
    );
    const en_root = switch (en.root()) {
        .table => |table| table,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 3), en_root.count());

    const en_us_bytes = @embedFile("fixtures/en_US.res");
    const en_us = try ResourceBundle.init(en_us_bytes);
    try expectRefEquals(
        try en_us.getString("greeting"),
        "howdy",
        allocator,
    );

    const pool_bytes = @embedFile("fixtures/pool.res");
    const pooled_bytes = @embedFile("fixtures/pooled_root.res");
    const pooled = try ResourceBundle.initWithPool(pooled_bytes, pool_bytes);
    try expectRefEquals(
        try pooled.getString("greeting"),
        "hello",
        allocator,
    );
    try testing.expectEqual(@as(i32, 42), try pooled.getInt("count"));
    try expectRefEquals(
        try pooled.getString("aliasClient"),
        "aliased",
        allocator,
    );
    try expectRefEquals(
        try pooled.getString("shared"),
        "common value",
        allocator,
    );
    try expectRefEquals(
        try pooled.getString("nested/deeper/inner"),
        "deep",
        allocator,
    );

    const pooled_en_bytes = @embedFile("fixtures/pooled_en.res");
    const pooled_en = try ResourceBundle.initWithPool(
        pooled_en_bytes,
        pool_bytes,
    );
    try expectRefEquals(
        try pooled_en.getString("greeting"),
        "hi",
        allocator,
    );
    try expectRefEquals(
        try pooled_en.getString("shared"),
        "common value",
        allocator,
    );
}

test "resource bundle lookup errors" {
    const testing = @import("std").testing;
    const bytes = @embedFile("fixtures/root.res");
    const bundle = try ResourceBundle.init(bytes);

    try testing.expectError(error.NotFound, bundle.find("missing"));
    try testing.expectError(error.NotFound, bundle.find("strings/9"));
    try testing.expectError(error.InvalidPath, bundle.find("strings/x"));
    try testing.expectError(error.TypeMismatch, bundle.getString("count"));
    try testing.expectError(error.TypeMismatch, bundle.getInt("greeting"));
    try testing.expectError(error.TypeMismatch, bundle.getArray("greeting"));

    try testing.expectError(error.InvalidFormat, ResourceBundle.init(&.{}));
    var broken = [_]u8{0} ** 32;
    broken[2] = 0xda;
    broken[3] = 0x27;
    try testing.expectError(error.InvalidFormat, ResourceBundle.init(&broken));
}

test "ICU resource bundle conformance fixture" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;
    const fixture = @embedFile("res_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJGM", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const record_count = std.mem.readInt(u32, fixture[8..12], .little);

    const pool_bytes = @embedFile("fixtures/pool.res");
    var bundles: [6]ResourceBundle = undefined;
    bundles[0] = try ResourceBundle.init(@embedFile("fixtures/root.res"));
    bundles[1] = try ResourceBundle.init(@embedFile("fixtures/en.res"));
    bundles[2] = try ResourceBundle.init(@embedFile("fixtures/en_US.res"));
    bundles[3] = try ResourceBundle.initWithPool(
        @embedFile("fixtures/pooled_root.res"),
        pool_bytes,
    );
    bundles[4] = try ResourceBundle.initWithPool(
        @embedFile("fixtures/pooled_en.res"),
        pool_bytes,
    );
    bundles[5] = try ResourceBundle.initWithPool(
        @embedFile("fixtures/pooled_en_US.res"),
        pool_bytes,
    );

    var cursor: usize = 12;
    var failures: usize = 0;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const bundle_index = fixture[cursor];
        cursor += 1;
        const kind = fixture[cursor];
        cursor += 1;
        const path_length = std.mem.readInt(
            u16,
            fixture[cursor..][0..2],
            .little,
        );
        cursor += 2;
        const path = fixture[cursor..][0..path_length];
        cursor += path_length;
        if (bundle_index >= bundles.len) return error.InvalidFixture;
        const bundle = &bundles[bundle_index];

        switch (kind) {
            0 => {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const expected_ref = StringRef{
                    .bytes = fixture,
                    .unit_offset = cursor,
                    .len = length,
                    .endian = .little,
                };
                cursor += @as(usize, length) * 2;
                const expected = try expected_ref.toUtf8Alloc(allocator);
                defer allocator.free(expected);
                const actual_ref = bundle.getString(path) catch {
                    failures += 1;
                    std.debug.print("resource string missing: bundle {d} path [{s}]\n", .{ bundle_index, path });
                    continue;
                };
                const actual = try actual_ref.toUtf8Alloc(allocator);
                defer allocator.free(actual);
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "resource string mismatch: bundle {d} path [{s}] got [{s}] want [{s}]\n",
                            .{ bundle_index, path, actual, expected },
                        );
                    }
                }
            },
            1 => {
                const expected = std.mem.readInt(
                    i32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const actual = bundle.getInt(path) catch {
                    failures += 1;
                    std.debug.print("resource int missing: bundle {d} path [{s}]\n", .{ bundle_index, path });
                    continue;
                };
                if (actual != expected) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "resource int mismatch: bundle {d} path [{s}] got {d} want {d}\n",
                            .{ bundle_index, path, actual, expected },
                        );
                    }
                }
            },
            2 => {
                const expected = std.mem.readInt(
                    u32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const actual = bundle.getUInt(path) catch {
                    failures += 1;
                    std.debug.print("resource uint missing: bundle {d} path [{s}]\n", .{ bundle_index, path });
                    continue;
                };
                if (actual != expected) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "resource uint mismatch: bundle {d} path [{s}] got {d} want {d}\n",
                            .{ bundle_index, path, actual, expected },
                        );
                    }
                }
            },
            3 => {
                const length = std.mem.readInt(
                    u32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const expected = fixture[cursor..][0..length];
                cursor += length;
                const actual = bundle.getBinary(path) catch {
                    failures += 1;
                    std.debug.print("resource binary missing: bundle {d} path [{s}]\n", .{ bundle_index, path });
                    continue;
                };
                if (!std.mem.eql(u8, actual, expected)) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "resource binary mismatch: bundle {d} path [{s}]\n",
                            .{ bundle_index, path },
                        );
                    }
                }
            },
            4 => {
                const length = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const actual = bundle.getIntVector(path) catch {
                    failures += 1;
                    std.debug.print(
                        "resource int vector missing: bundle {d} path [{s}]\n",
                        .{ bundle_index, path },
                    );
                    cursor += @as(usize, length) * 4;
                    continue;
                };
                if (actual.len != length) {
                    failures += 1;
                    std.debug.print(
                        "resource int vector length: bundle {d} path [{s}] got {d} want {d}\n",
                        .{ bundle_index, path, actual.len, length },
                    );
                } else {
                    var index: usize = 0;
                    while (index < length) : (index += 1) {
                        const expected = std.mem.readInt(
                            i32,
                            fixture[cursor..][0..4],
                            .little,
                        );
                        cursor += 4;
                        if (actual.at(index).? != expected) {
                            failures += 1;
                            std.debug.print(
                                "resource int vector value: bundle {d} path [{s}] index {d} got {d} want {d}\n",
                                .{
                                    bundle_index,
                                    path,
                                    index,
                                    actual.at(index).?,
                                    expected,
                                },
                            );
                        }
                    }
                }
            },
            5 => {
                const count = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const array = bundle.getArray(path) catch {
                    failures += 1;
                    std.debug.print(
                        "resource array missing: bundle {d} path [{s}]\n",
                        .{ bundle_index, path },
                    );
                    continue;
                };
                if (array.count() != count) {
                    failures += 1;
                    std.debug.print(
                        "resource array length: bundle {d} path [{s}] got {d} want {d}\n",
                        .{ bundle_index, path, array.count(), count },
                    );
                }
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    const length = std.mem.readInt(
                        u16,
                        fixture[cursor..][0..2],
                        .little,
                    );
                    cursor += 2;
                    const expected_ref = StringRef{
                        .bytes = fixture,
                        .unit_offset = cursor,
                        .len = length,
                        .endian = .little,
                    };
                    cursor += @as(usize, length) * 2;
                    const expected = try expected_ref.toUtf8Alloc(allocator);
                    defer allocator.free(expected);
                    const value = array.at(index) orelse {
                        failures += 1;
                        std.debug.print("resource array item missing: bundle {d} path [{s}] index {d}\n", .{ bundle_index, path, index });
                        continue;
                    };
                    const actual = try value.string.toUtf8Alloc(allocator);
                    defer allocator.free(actual);
                    if (!std.mem.eql(u8, actual, expected)) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "resource array mismatch: bundle {d} path [{s}] index {d} got [{s}] want [{s}]\n",
                                .{
                                    bundle_index,
                                    path,
                                    index,
                                    actual,
                                    expected,
                                },
                            );
                        }
                    }
                }
            },
            6 => {
                const count = std.mem.readInt(
                    u16,
                    fixture[cursor..][0..2],
                    .little,
                );
                cursor += 2;
                const table = bundle.getTable(path) catch {
                    failures += 1;
                    std.debug.print(
                        "resource table missing: bundle {d} path [{s}]\n",
                        .{ bundle_index, path },
                    );
                    continue;
                };
                if (table.count() != count) {
                    failures += 1;
                    std.debug.print(
                        "resource table length: bundle {d} path [{s}] got {d} want {d}\n",
                        .{ bundle_index, path, table.count(), count },
                    );
                }
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    const length = std.mem.readInt(
                        u16,
                        fixture[cursor..][0..2],
                        .little,
                    );
                    cursor += 2;
                    const expected = fixture[cursor..][0..length];
                    cursor += length;
                    const actual = table.keyAt(index) orelse {
                        failures += 1;
                        std.debug.print("resource key missing: bundle {d} path [{s}] index {d}\n", .{ bundle_index, path, index });
                        continue;
                    };
                    if (!std.mem.eql(u8, actual, expected)) {
                        failures += 1;
                        if (failures <= 10) {
                            std.debug.print(
                                "resource key mismatch: bundle {d} path [{s}] index {d} got [{s}] want [{s}]\n",
                                .{
                                    bundle_index,
                                    path,
                                    index,
                                    actual,
                                    expected,
                                },
                            );
                        }
                    }
                }
            },
            else => return error.InvalidFixture,
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "resource bundle conformance: {d} records passed\n",
        .{record_count},
    );
}
