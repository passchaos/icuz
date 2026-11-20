//! ICU time scale conversions (`utmscale`).
//!
//! Universal time is the number of 100-nanosecond ticks since 0001-01-01.
//! Each scale converts to and from that representation using ICU's generated
//! constants, including the rounding rules for negative values.

const std = @import("std");

pub const Scale = enum(u8) {
    java = 0,
    unix = 1,
    icu4c = 2,
    windows_file = 3,
    dotnet = 4,
    mac_old = 5,
    mac_new = 6,
    excel = 7,
    db2 = 8,
    unix_microseconds = 9,
};

pub const Value = enum(u8) {
    units = 0,
    epoch_offset = 1,
    from_min = 2,
    from_max = 3,
    to_min = 4,
    to_max = 5,
    epoch_offset_plus_1 = 6,
    epoch_offset_minus_1 = 7,
    units_round = 8,
    min_round = 9,
    max_round = 10,
};

pub const Error = error{OutOfRange};

const ticks: i64 = 1;
const microseconds: i64 = ticks * 10;
const milliseconds: i64 = microseconds * 1000;
const seconds: i64 = milliseconds * 1000;
const minutes: i64 = seconds * 60;
const hours: i64 = minutes * 60;
const days: i64 = hours * 24;

const table = [10][11]i64{
    .{
        milliseconds, 62135596800000, -984472800485477, 860201606885477,
        -9223372036854774999, 9223372036854774999, 62135596800001,
        62135596799999, 5000, -9223372036854770808, 9223372036854770807,
    },
    .{
        seconds, 62135596800, -984472800485, 860201606885,
        std.math.minInt(i64), std.math.maxInt(i64), 62135596801,
        62135596799, 5000000, -9223372036849775808, 9223372036849775807,
    },
    .{
        milliseconds, 62135596800000, -984472800485477, 860201606885477,
        -9223372036854774999, 9223372036854774999, 62135596800001,
        62135596799999, 5000, -9223372036854770808, 9223372036854770807,
    },
    .{
        ticks, 504911232000000000, std.math.minInt(i64),
        8718460804854775807, -8718460804854775808, std.math.maxInt(i64),
        504911232000000000, 504911232000000000, 0, std.math.minInt(i64),
        std.math.maxInt(i64),
    },
    .{
        ticks, 0, std.math.minInt(i64), std.math.maxInt(i64),
        std.math.minInt(i64), std.math.maxInt(i64), 0, 0, 0,
        std.math.minInt(i64), std.math.maxInt(i64),
    },
    .{
        seconds, 60052752000, -982389955685, 862284451685,
        std.math.minInt(i64), std.math.maxInt(i64), 60052752001,
        60052751999, 5000000, -9223372036849775808, 9223372036849775807,
    },
    .{
        seconds, 63113904000, -985451107685, 859223299685,
        std.math.minInt(i64), std.math.maxInt(i64), 63113904001,
        63113903999, 5000000, -9223372036849775808, 9223372036849775807,
    },
    .{
        days, 693594, -11368793, 9981605, std.math.minInt(i64),
        std.math.maxInt(i64), 693595, 693593, 432000000000,
        -9223371604854775808, 9223371604854775807,
    },
    .{
        days, 693594, -11368793, 9981605, std.math.minInt(i64),
        std.math.maxInt(i64), 693595, 693593, 432000000000,
        -9223371604854775808, 9223371604854775807,
    },
    .{
        microseconds, 62135596800000000, -984472800485477580,
        860201606885477580, -9223372036854775804, 9223372036854775804,
        62135596800000001, 62135596799999999, 5,
        -9223372036854775803, 9223372036854775802,
    },
};

/// One of ICU's `UTimeScaleValue` constants for a scale.
pub fn value(scale: Scale, which: Value) i64 {
    return table[@intFromEnum(scale)][@intFromEnum(which)];
}

