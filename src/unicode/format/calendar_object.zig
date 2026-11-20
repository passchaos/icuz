//! ICU `ucal`-compatible mutable calendar object.
//!
//! Field values follow ICU's `UCalendarDateFields` conventions: months are
//! 0-based, days of the week are 1 (Sunday) through 7 (Saturday), and times
//! are resolved through the zone's daylight-saving transitions.

const std = @import("std");
const systems = @import("calendar.zig");
const timezone = @import("../timezone/root.zig");

pub const Error = error{ InvalidZone, Unsupported };

pub const Field = enum(u8) {
    era = 0,
    year = 1,
    month = 2,
    week_of_year = 3,
    week_of_month = 4,
    date = 5,
    day_of_year = 6,
    day_of_week = 7,
    day_of_week_in_month = 8,
    am_pm = 9,
    hour = 10,
    hour_of_day = 11,
    minute = 12,
    second = 13,
    millisecond = 14,
    zone_offset = 15,
    dst_offset = 16,
    year_woy = 17,
    dow_local = 18,
    extended_year = 19,
    julian_day = 20,
    milliseconds_in_day = 21,
    is_leap_month = 22,
};

const Local = struct {
    days: i64,
    milliseconds_of_day: i64,
    offset: timezone.Offset,
};

pub const WeekData = struct {
    /// ICU `UCAL_FIRST_DAY_OF_WEEK`: 1 = Sunday through 7 = Saturday.
    first_day: u8 = 1,
    minimal_days: u8 = 1,
};

