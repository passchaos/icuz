//! Non-Gregorian calendar conversions.
//!
//! The arithmetic follows ICU's calendar implementations (`islamcal.cpp`,
//! `persncal.cpp`, `indiancal.cpp`, `cecal.cpp`, `ethpccal.cpp`, and the
//! Gregorian-based calendars) so that computed fields match ICU for the same
//! instant. Era indices are CLDR era types.

const std = @import("std");
const chinese_calendar = @import("chinese_calendar.zig");

pub const Calendar = enum {
    gregorian,
    buddhist,
    japanese,
    roc,
    islamic_civil,
    islamic_tbla,
    islamic_umalqura,
    persian,
    indian,
    coptic,
    ethiopic,
    ethiopic_amete_alem,
    hebrew,
    chinese,
    iso8601,
};

pub const Date = struct {
    /// CLDR era type.
    era: u16,
    /// Year within the era (or extended year for single-era calendars).
    year: i32,
    /// 1-based month.
    month: u8,
    /// 1-based day of month.
    day: u8,
    /// True for leap months in lunisolar calendars.
    leap_month: bool = false,
    /// True when the containing year is a leap year (Hebrew/Chinese).
    leap_year: bool = false,
};

const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
};

/// Days since 1970-01-01 for a proleptic Gregorian date.
pub fn daysFromGregorian(year: i32, month: u8, day: u8) i64 {
    var y: i64 = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Proleptic Gregorian date for days since 1970-01-01.
pub fn gregorianFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(
        doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096),
        365,
    );
    const year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{
        .year = @intCast(if (month <= 2) year + 1 else year),
        .month = month,
        .day = day,
    };
}

fn isGregorianLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

const julian_epoch = 2440588;

fn julianDay(days: i64) i64 {
    return days + julian_epoch;
}

const japanese_eras = [_]struct {
    start: i64,
    start_year: i32,
    type: u16,
}{
    .{ .start = daysFromGregorian(1868, 10, 23), .start_year = 1868, .type = 232 },
    .{ .start = daysFromGregorian(1912, 7, 30), .start_year = 1912, .type = 233 },
    .{ .start = daysFromGregorian(1926, 12, 25), .start_year = 1926, .type = 234 },
    .{ .start = daysFromGregorian(1989, 1, 8), .start_year = 1989, .type = 235 },
    .{ .start = daysFromGregorian(2019, 5, 1), .start_year = 2019, .type = 236 },
};

fn japaneseDate(days: i64, civil: Civil) Date {
    var index = japanese_eras.len;
    while (index > 0) {
        index -= 1;
        const era = japanese_eras[index];
        if (days >= era.start) {
            return .{
                .era = era.type,
                .year = civil.year - era.start_year + 1,
                .month = civil.month,
                .day = civil.day,
            };
        }
    }
    // Before the Meiji era: ICU's extended year starts with Meiji 1 = 1868.
    return .{
        .era = 232,
        .year = civil.year - 1867,
        .month = civil.month,
        .day = civil.day,
    };
}

const hebrew_epoch = 347997;
const hebrew_hour_parts = 1080;
const hebrew_day_parts = 24 * 1080;
const hebrew_month_fract = 12 * 1080 + 793;
const hebrew_month_parts = 29 * hebrew_day_parts + hebrew_month_fract;
const hebrew_baharad = 11 * 1080 + 204;

const hebrew_month_length = [13][3]u8{
    .{ 30, 30, 30 },
    .{ 29, 29, 30 },
    .{ 29, 30, 30 },
    .{ 29, 29, 29 },
    .{ 30, 30, 30 },
    .{ 30, 30, 30 },
    .{ 29, 29, 29 },
    .{ 30, 30, 30 },
    .{ 29, 29, 29 },
    .{ 30, 30, 30 },
    .{ 29, 29, 29 },
    .{ 30, 30, 30 },
    .{ 29, 29, 29 },
};

const hebrew_month_start = [14][3]u16{
    .{ 0, 0, 0 },
    .{ 30, 30, 30 },
    .{ 59, 59, 60 },
    .{ 88, 89, 90 },
    .{ 117, 118, 119 },
    .{ 147, 148, 149 },
    .{ 147, 148, 149 },
    .{ 176, 177, 178 },
    .{ 206, 207, 208 },
    .{ 235, 236, 237 },
    .{ 265, 266, 267 },
    .{ 294, 295, 296 },
    .{ 324, 325, 326 },
    .{ 353, 354, 355 },
};