/// Convert a value in `scale` to universal 100-ns ticks since 0001-01-01.
pub fn fromInt64(other: i64, scale: Scale) Error!i64 {
    const data = &table[@intFromEnum(scale)];
    if (other < data[@intFromEnum(Value.from_min)] or
        other > data[@intFromEnum(Value.from_max)])
    {
        return error.OutOfRange;
    }
    return (other +% data[@intFromEnum(Value.epoch_offset)]) *%
        data[@intFromEnum(Value.units)];
}

/// Convert universal 100-ns ticks since 0001-01-01 to `scale`.
pub fn toInt64(universal: i64, scale: Scale) Error!i64 {
    const data = &table[@intFromEnum(scale)];
    if (universal < data[@intFromEnum(Value.to_min)] or
        universal > data[@intFromEnum(Value.to_max)])
    {
        return error.OutOfRange;
    }
    if (universal < 0) {
        if (universal < data[@intFromEnum(Value.min_round)]) {
            return @divTrunc(
                universal +% data[@intFromEnum(Value.units_round)],
                data[@intFromEnum(Value.units)],
            ) -% data[@intFromEnum(Value.epoch_offset_plus_1)];
        }
        return @divTrunc(
            universal -% data[@intFromEnum(Value.units_round)],
            data[@intFromEnum(Value.units)],
        ) -% data[@intFromEnum(Value.epoch_offset)];
    }
    if (universal > data[@intFromEnum(Value.max_round)]) {
        return @divTrunc(
            universal -% data[@intFromEnum(Value.units_round)],
            data[@intFromEnum(Value.units)],
        ) -% data[@intFromEnum(Value.epoch_offset_minus_1)];
    }
    return @divTrunc(
        universal +% data[@intFromEnum(Value.units_round)],
        data[@intFromEnum(Value.units)],
    ) -% data[@intFromEnum(Value.epoch_offset)];
}

test "time scale conversions" {
    const testing = @import("std").testing;
    try testing.expectEqual(
        @as(i64, 621355968000000000),
        try fromInt64(0, .unix),
    );
    try testing.expectEqual(@as(i64, 0), try toInt64(621355968000000000, .unix));
    try testing.expectEqual(
        @as(i64, 621355968000000000),
        try fromInt64(0, .java),
    );
    try testing.expectEqual(@as(i64, 0), try fromInt64(0, .dotnet));
    try testing.expectEqual(
        @as(i64, 504911232000000000),
        try fromInt64(0, .windows_file),
    );
    try testing.expectEqual(
        @as(i64, 600527520000000000),
        try fromInt64(0, .mac_old),
    );
    try testing.expectEqual(
        @as(i64, 631139040000000000),
        try fromInt64(0, .mac_new),
    );
    try testing.expectEqual(
        @as(i64, 599265216000000000),
        try fromInt64(0, .excel),
    );
    try testing.expectEqual(
        @as(i64, 123456789),
        try toInt64(try fromInt64(123456789, .unix), .unix),
    );
    try testing.expectError(error.OutOfRange, fromInt64(
        std.math.maxInt(i64),
        .excel,
    ));
}

const conformance = @embedFile("time_scale_conformance.bin");

test "time scale conformance" {
    const testing = @import("std").testing;
    try testing.expect(conformance.len >= 12);
    try testing.expectEqualSlices(u8, "CJTS", conformance[0..4]);
    const case_count = std.mem.readInt(u32, conformance[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    for (0..case_count) |_| {
        const kind = conformance[offset];
        const scale: Scale = @enumFromInt(conformance[offset + 1]);
        const input_value = std.mem.readInt(i64, conformance[offset + 4 ..][0..8], .little);
        const expected = std.mem.readInt(i64, conformance[offset + 12 ..][0..8], .little);
        offset += 20;
        const actual = if (kind == 0)
            try fromInt64(input_value, scale)
        else
            try toInt64(input_value, scale);
        if (actual != expected) {
            failures += 1;
            std.debug.print(
                "time scale mismatch kind={d} scale={d} value={d}: {d} != {d}\n",
                .{ kind, @intFromEnum(scale), input_value, actual, expected },
            );
        }
    }
    try testing.expectEqual(conformance.len, offset);
    try testing.expect(failures == 0);
}