pub const Calendar = struct {
    system: systems.Calendar,
    zone: timezone.Zone,
    week: WeekData = .{},
    millis: i64 = 0,

    pub fn init(system: systems.Calendar, zone_id: []const u8) Error!Calendar {
        const zone = timezone.find(zone_id) orelse return error.InvalidZone;
        return .{ .system = system, .zone = zone };
    }

    pub fn initUtc(system: systems.Calendar) Calendar {
        return .{
            .system = system,
            .zone = .{
                .id = "UTC",
                .first_transition = 0,
                .transition_count = 0,
            },
        };
    }

    pub fn zoneId(self: Calendar) []const u8 {
        return self.zone.id;
    }

    pub fn setWeekData(
        self: *Calendar,
        first_day: u8,
        minimal_days: u8,
    ) void {
        self.week = .{
            .first_day = @min(@max(first_day, 1), 7),
            .minimal_days = @min(@max(minimal_days, 1), 7),
        };
    }

    fn absoluteDayOfWeek(days: i64) i32 {
        return @intCast(@mod(days + 4, 7) + 1);
    }

    fn dayOfWeekLocal(self: Calendar, days: i64) i32 {
        return @intCast(@mod(
            absoluteDayOfWeek(days) - @as(i32, self.week.first_day) + 7,
            7,
        ) + 1);
    }

    fn weekOfMonth(
        self: Calendar,
        date: systems.Date,
        hint: i64,
    ) i32 {
        const month_start = self.daysFor(.{
            .era = date.era,
            .year = date.year,
            .month = date.month,
            .day = 1,
        }, hint) orelse return 0;
        const offset = @mod(
            absoluteDayOfWeek(month_start) -
                @as(i32, self.week.first_day) + 7,
            7,
        );
        var week = @divFloor(
            @as(i64, date.day) - 1 + offset,
            7,
        ) + 1;
        if (week == 1 and
            7 - offset < @as(i32, self.week.minimal_days))
        {
            week = 0;
        }
        return @intCast(week);
    }

    fn gregorianExtendedYear(days: i64) i32 {
        const gregorian = systems.fromDays(.gregorian, days);
        return if (gregorian.era == 0) 1 - gregorian.year else gregorian.year;
    }

    fn yearOfWeek(self: Calendar, date: systems.Date, days: i64) i32 {
        const info = self.weekOfYear(date, days);
        return switch (self.system) {
            .gregorian, .iso8601 => info.year,
            .buddhist => info.year - 543,
            .roc => if (date.era == 0)
                1912 - info.year
            else
                1911 + info.year,
            .japanese => blk: {
                const start = systems.daysFromDate(.japanese, .{
                    .era = date.era,
                    .year = info.year,
                    .month = 1,
                    .day = 1,
                }) orelse break :blk info.year;
                break :blk systems.fromDays(.gregorian, start).year;
            },
            .chinese => gregorianExtendedYear(days),
            else => info.year,
        };
    }

    const WeekOfYear = struct { week: i32, year: i32 };

    fn weekOfYear(
        self: Calendar,
        date: systems.Date,
        hint: i64,
    ) WeekOfYear {
        const year_start = self.daysFor(.{
            .era = date.era,
            .year = date.year,
            .month = 1,
            .day = 1,
        }, hint) orelse return .{ .week = 0, .year = date.year };
        const offset = @mod(
            absoluteDayOfWeek(year_start) -
                @as(i32, self.week.first_day) + 7,
            7,
        );
        var week1_start = year_start - offset;
        if (7 - offset < @as(i32, self.week.minimal_days)) {
            week1_start += 7;
        }

        if (self.daysFor(.{
            .era = date.era,
            .year = date.year + 1,
            .month = 1,
            .day = 1,
        }, hint)) |next_start| {
            const next_offset = @mod(
                absoluteDayOfWeek(next_start) -
                    @as(i32, self.week.first_day) + 7,
                7,
            );
            var next_week1 = next_start - next_offset;
            if (7 - next_offset < @as(i32, self.week.minimal_days)) {
                next_week1 += 7;
            }
            if (hint >= next_week1) {
                return .{ .week = 1, .year = date.year + 1 };
            }
        }

        if (hint < week1_start) {
            if (self.daysFor(.{
                .era = date.era,
                .year = date.year - 1,
                .month = 1,
                .day = 1,
            }, hint)) |previous_start| {
                const previous_offset = @mod(
                    absoluteDayOfWeek(previous_start) -
                        @as(i32, self.week.first_day) + 7,
                    7,
                );
                var previous_week1 = previous_start - previous_offset;
                if (7 - previous_offset <
                    @as(i32, self.week.minimal_days))
                {
                    previous_week1 += 7;
                }
                return .{
                    .week = @intCast(@divFloor(
                        hint - previous_week1,
                        7,
                    ) + 1),
                    .year = date.year - 1,
                };
            }
        }
        return .{
            .week = @intCast(@divFloor(hint - week1_start, 7) + 1),
            .year = date.year,
        };
    }

    pub fn setMillis(self: *Calendar, millis: i64) void {
        self.millis = millis;
    }

    pub fn getMillis(self: Calendar) i64 {
        return self.millis;
    }

    fn standardOffset(self: Calendar, unix_seconds: i64) i32 {
        const current = timezone.offsetAt(self.zone, unix_seconds);
        if (!current.daylight) return current.seconds;
        var probe = unix_seconds;
        var count: usize = 0;
        while (count < 8) : (count += 1) {
            const previous = timezone.previousTransition(self.zone, probe) orelse
                break;
            const before = timezone.offsetAt(self.zone, previous.at - 1);
            if (!before.daylight) return before.seconds;
            probe = previous.at - 1;
        }
        return current.seconds - 3600;
    }

    fn localInfo(self: Calendar) Local {
        const unix_seconds = @divFloor(self.millis, 1000);
        const millis_remainder = @mod(self.millis, 1000);
        const offset = timezone.offsetAt(self.zone, unix_seconds);
        const local_seconds = unix_seconds + offset.seconds;
        const days = @divFloor(local_seconds, 86400);
        const second_of_day = local_seconds - days * 86400;
        return .{
            .days = days,
            .milliseconds_of_day = second_of_day * 1000 + millis_remainder,
            .offset = offset,
        };
    }

    fn setLocal(self: *Calendar, days: i64, milliseconds_of_day: i64) void {
        const day_adjust = @divFloor(milliseconds_of_day, 86400000);
        const normalized = @mod(milliseconds_of_day, 86400000);
        const local_days = days + day_adjust;
        const local_seconds = local_days * 86400 + @divFloor(normalized, 1000);
        const utc_seconds = timezone.utcSeconds(self.zone, local_seconds);
        self.millis = utc_seconds * 1000 + @mod(normalized, 1000);
    }

    fn dateFor(self: Calendar, days: i64) systems.Date {
        return systems.fromDays(self.system, days);
    }

    fn supportsMutation(self: Calendar) bool {
        _ = self;
        return true;
    }

    fn daysFor(
        self: Calendar,
        date: systems.Date,
        hint: i64,
    ) ?i64 {
        return systems.daysFromDateNear(self.system, date, hint);
    }

    fn monthsInYear(self: Calendar, date: systems.Date) i64 {
        return switch (self.system) {
            .coptic, .ethiopic, .ethiopic_amete_alem => 13,
            .hebrew, .chinese => if (date.leap_year) 13 else 12,
            else => 12,
        };
    }

    fn monthLength(
        self: Calendar,
        date: systems.Date,
        hint: i64,
    ) ?i64 {
        const first = self.daysFor(.{
            .era = date.era,
            .year = date.year,
            .month = date.month,
            .day = 1,
        }, hint) orelse return null;
        var year = date.year;
        var month: i32 = @as(i32, date.month) + 1;
        if (month > self.monthsInYear(date)) {
            month = 1;
            year += 1;
        }
        const next = self.daysFor(.{
            .era = date.era,
            .year = year,
            .month = @intCast(month),
            .day = 1,
        }, hint) orelse return null;
        return next - first;
    }

    fn dayOfYear(self: Calendar, days: i64, date: systems.Date) i32 {
        if (systems.daysFromDate(self.system, .{
            .era = date.era,
            .year = date.year,
            .month = 1,
            .day = 1,
        })) |first| {
            return @intCast(days - first + 1);
        }
        var cursor = days;
        var count: i32 = 1;
        while (count <= 400) : (count += 1) {
            const current = self.dateFor(cursor);
            if (current.month == 1 and current.day == 1) break;
            cursor -= 1;
        }
        return count;
    }

    /// ICU `ucal_get`.
    pub fn get(self: Calendar, field: Field) i32 {
        const local = self.localInfo();
        const date = self.dateFor(local.days);
        const hour_of_day: i32 = @intCast(
            @divFloor(local.milliseconds_of_day, 3600000),
        );
        const minute: i32 = @intCast(
            @divFloor(@mod(local.milliseconds_of_day, 3600000), 60000),
        );
        const second: i32 = @intCast(
            @divFloor(@mod(local.milliseconds_of_day, 60000), 1000),
        );
        const millisecond: i32 = @intCast(
            @mod(local.milliseconds_of_day, 1000),
        );
        return switch (field) {
            .era => @intCast(date.era),
            .year => date.year,
            .month => switch (self.system) {
                .hebrew => blk: {
                    const month: i32 = date.month;
                    if (date.leap_year) break :blk month - 1;
                    break :blk month - 1 + @intFromBool(month >= 6);
                },
                else => @as(i32, date.month) - 1,
            },
            .date => date.day,
            .day_of_year => self.dayOfYear(local.days, date),
            .day_of_week => absoluteDayOfWeek(local.days),
            .week_of_year => self.weekOfYear(date, local.days).week,
            .week_of_month => self.weekOfMonth(date, local.days),
            .day_of_week_in_month => @divTrunc(
                @as(i32, date.day) - 1,
                7,
            ) + 1,
            .year_woy => self.yearOfWeek(date, local.days),
            .dow_local => self.dayOfWeekLocal(local.days),
            .am_pm => @intFromBool(hour_of_day >= 12),
            .hour => @mod(hour_of_day, 12),
            .hour_of_day => hour_of_day,
            .minute => minute,
            .second => second,
            .millisecond => millisecond,
            .zone_offset => blk: {
                const unix_seconds = @divFloor(self.millis, 1000);
                break :blk self.standardOffset(unix_seconds) * 1000;
            },
            .dst_offset => blk: {
                const unix_seconds = @divFloor(self.millis, 1000);
                const standard = self.standardOffset(unix_seconds);
                break :blk (local.offset.seconds - standard) * 1000;
            },
            .extended_year => switch (self.system) {
                .gregorian,
                .iso8601,
                .buddhist,
                .japanese,
                .roc,
                .chinese,
                => gregorianExtendedYear(local.days),
                else => date.year,
            },
            .julian_day => @intCast(local.days + 2440588),
            .milliseconds_in_day => @intCast(local.milliseconds_of_day),
            .is_leap_month => @intFromBool(date.leap_month),
        };
    }

    /// ICU `ucal_set`.
    pub fn set(self: *Calendar, field: Field, value: i32) Error!void {
        if (!self.supportsMutation()) return error.Unsupported;
        const local = self.localInfo();
        var date = self.dateFor(local.days);
        var milliseconds_of_day = local.milliseconds_of_day;

        switch (field) {
            .era => {
                if ((self.system == .gregorian or self.system == .iso8601) and
                    value != date.era)
                {
                    date.year = 1 - date.year;
                }
                date.era = @intCast(@max(value, 0));
            },
            .year => date.year = value,
            .month => {
                var year = date.year;
                var month: i32 = value + 1;
                const months: i32 = @intCast(self.monthsInYear(date));
                while (month > months) {
                    month -= months;
                    year += 1;
                }
                while (month < 1) {
                    month += months;
                    year -= 1;
                }
                date.year = year;
                date.month = @intCast(month);
            },
            .date => {
                const first = self.daysFor(.{
                    .era = date.era,
                    .year = date.year,
                    .month = date.month,
                    .day = 1,
                }, local.days) orelse return error.Unsupported;
                self.setLocal(first + value - 1, milliseconds_of_day);
                return;
            },
            .am_pm => {
                const hour = @divFloor(milliseconds_of_day, 3600000);
                milliseconds_of_day =
                    (@mod(hour, 12) + @as(i64, value) * 12) * 3600000 +
                    @mod(milliseconds_of_day, 3600000);
            },
            .hour => {
                const hour = @divFloor(milliseconds_of_day, 3600000);
                milliseconds_of_day =
                    (hour - @mod(hour, 12) + value) * 3600000 +
                    @mod(milliseconds_of_day, 3600000);
            },
            .hour_of_day => {
                milliseconds_of_day =
                    @as(i64, value) * 3600000 +
                    @mod(milliseconds_of_day, 3600000);
            },
            .minute => {
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 3600000) * 3600000 +
                    @as(i64, value) * 60000 +
                    @mod(milliseconds_of_day, 60000);
            },
            .second => {
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 60000) * 60000 +
                    @as(i64, value) * 1000 +
                    @mod(milliseconds_of_day, 1000);
            },
            .millisecond => {
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 1000) * 1000 + value;
            },
            else => return error.Unsupported,
        }

        const days = self.daysFor(date, local.days) orelse
            return error.Unsupported;
        self.setLocal(days, milliseconds_of_day);
    }

    /// ICU `ucal_add`.
    pub fn add(self: *Calendar, field: Field, amount: i32) Error!void {
        if (!self.supportsMutation()) return error.Unsupported;
        const local = self.localInfo();
        var date = self.dateFor(local.days);
        var days = local.days;
        var milliseconds_of_day = local.milliseconds_of_day;

        switch (field) {
            .era => return error.Unsupported,
            .year => {
                date.year += amount;
                if (self.monthLength(date, local.days)) |length| {
                    if (date.day > length) date.day = @intCast(length);
                }
                days = self.daysFor(date, local.days) orelse
                    return error.Unsupported;
            },
            .month => {
                const months = self.monthsInYear(date);
                const total: i64 = @as(i64, date.year) * months +
                    (date.month - 1) + amount;
                date.year = @intCast(@divFloor(total, months));
                date.month = @intCast(@mod(total, months) + 1);
                if (self.monthLength(date, local.days)) |length| {
                    if (date.day > length) date.day = @intCast(length);
                }
                days = self.daysFor(date, local.days) orelse
                    return error.Unsupported;
            },
            .date, .day_of_year, .day_of_week, .dow_local => {
                days += @as(i64, amount);
            },
            .hour, .hour_of_day => {
                milliseconds_of_day += @as(i64, amount) * 3600000;
            },
            .minute => milliseconds_of_day += @as(i64, amount) * 60000,
            .second => milliseconds_of_day += @as(i64, amount) * 1000,
            .millisecond => milliseconds_of_day += @as(i64, amount),
            .am_pm => {
                milliseconds_of_day += @as(i64, amount) * 12 * 3600000;
            },
            else => return error.Unsupported,
        }
        self.setLocal(days, milliseconds_of_day);
    }

    /// ICU `ucal_roll`.
    pub fn roll(self: *Calendar, field: Field, amount: i32) Error!void {
        if (!self.supportsMutation()) return error.Unsupported;
        const local = self.localInfo();
        const date = self.dateFor(local.days);
        var days = local.days;
        var milliseconds_of_day = local.milliseconds_of_day;

        switch (field) {
            .month => {
                const months = self.monthsInYear(date);
                const month = @mod(@as(i64, date.month) - 1 + amount, months) + 1;
                var rolled = date;
                rolled.month = @intCast(month);
                if (self.monthLength(rolled, local.days)) |length| {
                    if (rolled.day > length) rolled.day = @intCast(length);
                }
                days = self.daysFor(rolled, local.days) orelse
                    return error.Unsupported;
            },
            .date => {
                const length = self.monthLength(date, local.days) orelse
                    return error.Unsupported;
                const day = @mod(@as(i64, date.day) - 1 + amount, length) + 1;
                var rolled = date;
                rolled.day = @intCast(day);
                days = self.daysFor(rolled, local.days) orelse
                    return error.Unsupported;
            },
            .hour, .hour_of_day => {
                const hour = @mod(
                    @divFloor(milliseconds_of_day, 3600000) + amount,
                    24,
                );
                milliseconds_of_day = hour * 3600000 +
                    @mod(milliseconds_of_day, 3600000);
            },
            .minute => {
                const minute = @mod(
                    @divFloor(@mod(milliseconds_of_day, 3600000), 60000) +
                        amount,
                    60,
                );
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 3600000) * 3600000 +
                    minute * 60000 +
                    @mod(milliseconds_of_day, 60000);
            },
            .second => {
                const second = @mod(
                    @divFloor(@mod(milliseconds_of_day, 60000), 1000) + amount,
                    60,
                );
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 60000) * 60000 +
                    second * 1000 +
                    @mod(milliseconds_of_day, 1000);
            },
            .millisecond => {
                const millisecond = @mod(
                    @mod(milliseconds_of_day, 1000) + @as(i64, amount),
                    1000,
                );
                milliseconds_of_day =
                    @divFloor(milliseconds_of_day, 1000) * 1000 + millisecond;
            },
            .am_pm => {
                const old_am_pm = @divFloor(milliseconds_of_day, 3600000) >= 12;
                const new_am_pm = @mod(
                    @as(i64, @intFromBool(old_am_pm)) + amount,
                    2,
                ) == 1;
                if (new_am_pm != old_am_pm) {
                    milliseconds_of_day += if (new_am_pm)
                        12 * 3600000
                    else
                        -12 * 3600000;
                }
            },
            else => return error.Unsupported,
        }
        self.setLocal(days, milliseconds_of_day);
    }
};