const hebrew_leap_month_start = [14][3]u16{
    .{ 0, 0, 0 },
    .{ 30, 30, 30 },
    .{ 59, 59, 60 },
    .{ 88, 89, 90 },
    .{ 117, 118, 119 },
    .{ 147, 148, 149 },
    .{ 177, 178, 179 },
    .{ 206, 207, 208 },
    .{ 236, 237, 238 },
    .{ 265, 266, 267 },
    .{ 295, 296, 297 },
    .{ 324, 325, 326 },
    .{ 354, 355, 356 },
    .{ 383, 384, 385 },
};

fn hebrewIsLeapYear(year: i32) bool {
    const value = @mod(@as(i64, year) * 12 + 17, 19);
    return value >= 12;
}

fn hebrewStartOfYear(year: i32) i64 {
    const months = @divFloor(235 * @as(i64, year) - 234, 19);
    var fraction = months * hebrew_month_fract + hebrew_baharad;
    const fraction_div = @divFloor(fraction, hebrew_day_parts);
    var day = months * 29 + fraction_div;
    fraction -= fraction_div * hebrew_day_parts;
    var weekday = @mod(day, 7);
    if (weekday == 2 or weekday == 4 or weekday == 6) {
        day += 1;
        weekday = @mod(day, 7);
    } else if (weekday == 1 and fraction >= 15 * hebrew_hour_parts + 204 and
        !hebrewIsLeapYear(year))
    {
        day += 2;
    } else if (weekday == 0 and fraction >= 21 * hebrew_hour_parts + 589 and
        hebrewIsLeapYear(year - 1))
    {
        day += 1;
    }
    return day;
}

fn hebrewYearType(year: i32) usize {
    var length = hebrewStartOfYear(year + 1) - hebrewStartOfYear(year);
    if (length > 380) length -= 30;
    return switch (length) {
        353 => 0,
        354 => 1,
        355 => 2,
        else => 1,
    };
}

fn hebrewDate(days: i64) Date {
    const value = julianDay(days) - hebrew_epoch;
    const months = @divFloor(value * hebrew_day_parts, hebrew_month_parts);
    var year: i32 = @intCast(@divFloor(19 * months + 234, 235) + 1);
    var year_start = hebrewStartOfYear(year);
    var day_of_year = value - year_start;
    while (day_of_year < 1) {
        year -= 1;
        year_start = hebrewStartOfYear(year);
        day_of_year = value - year_start;
    }
    const year_type = hebrewYearType(year);
    const leap = hebrewIsLeapYear(year);
    var month: usize = 0;
    const starts = if (leap) &hebrew_leap_month_start else &hebrew_month_start;
    while (month < 14 and day_of_year > starts[month][year_type]) : (month += 1) {}
    if (month == 0) month = 1;
    if (month > 13) month = 13;
    month -= 1;
    const day = day_of_year - starts[month][year_type];
    var ordinal: i64 = @intCast(month);
    if (!leap and ordinal > 5) ordinal -= 1;
    return .{
        .era = 0,
        .year = year,
        .month = @intCast(ordinal + 1),
        .day = @intCast(day),
        .leap_year = leap,
    };
}

const umalqura_year_start = 1300;
const umalqura_year_end = 1600;

