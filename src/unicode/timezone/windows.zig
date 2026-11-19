//! CLDR Windows time zone ID mapping.
//!
//! ICU exposes both directions: `ucal_getWindowsTimeZoneID` maps an IANA
//! zone to its Windows ID, and `ucal_getTimeZoneIDForWindowsID` maps a
//! Windows ID plus an optional region to an IANA zone. The region "001"
//! mapping is the default and the fallback when a region has no entry.

const std = @import("std");

const data = @import("windows_data.zig");

pub const windows_ids = &data.windows_ids;
pub const zones = &data.zones;

/// Map a Windows time zone ID and optional ISO 3166 region to an IANA zone.
///
/// A missing or unmapped region falls back to the CLDR "001" mapping, like
/// ICU's `ucal_getTimeZoneIDForWindowsID`.
pub fn zoneForWindowsId(windows_id: []const u8, region: ?[]const u8) ?[]const u8 {
    const windows = windowsIndex(windows_id) orelse return null;
    if (region) |code| {
        if (zoneForRegion(windows, code)) |zone| return zone;
    }
    return zoneForRegion(windows, "001");
}

/// Map an IANA zone ID to its Windows time zone ID.
///
/// Returns null for IDs that do not appear in the CLDR mapping. Link names
/// that are listed in `windowsZones.xml` map like their target zone.
pub fn windowsIdForZone(zone_id: []const u8) ?[]const u8 {
    const zone = zoneIndex(zone_id) orelse return null;
    var low: usize = 0;
    var high: usize = data.by_zone.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (data.by_zone[middle].zone < zone) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low >= data.by_zone.len or data.by_zone[low].zone != zone) return null;
    return data.windows_ids[data.by_zone[low].windows];
}

fn windowsIndex(windows_id: []const u8) ?u16 {
    var low: usize = 0;
    var high: usize = data.windows_ids.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.windows_ids[middle], windows_id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @intCast(middle),
        }
    }
    return null;
}

fn zoneIndex(zone_id: []const u8) ?u16 {
    var low: usize = 0;
    var high: usize = data.zones.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.zones[middle], zone_id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @intCast(middle),
        }
    }
    return null;
}

fn zoneForRegion(windows: u16, region: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = data.by_windows.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.by_windows[middle];
        const order: std.math.Order = if (entry.windows != windows)
            (if (entry.windows < windows) .lt else .gt)
        else
            std.mem.order(u8, entry.region, region);
        switch (order) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return data.zones[entry.zone],
        }
    }
    return null;
}

test "Windows time zone IDs round trip" {
    for (data.by_windows) |entry| {
        try std.testing.expectEqualStrings(
            data.zones[entry.zone],
            zoneForWindowsId(data.windows_ids[entry.windows], entry.region).?,
        );
    }
    for (data.by_zone) |entry| {
        try std.testing.expectEqualStrings(
            data.windows_ids[entry.windows],
            windowsIdForZone(data.zones[entry.zone]).?,
        );
    }
}

test "Windows time zone mapping matches ICU" {
    try std.testing.expectEqualStrings(
        "Pacific Standard Time",
        windowsIdForZone("America/Los_Angeles").?,
    );
    try std.testing.expectEqualStrings(
        "America/Los_Angeles",
        zoneForWindowsId("Pacific Standard Time", null).?,
    );
    try std.testing.expectEqualStrings(
        "America/Vancouver",
        zoneForWindowsId("Pacific Standard Time", "CA").?,
    );
    try std.testing.expectEqualStrings(
        "America/Los_Angeles",
        zoneForWindowsId("Pacific Standard Time", "ZZ").?,
    );
    try std.testing.expectEqualStrings(
        "W. Europe Standard Time",
        windowsIdForZone("Europe/Berlin").?,
    );
    try std.testing.expectEqualStrings(
        "Europe/Berlin",
        zoneForWindowsId("W. Europe Standard Time", "DE").?,
    );
    try std.testing.expectEqualStrings(
        "W. Europe Standard Time",
        windowsIdForZone("Europe/Busingen").?,
    );
    try std.testing.expectEqualStrings(
        "China Standard Time",
        windowsIdForZone("Asia/Shanghai").?,
    );
    try std.testing.expectEqualStrings(
        "Asia/Calcutta",
        zoneForWindowsId("India Standard Time", "IN").?,
    );
    try std.testing.expectEqualStrings(
        "AUS Eastern Standard Time",
        windowsIdForZone("Australia/Sydney").?,
    );
    try std.testing.expectEqualStrings(
        "Dateline Standard Time",
        windowsIdForZone("Etc/GMT+12").?,
    );
    try std.testing.expect(zoneForWindowsId("Not A Windows Zone", null) == null);
    try std.testing.expect(windowsIdForZone("Mars/Olympus_Mons") == null);
}