test "mutable calendar fields match ICU" {
    const testing = @import("std").testing;

    var calendar = Calendar.initUtc(.gregorian);
    calendar.setMillis(0);
    try testing.expectEqual(@as(i32, 1970), calendar.get(.year));
    try testing.expectEqual(@as(i32, 0), calendar.get(.month));
    try testing.expectEqual(@as(i32, 1), calendar.get(.date));
    try testing.expectEqual(@as(i32, 5), calendar.get(.day_of_week));
    try testing.expectEqual(@as(i32, 1), calendar.get(.day_of_year));

    calendar.setMillis(1_700_000_000_000);
    try testing.expectEqual(@as(i32, 2023), calendar.get(.year));
    try testing.expectEqual(@as(i32, 10), calendar.get(.month));
    try testing.expectEqual(@as(i32, 14), calendar.get(.date));

    try calendar.add(.month, 2);
    try testing.expectEqual(@as(i32, 2024), calendar.get(.year));
    try testing.expectEqual(@as(i32, 0), calendar.get(.month));
    try testing.expectEqual(@as(i32, 14), calendar.get(.date));

    try calendar.roll(.month, 14);
    try testing.expectEqual(@as(i32, 2), calendar.get(.month));
    try testing.expectEqual(@as(i32, 14), calendar.get(.date));

    try calendar.set(.date, 31);
    try testing.expectEqual(@as(i32, 31), calendar.get(.date));
}