const umalqura_month_length = [_]u16{
    0x0AAA, 0x0D54, 0x0EC9, 0x06D4, 0x06EA, 0x036C, 0x0AAD, 0x0555, 0x06A9, 0x0792, 0x0BA9, 0x05D4,
    0x0ADA, 0x055C, 0x0D2D, 0x0695, 0x074A, 0x0B54, 0x0B6A, 0x05AD, 0x04AE, 0x0A4F, 0x0517, 0x068B,
    0x06A5, 0x0AD5, 0x02D6, 0x095B, 0x049D, 0x0A4D, 0x0D26, 0x0D95, 0x05AC, 0x09B6, 0x02BA, 0x0A5B,
    0x052B, 0x0A95, 0x06CA, 0x0AE9, 0x02F4, 0x0976, 0x02B6, 0x0956, 0x0ACA, 0x0BA4, 0x0BD2, 0x05D9,
    0x02DC, 0x096D, 0x054D, 0x0AA5, 0x0B52, 0x0BA5, 0x05B4, 0x09B6, 0x0557, 0x0297, 0x054B, 0x06A3,
    0x0752, 0x0B65, 0x056A, 0x0AAB, 0x052B, 0x0C95, 0x0D4A, 0x0DA5, 0x05CA, 0x0AD6, 0x0957, 0x04AB,
    0x094B, 0x0AA5, 0x0B52, 0x0B6A, 0x0575, 0x0276, 0x08B7, 0x045B, 0x0555, 0x05A9, 0x05B4, 0x09DA,
    0x04DD, 0x026E, 0x0936, 0x0AAA, 0x0D54, 0x0DB2, 0x05D5, 0x02DA, 0x095B, 0x04AB, 0x0A55, 0x0B49,
    0x0B64, 0x0B71, 0x05B4, 0x0AB5, 0x0A55, 0x0D25, 0x0E92, 0x0EC9, 0x06D4, 0x0AE9, 0x096B, 0x04AB,
    0x0A93, 0x0D49, 0x0DA4, 0x0DB2, 0x0AB9, 0x04BA, 0x0A5B, 0x052B, 0x0A95, 0x0B2A, 0x0B55, 0x055C,
    0x04BD, 0x023D, 0x091D, 0x0A95, 0x0B4A, 0x0B5A, 0x056D, 0x02B6, 0x093B, 0x049B, 0x0655, 0x06A9,
    0x0754, 0x0B6A, 0x056C, 0x0AAD, 0x0555, 0x0B29, 0x0B92, 0x0BA9, 0x05D4, 0x0ADA, 0x055A, 0x0AAB,
    0x0595, 0x0749, 0x0764, 0x0BAA, 0x05B5, 0x02B6, 0x0A56, 0x0E4D, 0x0B25, 0x0B52, 0x0B6A, 0x05AD,
    0x02AE, 0x092F, 0x0497, 0x064B, 0x06A5, 0x06AC, 0x0AD6, 0x055D, 0x049D, 0x0A4D, 0x0D16, 0x0D95,
    0x05AA, 0x05B5, 0x02DA, 0x095B, 0x04AD, 0x0595, 0x06CA, 0x06E4, 0x0AEA, 0x04F5, 0x02B6, 0x0956,
    0x0AAA, 0x0B54, 0x0BD2, 0x05D9, 0x02EA, 0x096D, 0x04AD, 0x0A95, 0x0B4A, 0x0BA5, 0x05B2, 0x09B5,
    0x04D6, 0x0A97, 0x0547, 0x0693, 0x0749, 0x0B55, 0x056A, 0x0A6B, 0x052B, 0x0A8B, 0x0D46, 0x0DA3,
    0x05CA, 0x0AD6, 0x04DB, 0x026B, 0x094B, 0x0AA5, 0x0B52, 0x0B69, 0x0575, 0x0176, 0x08B7, 0x025B,
    0x052B, 0x0565, 0x05B4, 0x09DA, 0x04ED, 0x016D, 0x08B6, 0x0AA6, 0x0D52, 0x0DA9, 0x05D4, 0x0ADA,
    0x095B, 0x04AB, 0x0653, 0x0729, 0x0762, 0x0BA9, 0x05B2, 0x0AB5, 0x0555, 0x0B25, 0x0D92, 0x0EC9,
    0x06D2, 0x0AE9, 0x056B, 0x04AB, 0x0A55, 0x0D29, 0x0D54, 0x0DAA, 0x09B5, 0x04BA, 0x0A3B, 0x049B,
    0x0A4D, 0x0AAA, 0x0AD5, 0x02DA, 0x095D, 0x045E, 0x0A2E, 0x0C9A, 0x0D55, 0x06B2, 0x06B9, 0x04BA,
    0x0A5D, 0x052D, 0x0A95, 0x0B52, 0x0BA8, 0x0BB4, 0x05B9, 0x02DA, 0x095A, 0x0B4A, 0x0DA4, 0x0ED1,
    0x06E8, 0x0B6A, 0x056D, 0x0535, 0x0695, 0x0D4A, 0x0DA8, 0x0DD4, 0x06DA, 0x055B, 0x029D, 0x062B,
    0x0B15, 0x0B4A, 0x0B95, 0x05AA, 0x0AAE, 0x092E, 0x0C8F, 0x0527, 0x0695,
};

