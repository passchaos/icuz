//! CLDR canonical time zone IDs, IANA preferred IDs, and regions.
//!
//! ICU's `TimeZone::getCanonicalID` returns the CLDR canonical long ID,
//! `getIanaID` the preferred IANA ID, and `getRegion` the two-letter country
//! code or "001" for zones without a country. Legacy tzdata links such as
//! `US/Pacific` resolve through the same table.

const std = @import("std");

const data = @import("canonical_data.zig");

pub const Zone = data.Zone;
pub const zones = &data.zones;

fn find(zone_id: []const u8) ?Zone {
    var low: usize = 0;
    var high: usize = data.zones.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, data.zones[middle].id, zone_id)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return data.zones[middle],
        }
    }
    return null;
}

/// CLDR canonical long ID for `zone_id`, or null if the ID is unknown.
pub fn canonicalId(zone_id: []const u8) ?[]const u8 {
    return (find(zone_id) orelse return null).canonical;
}

/// Preferred IANA ID for `zone_id`, or null if the ID is unknown.
pub fn ianaId(zone_id: []const u8) ?[]const u8 {
    return (find(zone_id) orelse return null).iana;
}

/// Country code for `zone_id` ("001" when the zone has no country), or null
/// if the ID is unknown.
pub fn regionForZone(zone_id: []const u8) ?[]const u8 {
    return (find(zone_id) orelse return null).region;
}

test "canonical time zone IDs match ICU" {
    try std.testing.expectEqualStrings(
        "America/Los_Angeles",
        canonicalId("US/Pacific").?,
    );
    try std.testing.expectEqualStrings(
        "Asia/Calcutta",
        canonicalId("Asia/Kolkata").?,
    );
    try std.testing.expectEqualStrings(
        "Etc/UTC",
        canonicalId("UTC").?,
    );
    try std.testing.expectEqualStrings(
        "Asia/Shanghai",
        canonicalId("PRC").?,
    );
    try std.testing.expectEqualStrings(
        "Asia/Kolkata",
        ianaId("Asia/Calcutta").?,
    );
    try std.testing.expectEqualStrings(
        "America/Los_Angeles",
        ianaId("US/Pacific").?,
    );
    try std.testing.expectEqualStrings("US", regionForZone("US/Pacific").?);
    try std.testing.expectEqualStrings("DE", regionForZone("Europe/Berlin").?);
    try std.testing.expectEqualStrings("CN", regionForZone("Asia/Shanghai").?);
    try std.testing.expectEqualStrings("IN", regionForZone("Asia/Kolkata").?);
    try std.testing.expectEqualStrings("001", regionForZone("Etc/GMT+12").?);
    try std.testing.expectEqualStrings("001", regionForZone("UTC").?);
    try std.testing.expect(canonicalId("Mars/Olympus_Mons") == null);
    try std.testing.expect(regionForZone("Mars/Olympus_Mons") == null);
}

test "canonical time zone table is idempotent" {
    for (data.zones) |zone| {
        const canonical = canonicalId(zone.canonical).?;
        try std.testing.expectEqualStrings(zone.canonical, canonical);
        try std.testing.expectEqualStrings(zone.iana, ianaId(zone.canonical).?);
        try std.testing.expectEqualStrings(
            zone.region,
            regionForZone(zone.canonical).?,
        );
        try std.testing.expect(
            zone.region.len == 2 or std.mem.eql(u8, zone.region, "001"),
        );
    }
}