const fixture_fields = [_]Field{
    .era,
    .year,
    .month,
    .week_of_year,
    .week_of_month,
    .date,
    .day_of_year,
    .day_of_week,
    .day_of_week_in_month,
    .am_pm,
    .hour,
    .hour_of_day,
    .minute,
    .second,
    .millisecond,
    .zone_offset,
    .year_woy,
    .dow_local,
    .extended_year,
    .julian_day,
    .milliseconds_in_day,
    .is_leap_month,
};

fn fieldFromByte(value: u8) ?Field {
    return switch (value) {
        0 => .era,
        1 => .year,
        2 => .month,
        3 => .week_of_year,
        4 => .week_of_month,
        5 => .date,
        6 => .day_of_year,
        7 => .day_of_week,
        8 => .day_of_week_in_month,
        9 => .am_pm,
        10 => .hour,
        11 => .hour_of_day,
        12 => .minute,
        13 => .second,
        14 => .millisecond,
        15 => .zone_offset,
        17 => .year_woy,
        18 => .dow_local,
        19 => .extended_year,
        20 => .julian_day,
        21 => .milliseconds_in_day,
        22 => .is_leap_month,
        else => null,
    };
}

test "ICU mutable calendar conformance fixture" {
    const testing = @import("std").testing;
    const fixture = @embedFile("calendar_object_conformance.bin");

    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJUC", fixture[0..4]);
    try testing.expectEqual(@as(u8, 1), fixture[4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);

    var cursor: usize = 12;
    var failures: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_count) : (case_index += 1) {
        const system_byte = fixture[cursor];
        const zone_len = fixture[cursor + 1];
        cursor += 2;
        const zone = fixture[cursor..][0..zone_len];
        cursor += zone_len;
        const first_day = fixture[cursor];
        const minimal_days = fixture[cursor + 1];
        const initial = std.mem.readInt(
            i64,
            fixture[cursor + 2 ..][0..8],
            .little,
        );
        cursor += 10;
        var calendar = Calendar.init(
            switch (system_byte) {
                0 => .gregorian,
                1 => .buddhist,
                2 => .japanese,
                3 => .roc,
                4 => .islamic_umalqura,
                5 => .persian,
                6 => .hebrew,
                7 => .indian,
                8 => .coptic,
                9 => .ethiopic,
                10 => .chinese,
                else => return error.InvalidFixture,
            },
            zone,
        ) catch return error.InvalidFixture;
        calendar.setWeekData(first_day, minimal_days);
        calendar.setMillis(initial);

        var field_index: usize = 0;
        while (field_index < fixture_fields.len) : (field_index += 1) {
            const expected = std.mem.readInt(
                i32,
                fixture[cursor..][0..4],
                .little,
            );
            cursor += 4;
            const actual = calendar.get(fixture_fields[field_index]);
            if (actual != expected) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "calendar initial mismatch: case {d} field {s} got {d} want {d}\n",
                        .{ case_index, @tagName(fixture_fields[field_index]), actual, expected },
                    );
                }
            }
        }

        const op_count = fixture[cursor];
        cursor += 1;
        var op_index: usize = 0;
        while (op_index < op_count) : (op_index += 1) {
            const opcode = fixture[cursor];
            const field_byte = fixture[cursor + 1];
            const amount = std.mem.readInt(
                i32,
                fixture[cursor + 2 ..][0..4],
                .little,
            );
            const expected_millis = std.mem.readInt(
                i64,
                fixture[cursor + 6 ..][0..8],
                .little,
            );
            cursor += 14;
            const field = fieldFromByte(field_byte) orelse
                return error.InvalidFixture;
            switch (opcode) {
                0 => calendar.set(field, amount) catch |err| {
                    std.debug.print(
                        "calendar set failed: case {d} op {d} field {s} amount {d} err {s}\n",
                        .{ case_index, op_index, @tagName(field), amount, @errorName(err) },
                    );
                    return error.InvalidFixture;
                },
                1 => calendar.add(field, amount) catch |err| {
                    std.debug.print(
                        "calendar add failed: case {d} op {d} field {s} amount {d} err {s}\n",
                        .{ case_index, op_index, @tagName(field), amount, @errorName(err) },
                    );
                    return error.InvalidFixture;
                },
                2 => calendar.roll(field, amount) catch |err| {
                    std.debug.print(
                        "calendar roll failed: case {d} op {d} field {s} amount {d} err {s}\n",
                        .{ case_index, op_index, @tagName(field), amount, @errorName(err) },
                    );
                    return error.InvalidFixture;
                },
                else => return error.InvalidFixture,
            }
            if (calendar.getMillis() != expected_millis) {
                failures += 1;
                if (failures <= 10) {
                    std.debug.print(
                        "calendar millis mismatch: case {d} op {d} got {d} want {d}\n",
                        .{ case_index, op_index, calendar.getMillis(), expected_millis },
                    );
                }
            }
            var value_index: usize = 0;
            while (value_index < fixture_fields.len) : (value_index += 1) {
                const expected = std.mem.readInt(
                    i32,
                    fixture[cursor..][0..4],
                    .little,
                );
                cursor += 4;
                const actual = calendar.get(fixture_fields[value_index]);
                if (actual != expected) {
                    failures += 1;
                    if (failures <= 10) {
                        std.debug.print(
                            "calendar field mismatch: case {d} op {d} field {s} got {d} want {d}\n",
                            .{
                                case_index,
                                op_index,
                                @tagName(fixture_fields[value_index]),
                                actual,
                                expected,
                            },
                        );
                    }
                }
            }
        }
    }
    try testing.expectEqual(fixture.len, cursor);
    try testing.expectEqual(@as(usize, 0), failures);
    std.debug.print(
        "mutable calendar conformance: {}/{} cases passed\n",
        .{ case_count - failures, case_count },
    );
}