const umalqura_year_fix = [_]i8{
    0, 0, -1, 0, -1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0, -1, 0,
    1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
    0, 0, 1, 0, 0, -1, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, 1, 1, 0, 0, -1, 0, 1, 0, 1,
    1, 0, 0, -1, 0, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, -1, 0, 0,
    0, 0, -1, -1, 0, -1, 0, 1, 0, 0, 0, -1, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 1, 0, 0, -1, -1, 0, 0, 0, 1, 0, 0, -1, -1, 0, -1, 0, 0, -1, -1,
    0, -1, 0, -1, 0, 0, -1, -1, 0, 0, 0, 0, 0, 0, -1, 0, 1, 0, 1, 1,
    0, 0, -1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, -1, 0, 1, 0,
    0, -1, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
    1, 0, 0, -1, 0, 0, 0, 1, 1, 0, 0, -1, 0, 1, 0, 1, 1, 0, 0, 0,
    0, 1, 0, 0, 0, -1, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 0, 0, 0, -1,
    0, -1, 0, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0,
    -1, 0, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 0, 0, -1, -1, 0, -1, 0, 1,
    0, 0, -1, -1, 0, 0, 1, 1, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0,
    1,
};

fn islamicCivilYearStart(year: i64) i64 {
    return 354 * (year - 1) + @divFloor(11 * year + 3, 30);
}

fn islamicCivilMonthLength(year: i64, month: u8) u8 {
    const leap = @mod(11 * year + 3, 30) >= 12;
    if (month == 11 and leap) return 30;
    return if (month % 2 == 0) 30 else 29;
}

fn umalquraYearStart(year: i32) i64 {
    if (year < umalqura_year_start or year > umalqura_year_end) {
        return islamicCivilYearStart(year);
    }
    const index: usize = @intCast(year - umalqura_year_start);
    const estimate = 354.36720 * @as(f64, @floatFromInt(index)) + 460322.05 + 0.5;
    return @as(i64, @intFromFloat(estimate)) + umalqura_year_fix[index];
}

fn umalquraMonthLength(year: i32, month: u8) u8 {
    if (year < umalqura_year_start or year > umalqura_year_end) {
        return islamicCivilMonthLength(year, month);
    }
    const index: usize = @intCast(year - umalqura_year_start);
    const mask: u16 = @as(u16, 1) << @intCast(11 - month);
    return if (umalqura_month_length[index] & mask != 0) 30 else 29;
}

fn umalquraYearLength(year: i32) u16 {
    if (year < umalqura_year_start or year > umalqura_year_end) {
        return 354 + @as(u16, if (@mod(11 * @as(i64, year) + 3, 30) >= 12) 1 else 0);
    }
    var length: u16 = 0;
    for (0..12) |month| length += umalquraMonthLength(year, @intCast(month));
    return length;
}

fn umalquraDate(days: i64) Date {
    const value = julianDay(days) - 1948440;
    if (value < umalquraYearStart(umalqura_year_start)) {
        return islamicDate(days, 1948440);
    }
    var year: i32 = @intFromFloat(
        (@as(f64, @floatFromInt(value)) - (460322.05 + 0.5)) / 354.36720 +
            @as(f64, umalqura_year_start - 1),
    );
    var month: u8 = 0;
    var day: i64 = 1;
    while (day > 0) {
        year += 1;
        day = value - umalquraYearStart(year) + 1;
        const length = umalquraYearLength(year);
        if (day == length) {
            month = 11;
            break;
        }
        if (day < length) {
            var month_length = umalquraMonthLength(year, month);
            while (day > month_length) {
                day -= month_length;
                month += 1;
                month_length = umalquraMonthLength(year, month);
            }
            break;
        }
    }
    var month_start = umalquraYearStart(year);
    var index: u8 = 0;
    while (index < month) : (index += 1) {
        month_start += umalquraMonthLength(year, index);
    }
    return .{
        .era = 0,
        .year = year,
        .month = month + 1,
        .day = @intCast(value - month_start + 1),
    };
}

fn rocDate(civil: Civil, days: i64) Date {
    const start = daysFromGregorian(1912, 1, 1);
    if (days >= start) {
        return .{
            .era = 1,
            .year = civil.year - 1911,
            .month = civil.month,
            .day = civil.day,
        };
    }
    return .{
        .era = 0,
        .year = 1912 - civil.year,
        .month = civil.month,
        .day = civil.day,
    };
}

fn islamicDate(days: i64, epoch: i64) Date {
    const days_since_epoch = julianDay(days) - epoch;
    const year = @divFloor(30 * days_since_epoch + 10646, 10631);
    const year_start = 354 * (year - 1) + @divFloor(11 * year + 3, 30);
    var month = @divFloor(2 * (days_since_epoch - 29 - year_start) + 58, 59);
    if (month < 0) month = 0;
    if (month > 11) month = 11;
    const month_start = @divFloor(59 * month + 1, 2) + 354 * (year - 1) +
        @divFloor(11 * year + 3, 30);
    const day = days_since_epoch - month_start + 1;
    return .{
        .era = 0,
        .year = @intCast(year),
        .month = @intCast(month + 1),
        .day = @intCast(day),
    };
}

const persian_non_leap_years = [_]i32{
    1502, 1601, 1634, 1667, 1700, 1733, 1766, 1799, 1832, 1865, 1898, 1931,
    1964, 1997, 2030, 2059, 2063, 2096, 2129, 2158, 2162, 2191, 2195, 2224,
    2228, 2257, 2261, 2290, 2294, 2323, 2327, 2356, 2360, 2389, 2393, 2422,
    2426, 2455, 2459, 2488, 2492, 2521, 2525, 2554, 2558, 2587, 2591, 2620,
    2624, 2653, 2657, 2686, 2690, 2719, 2723, 2748, 2752, 2756, 2781, 2785,
    2789, 2818, 2822, 2847, 2851, 2855, 2880, 2884, 2888, 2913, 2917, 2921,
    2946, 2950, 2954, 2979, 2983, 2987,
};

fn persianIsNonLeap(year: i64) bool {
    if (year < persian_non_leap_years[0]) return false;
    var low: usize = 0;
    var high: usize = persian_non_leap_years.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const value: i64 = persian_non_leap_years[middle];
        if (value < year) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low < persian_non_leap_years.len and persian_non_leap_years[low] == year;
}

fn persianFirstDay(year: i64) i64 {
    var day = 365 * (year - 1) + @divFloor(8 * year + 21, 33);
    if (year > persian_non_leap_years[0] and persianIsNonLeap(year - 1)) {
        day -= 1;
    }
    return day;
}

const persian_month_starts = [_]i32{ 0, 31, 62, 93, 124, 155, 186, 216, 246, 276, 306, 336 };

fn persianDate(days: i64) Date {
    const days_since_epoch = julianDay(days) - 1948320;
    var year = @divFloor(33 * days_since_epoch + 3, 12053) + 1;
    var day_of_year = days_since_epoch - persianFirstDay(year);
    if (day_of_year == 365 and year >= persian_non_leap_years[0] and
        persianIsNonLeap(year))
    {
        year += 1;
        day_of_year = 0;
    }
    const month: i64 = if (day_of_year < 216)
        @divFloor(day_of_year, 31)
    else
        @divFloor(day_of_year - 6, 30);
    const day = day_of_year + 1 - persian_month_starts[@intCast(month)];
    return .{
        .era = 0,
        .year = @intCast(year),
        .month = @intCast(month + 1),
        .day = @intCast(day),
    };
}

fn indianDate(civil: Civil, days: i64) Date {
    const gregorian_year_start = daysFromGregorian(civil.year, 1, 1);
    const yday = days - gregorian_year_start;
    var year = civil.year - 78;
    var day_of_year = yday;
    var leap_month: i64 = 0;
    if (yday < 80) {
        year -= 1;
        leap_month = if (isGregorianLeap(civil.year - 1)) 31 else 30;
        day_of_year += leap_month + 31 * 5 + 30 * 3 + 10;
    } else {
        leap_month = if (isGregorianLeap(civil.year)) 31 else 30;
        day_of_year -= 80;
    }
    var month: i64 = 0;
    var day: i64 = 0;
    if (day_of_year < leap_month) {
        month = 0;
        day = day_of_year + 1;
    } else {
        const month_day = day_of_year - leap_month;
        if (month_day < 31 * 5) {
            month = @divFloor(month_day, 31) + 1;
            day = @mod(month_day, 31) + 1;
        } else {
            const later = month_day - 31 * 5;
            month = @divFloor(later, 30) + 6;
            day = @mod(later, 30) + 1;
        }
    }
    return .{
        .era = 0,
        .year = @intCast(year),
        .month = @intCast(month + 1),
        .day = @intCast(day),
    };
}

fn copticEthiopicDate(days: i64, epoch: i64) struct { year: i32, month: u8, day: u8 } {
    const value = julianDay(days) - epoch;
    const cycle = @divFloor(value, 1461);
    const remainder = @mod(value, 1461);
    const year = 4 * cycle + @divFloor(remainder, 365) - @divFloor(remainder, 1460);
    const day_of_year = if (remainder == 1460) 365 else @mod(remainder, 365);
    return .{
        .year = @intCast(year),
        .month = @intCast(@divFloor(day_of_year, 30) + 1),
        .day = @intCast(@mod(day_of_year, 30) + 1),
    };
}

fn copticDate(days: i64) Date {
    const fields = copticEthiopicDate(days, 1824665);
    if (fields.year <= 0) {
        return .{
            .era = 0,
            .year = 1 - fields.year,
            .month = fields.month,
            .day = fields.day,
        };
    }
    return .{
        .era = 1,
        .year = fields.year,
        .month = fields.month,
        .day = fields.day,
    };
}

fn ethiopicDate(days: i64) Date {
    const fields = copticEthiopicDate(days, 1723856);
    if (fields.year <= 0) {
        return .{
            .era = 0,
            .year = fields.year + 5500,
            .month = fields.month,
            .day = fields.day,
        };
    }
    return .{
        .era = 1,
        .year = fields.year,
        .month = fields.month,
        .day = fields.day,
    };
}

fn ethiopicAmeteAlemDate(days: i64) Date {
    const fields = copticEthiopicDate(days, -285019);
    return .{
        .era = 0,
        .year = fields.year,
        .month = fields.month,
        .day = fields.day,
    };
}

/// Convert days since 1970-01-01 to calendar fields.
pub fn fromDays(calendar: Calendar, days: i64) Date {
    const civil = gregorianFromDays(days);
    return switch (calendar) {
        .gregorian => .{
            .era = if (civil.year <= 0) 0 else 1,
            .year = if (civil.year <= 0) 1 - civil.year else civil.year,
            .month = civil.month,
            .day = civil.day,
        },
        .iso8601 => .{
            // ICU's ISO-8601 calendar reuses the Gregorian era field, but
            // CLDR provides no era names for it.
            .era = if (civil.year <= 0) 0 else 1,
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
        },
        .buddhist => .{
            .era = 0,
            .year = civil.year + 543,
            .month = civil.month,
            .day = civil.day,
        },
        .japanese => japaneseDate(days, civil),
        .roc => rocDate(civil, days),
        .islamic_civil => islamicDate(days, 1948440),
        .islamic_tbla => islamicDate(days, 1948439),
        .islamic_umalqura => umalquraDate(days),
        .hebrew => hebrewDate(days),
        .chinese => chinese_calendar.fromDays(days) orelse .{
            .era = 0,
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
        },
        .persian => persianDate(days),
        .indian => indianDate(civil, days),
        .coptic => copticDate(days),
        .ethiopic => ethiopicDate(days),
        .ethiopic_amete_alem => ethiopicAmeteAlemDate(days),
    };
}

/// Convert calendar fields to days since 1970-01-01 for the Gregorian-like
/// calendars that share Gregorian month and day arithmetic. Returns null for
/// calendars without an inverse conversion.
pub fn daysFromDate(calendar: Calendar, date: Date) ?i64 {
    if (calendar == .japanese) {
        var start: i64 = 0;
        var start_year: i32 = 0;
        var found = false;
        for (japanese_eras) |era| {
            if (era.type != date.era) continue;
            start = era.start;
            start_year = era.start_year;
            found = true;
            break;
        }
        if (!found) return null;
        const year = start_year + date.year - 1;
        const days = daysFromGregorian(year, date.month, date.day);
        return if (days < start) start else days;
    }
    const gregorian_year: i32 = switch (calendar) {
        .gregorian => if (date.era == 0) 1 - date.year else date.year,
        .iso8601 => date.year,
        .buddhist => date.year - 543,
        .roc => if (date.era == 0) 1912 - date.year else 1911 + date.year,
        else => return null,
    };
    return daysFromGregorian(gregorian_year, date.month, date.day);
}

/// Inverse conversion for calendars without a closed-form Gregorian mapping.
///
/// `hint` is a nearby day (normally the calendar's current day). The year is
/// located by binary search, then the month and day are scanned within that
/// year. Returns null when the requested fields do not exist (for example a
/// non-leap month in a lunisolar calendar).
pub fn daysFromDateNear(
    calendar: Calendar,
    date: Date,
    hint: i64,
) ?i64 {
    if (daysFromDate(calendar, date)) |exact| return exact;

    const current = fromDays(calendar, hint);
    const estimate = hint + @as(i64, date.year - current.year) * 365;
    var low = estimate - 2000;
    var high = estimate + 2000;
    if (fromDays(calendar, low).year >= date.year) {
        low -= 20000;
    }
    if (fromDays(calendar, high).year < date.year) {
        high += 20000;
    }
    while (low < high) {
        const middle = low + @divFloor(high - low, 2);
        if (fromDays(calendar, middle).year < date.year) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    var day = low;
    var scanned: usize = 0;
    while (scanned < 420) : (scanned += 1) {
        const candidate = fromDays(calendar, day);
        if (candidate.year != date.year) break;
        if (candidate.era == date.era and
            candidate.month == date.month and
            candidate.day == 1 and
            candidate.leap_month == date.leap_month)
        {
            // ICU's set is lenient: a day beyond the month length rolls into
            // the following month.
            return day + @as(i64, date.day) - 1;
        }
        day += 1;
    }
    return null;
}

fn expectDate(days: i64, calendar: Calendar, expected: Date) !void {
    const actual = fromDays(calendar, days);
    try std.testing.expectEqual(expected.era, actual.era);
    try std.testing.expectEqual(expected.year, actual.year);
    try std.testing.expectEqual(expected.month, actual.month);
    try std.testing.expectEqual(expected.day, actual.day);
}

test "calendar conversions match ICU" {
    const jan = daysFromGregorian(2024, 1, 15);
    const jul = daysFromGregorian(2024, 7, 15);
    try expectDate(jan, .buddhist, .{ .era = 0, .year = 2567, .month = 1, .day = 15 });
    try expectDate(jan, .japanese, .{ .era = 236, .year = 6, .month = 1, .day = 15 });
    try expectDate(jan, .roc, .{ .era = 1, .year = 113, .month = 1, .day = 15 });
    try expectDate(jan, .islamic_civil, .{ .era = 0, .year = 1445, .month = 7, .day = 4 });
    try expectDate(jan, .islamic_tbla, .{ .era = 0, .year = 1445, .month = 7, .day = 5 });
    try expectDate(jan, .persian, .{ .era = 0, .year = 1402, .month = 10, .day = 25 });
    try expectDate(jan, .indian, .{ .era = 0, .year = 1945, .month = 10, .day = 25 });
    try expectDate(jan, .coptic, .{ .era = 1, .year = 1740, .month = 5, .day = 6 });
    try expectDate(jan, .ethiopic, .{ .era = 1, .year = 2016, .month = 5, .day = 6 });
    try expectDate(jan, .ethiopic_amete_alem, .{ .era = 0, .year = 7516, .month = 5, .day = 6 });
    try expectDate(jan, .iso8601, .{ .era = 1, .year = 2024, .month = 1, .day = 15 });

    try expectDate(jul, .islamic_civil, .{ .era = 0, .year = 1446, .month = 1, .day = 8 });
    try expectDate(jul, .islamic_tbla, .{ .era = 0, .year = 1446, .month = 1, .day = 9 });
    try expectDate(jul, .persian, .{ .era = 0, .year = 1403, .month = 4, .day = 25 });
    try expectDate(jul, .indian, .{ .era = 0, .year = 1946, .month = 4, .day = 24 });
    try expectDate(jul, .coptic, .{ .era = 1, .year = 1740, .month = 11, .day = 8 });
    try expectDate(jul, .ethiopic, .{ .era = 1, .year = 2016, .month = 11, .day = 8 });
}

test "calendar era and year boundaries" {
    try expectDate(daysFromGregorian(2019, 4, 30), .japanese, .{ .era = 235, .year = 31, .month = 4, .day = 30 });
    try expectDate(daysFromGregorian(2019, 5, 1), .japanese, .{ .era = 236, .year = 1, .month = 5, .day = 1 });
    try expectDate(daysFromGregorian(1989, 1, 7), .japanese, .{ .era = 234, .year = 64, .month = 1, .day = 7 });
    try expectDate(daysFromGregorian(1989, 1, 8), .japanese, .{ .era = 235, .year = 1, .month = 1, .day = 8 });
    try expectDate(daysFromGregorian(1912, 7, 29), .japanese, .{ .era = 232, .year = 45, .month = 7, .day = 29 });
    try expectDate(daysFromGregorian(1912, 7, 30), .japanese, .{ .era = 233, .year = 1, .month = 7, .day = 30 });
    try expectDate(daysFromGregorian(1800, 1, 1), .roc, .{ .era = 0, .year = 112, .month = 1, .day = 1 });
    try expectDate(daysFromGregorian(1912, 7, 29), .roc, .{ .era = 1, .year = 1, .month = 7, .day = 29 });
    try expectDate(daysFromGregorian(2024, 3, 20), .persian, .{ .era = 0, .year = 1403, .month = 1, .day = 1 });
    try expectDate(daysFromGregorian(2024, 3, 20), .indian, .{ .era = 0, .year = 1945, .month = 12, .day = 30 });
    try expectDate(daysFromGregorian(2024, 3, 21), .indian, .{ .era = 0, .year = 1946, .month = 1, .day = 1 });
    try expectDate(daysFromGregorian(2023, 9, 11), .coptic, .{ .era = 1, .year = 1739, .month = 13, .day = 6 });
    try expectDate(daysFromGregorian(2023, 9, 12), .coptic, .{ .era = 1, .year = 1740, .month = 1, .day = 1 });
    try expectDate(daysFromGregorian(2023, 9, 12), .ethiopic, .{ .era = 1, .year = 2016, .month = 1, .day = 1 });
    try expectDate(daysFromGregorian(2000, 2, 29), .islamic_civil, .{ .era = 0, .year = 1420, .month = 11, .day = 24 });
    try expectDate(daysFromGregorian(1970, 1, 1), .islamic_civil, .{ .era = 0, .year = 1389, .month = 10, .day = 22 });
    try expectDate(daysFromGregorian(2100, 1, 1), .islamic_tbla, .{ .era = 0, .year = 1523, .month = 10, .day = 20 });
}

test "calendar conformance" {
    const testing = @import("std").testing;
    const fixture = @embedFile("calendar_conformance.bin");
    try testing.expect(fixture.len >= 12);
    try testing.expectEqualStrings("CJKC", fixture[0..4]);
    const case_count = std.mem.readInt(u32, fixture[8..12], .little);
    var offset: usize = 12;
    var failures: usize = 0;
    var total: usize = 0;
    var printed: usize = 0;
    for (0..case_count) |_| {
        const index = fixture[offset];
        const month = fixture[offset + 1];
        const day = fixture[offset + 2];
        const era = std.mem.readInt(u16, fixture[offset + 4 ..][0..2], .little);
        const year = std.mem.readInt(i32, fixture[offset + 8 ..][0..4], .little);
        const days = std.mem.readInt(i64, fixture[offset + 12 ..][0..8], .little);
        offset += 20;
        const calendar: Calendar = @enumFromInt(index);
        const actual = fromDays(calendar, days);
        total += 1;
        if (actual.era != era or actual.year != year or
            actual.month != month or actual.day != day)
        {
            failures += 1;
            if (printed < 30) {
                printed += 1;
                std.debug.print(
                    "calendar mismatch {s} day {d}: got {d}-{d}-{d} era {d}, expected {d}-{d}-{d} era {d}\n",
                    .{ @tagName(calendar), days, actual.year, actual.month, actual.day, actual.era, year, month, day, era },
                );
            }
        }
    }
    std.debug.print("calendar conformance: {d}/{d} passed\n", .{ total - failures, total });
    try testing.expect(failures == 0);
}
