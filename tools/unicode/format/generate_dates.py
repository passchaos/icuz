#!/usr/bin/env python3
"""Generate CLDR 48 Gregorian calendar formatting data.

Usage:
    generate_dates.py cldr-common-48.zip out_dir

Locale data is read from `common/main/<locale>.xml` and resolved through
the CLDR parent chain (locale -> language -> root).
"""

from __future__ import annotations

import copy
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

MONTH_KEYS = [str(index) for index in range(1, 13)]
DAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
QUARTER_KEYS = ["1", "2", "3", "4"]

LOCALES = (
    "af", "ak", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "ccp",
    "chr", "cs", "cy", "da", "de", "de-AT", "de-CH", "ee", "el", "en",
    "en-001", "en-AU", "en-CA", "en-GB", "en-IN", "eo", "es", "es-419",
    "es-MX", "et", "eu", "fa", "fa-AF", "ff", "fi", "fil", "fo", "fr",
    "fr-BE", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky",
    "lb", "lo", "lrc", "lt", "lv", "mk", "ml", "mn", "mr", "ms",
    "mt", "my", "nb", "ne", "nl", "nl-BE", "nn", "no", "pa", "pl", "ps",
    "pt", "pt-PT", "qu", "ro", "ru", "se", "si", "sk", "sl", "sq", "sr",
    "su", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
    "uz", "vec", "vi", "yue", "yue-Hans", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-001": "en",
    "en-AU": "en-001",
    "en-CA": "en-001",
    "en-GB": "en-001",
    "en-IN": "en-001",
    "es-419": "es",
    "es-MX": "es-419",
    "fa-AF": "fa",
    "fr-BE": "fr",
    "fr-CA": "fr",
    "nb": "no",
    "nn": "no",
    "nl-BE": "nl",
    "pt-PT": "pt",
    "yue-Hans": "yue",
    "zh-Hant": "root",
}


def zig_string(value: str) -> str:
    result = '"'
    for byte in value.encode("utf-8"):
        if byte == 0x22:
            result += '\\"'
        elif byte == 0x5C:
            result += "\\\\"
        elif 0x20 <= byte < 0x7F:
            result += chr(byte)
        else:
            result += f"\\x{byte:02x}"
    result += '"'
    return result


def names(values: dict, keys: list[str], *fallbacks: dict) -> list[str]:
    result: list[str] = []
    for key in keys:
        value = values.get(key)
        for fallback in fallbacks:
            if value is not None:
                break
            value = fallback.get(key)
        if value is None:
            value = key
        result.append(value)
    return result


def parse_locale(path: Path) -> tuple[str, dict]:
    document = json.loads(path.read_text(encoding="utf-8"))
    locale = next(iter(document["main"]))
    gregorian = document["main"][locale]["dates"]["calendars"]["gregorian"]

    months = gregorian["months"]["format"]
    days = gregorian["days"]["format"]
    day_periods = gregorian["dayPeriods"]["format"]
    eras = gregorian.get("eras", {})

    date_formats = gregorian["dateFormats"]
    time_formats = gregorian["timeFormats"]
    date_time_formats = gregorian["dateTimeFormats"]

    systems = load_numbering_systems(archive)
    system = default_numbering_system(archive, locale, cache)
    digits = systems.get(system, "0123456789")

    return locale, {
        "digits": digits,
        "months_wide": names(months.get("wide", {}), MONTH_KEYS),
        "months_abbreviated": names(
            months.get("abbreviated", {}),
            MONTH_KEYS,
            months.get("wide", {}),
        ),
        "months_narrow": names(
            months.get("narrow", {}),
            MONTH_KEYS,
            months.get("abbreviated", {}),
        ),
        "months_standalone_wide": names(
            months_standalone.get("wide", {}),
            MONTH_KEYS,
            months.get("wide", {}),
        ),
        "months_standalone_abbreviated": names(
            months_standalone.get("abbreviated", {}),
            MONTH_KEYS,
            months_standalone.get("wide", {}),
            months.get("abbreviated", {}),
        ),
        "months_standalone_narrow": names(
            months_standalone.get("narrow", {}),
            MONTH_KEYS,
            months_standalone.get("abbreviated", {}),
            months.get("narrow", {}),
        ),
        "days_wide": names(days.get("wide", {}), DAY_KEYS),
        "days_abbreviated": names(
            days.get("abbreviated", {}),
            DAY_KEYS,
            days.get("wide", {}),
        ),
        "days_narrow": names(
            days.get("narrow", {}),
            DAY_KEYS,
            days.get("abbreviated", {}),
        ),
        "days_short": names(
            days.get("short", {}),
            DAY_KEYS,
            days.get("abbreviated", {}),
        ),
        "days_standalone_wide": names(
            days_standalone.get("wide", {}),
            DAY_KEYS,
            days.get("wide", {}),
        ),
        "days_standalone_abbreviated": names(
            days_standalone.get("abbreviated", {}),
            DAY_KEYS,
            days_standalone.get("wide", {}),
            days.get("abbreviated", {}),
        ),
        "days_standalone_narrow": names(
            days_standalone.get("narrow", {}),
            DAY_KEYS,
            days_standalone.get("abbreviated", {}),
            days.get("narrow", {}),
        ),
        "days_standalone_short": names(
            days_standalone.get("short", {}),
            DAY_KEYS,
            days_standalone.get("abbreviated", {}),
            days.get("short", {}),
        ),
        "quarters_wide": names(
            quarters.get("wide", {}),
            QUARTER_KEYS,
            quarters.get("abbreviated", {}),
        ),
        "quarters_abbreviated": names(
            quarters.get("abbreviated", {}),
            QUARTER_KEYS,
            quarters.get("wide", {}),
        ),
        "quarters_narrow": names(
            quarters.get("narrow", {}),
            QUARTER_KEYS,
            quarters.get("abbreviated", {}),
        ),
        "quarters_standalone_wide": names(
            quarters_standalone.get("wide", {}),
            QUARTER_KEYS,
            quarters.get("wide", {}),
        ),
        "quarters_standalone_abbreviated": names(
            quarters_standalone.get("abbreviated", {}),
            QUARTER_KEYS,
            quarters_standalone.get("wide", {}),
            quarters.get("abbreviated", {}),
        ),
        "quarters_standalone_narrow": names(
            quarters_standalone.get("narrow", {}),
            QUARTER_KEYS,
            quarters_standalone.get("abbreviated", {}),
            quarters.get("narrow", {}),
        ),
        "first_day_of_week": first_day_of_week,
        "minimal_days": minimal_days,
        "am_wide": day_period_value(
            (
                own_wide[0],
                day_periods.get("wide", {}).get("am"),
                day_periods.get("abbreviated", {}).get("am"),
            ),
            "am",
            "AM",
        ),
        "pm_wide": day_period_value(
            (
                own_wide[1],
                day_periods.get("wide", {}).get("pm"),
                day_periods.get("abbreviated", {}).get("pm"),
            ),
            "pm",
            "PM",
        ),
        "am_abbreviated": day_period_value(
            (
                own_abbreviated[0],
                own_wide[0],
                day_periods.get("abbreviated", {}).get("am"),
                day_periods.get("wide", {}).get("am"),
            ),
            "am",
            "AM",
        ),
        "pm_abbreviated": day_period_value(
            (
                own_abbreviated[1],
                own_wide[1],
                day_periods.get("abbreviated", {}).get("pm"),
                day_periods.get("wide", {}).get("pm"),
            ),
            "pm",
            "PM",
        ),
        "am_narrow": day_period_value(
            (
                own_narrow[0],
                own_abbreviated[0],
                own_wide[0],
                day_periods.get("narrow", {}).get("am"),
            ),
            "am",
            "a",
        ),
        "pm_narrow": day_period_value(
            (
                own_narrow[1],
                own_abbreviated[1],
                own_wide[1],
                day_periods.get("narrow", {}).get("pm"),
            ),
            "pm",
            "p",
        ),
        "era_wide": names(eras.get("eraNames", {}), ["0", "1"], {"0": "BC", "1": "AD"}),
        "era_abbreviated": names(
            eras.get("eraAbbr", {}),
            ["0", "1"],
            {"0": "BC", "1": "AD"},
        ),
        "era_narrow": names(
            eras.get("eraNarrow", {}),
            ["0", "1"],
            {"0": "B", "1": "A"},
        ),
        "date_full": date_formats.get("full", "EEEE, MMMM d, y"),
        "date_long": date_formats.get("long", "MMMM d, y"),
        "date_medium": date_formats.get("medium", "MMM d, y"),
        "date_short": date_formats.get("short", "M/d/yy"),
        "time_full": time_formats.get("full", "h:mm:ss a zzzz"),
        "time_long": time_formats.get("long", "h:mm:ss a z"),
        "time_medium": time_formats.get("medium", "h:mm:ss a"),
        "time_short": time_formats.get("short", "h:mm a"),
        "date_time_full": date_time_formats.get("full", "{1}, {0}"),
        "date_time_long": date_time_formats.get("long", "{1}, {0}"),
        "date_time_medium": date_time_formats.get("medium", "{1}, {0}"),
        "date_time_short": date_time_formats.get("short", "{1}, {0}"),
    }


# ICU UDateTimePatternField order: era, year, quarter, month, week-of-year,
# week-of-month, weekday, day-of-year, day-of-week-in-month, day, dayperiod,
# hour, minute, second, fractional second, zone.
SKELETON_ORDER = "GyYuUrUQqMLlwWEecDFdgabBHkhKJjCmsASvzZOVXx"


def canonical_skeleton(skeleton: str) -> str:
    fields: dict[int, tuple[str, int]] = {}
    index = 0
    while index < len(skeleton):
        letter = skeleton[index]
        end = index
        while end < len(skeleton) and skeleton[end] == letter:
            end += 1
        position = SKELETON_ORDER.find(letter)
        # ICU keeps the last letter provided for a field.
        fields[position if position >= 0 else len(SKELETON_ORDER) + index] = (
            letter,
            end - index,
        )
        index = end
    return "".join(
        letter * count for letter, count in (fields[key] for key in sorted(fields))
    )


def render(entries: list[tuple[str, dict]]) -> str:
    skeleton_items: list[tuple[str, str]] = []
    skeleton_ranges: dict[str, tuple[int, int]] = {}
    for locale, values in sorted(entries):
        items: dict[str, str] = {}
        for item_id, pattern in values.get("available_formats", {}).items():
            items.setdefault(canonical_skeleton(item_id), pattern)
        start = len(skeleton_items)
        for canonical in sorted(items):
            skeleton_items.append((canonical, items[canonical]))
        skeleton_ranges[locale] = (start, len(skeleton_items))

    lines = [
        "// Generated by tools/unicode/format/generate_dates.py from CLDR 48.",
        "// Source: cldr-dates-full/main/<locale>/ca-gregorian.json",
        "",
        "pub const Skeleton = struct {",
        "    id: []const u8,",
        "    pattern: []const u8,",
        "};",
        "",
        "pub const skeleton_items = [_]Skeleton{",
    ]
    for item_id, pattern in skeleton_items:
        lines.append(
            f"    .{{ .id = {zig_string(item_id)}, "
            f".pattern = {zig_string(pattern)} }},"
        )
    lines.extend([
        "};",
        "",
        "pub const Locale = struct {",
        "    id: []const u8,",
        "    skeletons: []const Skeleton,",
        "    digits: [10]u21,",
        "    months_wide: [12][]const u8,",
        "    months_abbreviated: [12][]const u8,",
        "    months_narrow: [12][]const u8,",
        "    months_standalone_wide: [12][]const u8,",
        "    months_standalone_abbreviated: [12][]const u8,",
        "    months_standalone_narrow: [12][]const u8,",
        "    days_wide: [7][]const u8,",
        "    days_abbreviated: [7][]const u8,",
        "    days_narrow: [7][]const u8,",
        "    days_short: [7][]const u8,",
        "    days_standalone_wide: [7][]const u8,",
        "    days_standalone_abbreviated: [7][]const u8,",
        "    days_standalone_narrow: [7][]const u8,",
        "    days_standalone_short: [7][]const u8,",
        "    quarters_wide: [4][]const u8,",
        "    quarters_abbreviated: [4][]const u8,",
        "    quarters_narrow: [4][]const u8,",
        "    quarters_standalone_wide: [4][]const u8,",
        "    quarters_standalone_abbreviated: [4][]const u8,",
        "    quarters_standalone_narrow: [4][]const u8,",
        "    first_day_of_week: u8,",
        "    minimal_days: u8,",
        "    am_wide: []const u8,",
        "    pm_wide: []const u8,",
        "    am_abbreviated: []const u8,",
        "    pm_abbreviated: []const u8,",
        "    am_narrow: []const u8,",
        "    pm_narrow: []const u8,",
        "    era_wide: [2][]const u8,",
        "    era_abbreviated: [2][]const u8,",
        "    era_narrow: [2][]const u8,",
        "    date_full: []const u8,",
        "    date_long: []const u8,",
        "    date_medium: []const u8,",
        "    date_short: []const u8,",
        "    time_full: []const u8,",
        "    time_long: []const u8,",
        "    time_medium: []const u8,",
        "    time_short: []const u8,",
        "    date_time_full: []const u8,",
        "    date_time_long: []const u8,",
        "    date_time_medium: []const u8,",
        "    date_time_short: []const u8,",
        "    date_time_interval: []const u8,",
        "};",
        "",
        "pub const locales = [_]Locale{",
    ])
    for locale, values in sorted(entries):
        digits = ", ".join(f"0x{ord(c):x}" for c in values["digits"])

        def string_array(key: str) -> str:
            return ".{ " + ", ".join(zig_string(v) for v in values[key]) + " }"

        start, end = skeleton_ranges[locale]
        lines.append(
            "    .{ "
            f".id = {zig_string(locale)}, "
            f".skeletons = skeleton_items[{start}..{end}], "
            f".digits = .{{ {digits} }}, "
            f".months_wide = {string_array('months_wide')}, "
            f".months_abbreviated = {string_array('months_abbreviated')}, "
            f".months_narrow = {string_array('months_narrow')}, "
            f".months_standalone_wide = {string_array('months_standalone_wide')}, "
            f".months_standalone_abbreviated = {string_array('months_standalone_abbreviated')}, "
            f".months_standalone_narrow = {string_array('months_standalone_narrow')}, "
            f".days_wide = {string_array('days_wide')}, "
            f".days_abbreviated = {string_array('days_abbreviated')}, "
            f".days_narrow = {string_array('days_narrow')}, "
            f".days_short = {string_array('days_short')}, "
            f".days_standalone_wide = {string_array('days_standalone_wide')}, "
            f".days_standalone_abbreviated = {string_array('days_standalone_abbreviated')}, "
            f".days_standalone_narrow = {string_array('days_standalone_narrow')}, "
            f".days_standalone_short = {string_array('days_standalone_short')}, "
            f".quarters_wide = {string_array('quarters_wide')}, "
            f".quarters_abbreviated = {string_array('quarters_abbreviated')}, "
            f".quarters_narrow = {string_array('quarters_narrow')}, "
            f".quarters_standalone_wide = {string_array('quarters_standalone_wide')}, "
            f".quarters_standalone_abbreviated = {string_array('quarters_standalone_abbreviated')}, "
            f".quarters_standalone_narrow = {string_array('quarters_standalone_narrow')}, "
            f".first_day_of_week = {values['first_day_of_week']}, "
            f".minimal_days = {values['minimal_days']}, "
            f".am_wide = {zig_string(values['am_wide'])}, "
            f".pm_wide = {zig_string(values['pm_wide'])}, "
            f".am_abbreviated = {zig_string(values['am_abbreviated'])}, "
            f".pm_abbreviated = {zig_string(values['pm_abbreviated'])}, "
            f".am_narrow = {zig_string(values['am_narrow'])}, "
            f".pm_narrow = {zig_string(values['pm_narrow'])}, "
            f".era_wide = {string_array('era_wide')}, "
            f".era_abbreviated = {string_array('era_abbreviated')}, "
            f".era_narrow = {string_array('era_narrow')}, "
            f".date_full = {zig_string(values['date_full'])}, "
            f".date_long = {zig_string(values['date_long'])}, "
            f".date_medium = {zig_string(values['date_medium'])}, "
            f".date_short = {zig_string(values['date_short'])}, "
            f".time_full = {zig_string(values['time_full'])}, "
            f".time_long = {zig_string(values['time_long'])}, "
            f".time_medium = {zig_string(values['time_medium'])}, "
            f".time_short = {zig_string(values['time_short'])}, "
            f".date_time_full = {zig_string(values['date_time_full'])}, "
            f".date_time_long = {zig_string(values['date_time_long'])}, "
            f".date_time_medium = {zig_string(values['date_time_medium'])}, "
            f".date_time_short = {zig_string(values['date_time_short'])}, "
            f".date_time_interval = {zig_string(values['date_time_interval'])} "
            "},"
        )
    lines.extend(["};", ""])
    return "\n".join(lines)


def is_alias(value) -> bool:
    return isinstance(value, dict) and "alias" in value


def merge_dict(target: dict, source: dict) -> None:
    for key, value in source.items():
        existing = target.get(key)
        if isinstance(value, dict) and isinstance(existing, dict):
            if is_alias(value):
                target[key] = copy.deepcopy(value)
            elif is_alias(existing):
                # An empty source section inherits the parent's alias.
                if value:
                    target[key] = copy.deepcopy(value)
            else:
                merge_dict(existing, value)
        else:
            # Deep-copy so later merges never mutate a cached locale tree.
            target[key] = copy.deepcopy(value)


def context_widths(parent, context_tag: str, width_tag: str, item_tag: str) -> dict:
    """Convert `<*Context>` elements into {context: {width: {type: text}}}.

    Widths whose content is an `<alias>` keep the alias path so it can be
    resolved after the locale's parent chain has been merged.
    """
    result: dict = {"format": {}, "stand-alone": {}}
    if parent is None:
        return result
    for context in parent.findall(context_tag):
        context_type = context.get("type", "format")
        if context_type not in result:
            continue
        for width in context.findall(width_tag):
            width_type = width.get("type", "wide")
            alias = width.find("alias")
            if alias is not None:
                result[context_type][width_type] = {
                    "alias": alias.get("path", "")
                }
                continue
            bucket: dict = {}
            for item in width.findall(item_tag):
                if item.text is not None and item.get("alt") is None:
                    bucket[item.get("type", "other")] = item.text
            result[context_type][width_type] = bucket
    return result


def format_patterns(container) -> dict:
    result: dict = {}
    if container is None:
        return result
    if container.find("alias") is not None:
        return {"__alias__": container.find("alias").get("path", "")}
    for length in container:
        if not length.tag.endswith("FormatLength"):
            continue
        length_type = length.get("type", "full")
        for fmt in length:
            for pattern in fmt:
                if pattern.tag != "pattern":
                    continue
                if pattern.get("alt") is not None:
                    continue
                if pattern.get("type") is not None or pattern.get("count") is not None:
                    continue
                result[length_type] = pattern.text or ""
                break
            if length_type in result:
                break
    return result


def date_time_patterns(container) -> dict:
    result: dict = {}
    if container is None:
        return result
    if container.find("alias") is not None:
        return {"__alias__": container.find("alias").get("path", "")}
    for length in container:
        if not length.tag.endswith("FormatLength"):
            continue
        length_type = length.get("type", "full")
        candidates: dict[str, str] = {}
        for fmt in length:
            if fmt.tag != "dateTimeFormat":
                continue
            for pattern in fmt:
                if pattern.tag != "pattern":
                    continue
                if pattern.get("alt") is not None:
                    continue
                candidates[fmt.get("type", "standard")] = pattern.text or ""
                break
        # ICU 42+ prefers the "atTime" variant when CLDR provides one.
        for variant in ("atTime", "standard"):
            if variant in candidates:
                value = candidates[variant]
                # ICU does not use an atTime pattern that merely concatenates
                # the date and time without a separator; fall back to the
                # standard glue in that case.
                if variant == "atTime" and value == "{1}{0}":
                    continue
                result[length_type] = value
                break
        else:
            if candidates:
                result[length_type] = next(iter(candidates.values()))
        if "standard" in candidates:
            result["standard_" + length_type] = candidates["standard"]
    return result


def calendar_dict(document, element) -> dict:
    """Convert a CLDR gregorian `<calendar>` into the resolved JSON shape."""
    result: dict = {}
    result["months"] = context_widths(
        element.find("months"),
        "monthContext",
        "monthWidth",
        "month",
    )
    result["days"] = context_widths(
        element.find("days"),
        "dayContext",
        "dayWidth",
        "day",
    )
    result["quarters"] = context_widths(
        element.find("quarters"),
        "quarterContext",
        "quarterWidth",
        "quarter",
    )
    result["dayPeriods"] = context_widths(
        element.find("dayPeriods"),
        "dayPeriodContext",
        "dayPeriodWidth",
        "dayPeriod",
    )
    eras = element.find("eras")
    era_result: dict = {}
    if eras is not None:
        for tag in ("eraNames", "eraAbbr", "eraNarrow"):
            container = eras.find(tag)
            if container is None:
                continue
            alias = container.find("alias")
            if alias is not None:
                era_result[tag] = {"alias": alias.get("path", "")}
                continue
            era_result[tag] = {
                era.get("type", "0"): era.text or ""
                for era in container.findall("era")
                if era.text is not None and era.get("alt") is None
            }
    result["eras"] = era_result
    result["dateFormats"] = format_patterns(element.find("dateFormats"))
    result["timeFormats"] = format_patterns(element.find("timeFormats"))
    available: dict[str, str] = {}
    available_container = element.find("dateTimeFormats/availableFormats")
    if available_container is not None:
        for item in available_container.findall("dateFormatItem"):
            item_id = item.get("id")
            if item_id is None or item.get("alt") is not None or not item.text:
                continue
            available[item_id] = item.text
    result["availableFormats"] = available
    date_time = element.find("dateTimeFormats")
    if date_time is not None and date_time.find("alias") is not None:
        # Root aliases the gregorian date/time glue to the generic calendar.
        generic = document.find('.//calendar[@type="generic"]')
        if generic is not None:
            date_time = generic.find("dateTimeFormats")
    result["dateTimeFormats"] = date_time_patterns(date_time)
    return result


def resolve_width_alias(data: dict, context: str, path: str):
    match = re.search(
        r"(month|day|dayPeriod)Context\[@type='([^']+)'\]",
        path,
    )
    target_context = match.group(2) if match else context
    width = re.search(
        r"(?:month|day|dayPeriod)Width\[@type='([^']+)'\]",
        path,
    )
    if width is None:
        return None
    return target_context, width.group(1)


def resolve_aliases(calendar: dict) -> None:
    """Resolve `<alias source="locale">` markers against the merged tree."""
    for section in ("months", "days", "dayPeriods"):
        data = calendar.get(section, {})
        for context in ("format", "stand-alone"):
            widths = data.get(context, {})
            for width, value in list(widths.items()):
                if not (isinstance(value, dict) and "alias" in value):
                    continue
                target = resolve_width_alias(data, context, value["alias"])
                if target is None:
                    continue
                resolved = data.get(target[0], {}).get(target[1])
                if resolved is not None and not (
                    isinstance(resolved, dict) and "alias" in resolved
                ):
                    widths[width] = resolved
    eras = calendar.get("eras", {})
    for key, value in list(eras.items()):
        if not (isinstance(value, dict) and "alias" in value):
            continue
        match = re.search(r"era(Names|Abbr|Narrow)", value["alias"])
        if match is None:
            continue
        resolved = eras.get("era" + match.group(1))
        if resolved is not None and not (
            isinstance(resolved, dict) and "alias" in resolved
        ):
            eras[key] = resolved


def parent_chain(locale: str) -> list[str]:
    chain = []
    current = locale
    seen: set[str] = set()
    while current not in seen:
        seen.add(current)
        chain.append(current)
        if current == "root":
            break
        parent = PARENT.get(current)
        if parent is None:
            parent = re.split(r"[-_]", current)[0]
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def load_week_data(archive: zipfile.ZipFile) -> tuple[dict, dict]:
    """Return (first_day_by_territory, min_days_by_territory).

    First day uses Sunday = 0, matching `dayOfWeek` in the formatter.
    """
    days = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}
    first_day: dict[str, int] = {}
    min_days: dict[str, int] = {}
    try:
        text = archive.read("common/supplemental/supplementalData.xml")
    except KeyError:
        return first_day, min_days
    document = ET.fromstring(text)
    for element in document.iter("firstDay"):
        if element.get("alt") is not None:
            continue
        value = days.get(element.get("day", ""))
        if value is None:
            continue
        for territory in element.get("territories", "").split():
            first_day[territory] = value
    for element in document.iter("minDays"):
        if element.get("alt") is not None:
            continue
        try:
            value = int(element.get("count", ""))
        except ValueError:
            continue
        for territory in element.get("territories", "").split():
            min_days[territory] = value
    return first_day, min_days


def load_likely_regions(archive: zipfile.ZipFile) -> dict[str, str]:
    """Map `language[_Script]` to the likely territory from likelySubtags."""
    result: dict[str, str] = {}
    try:
        text = archive.read("common/supplemental/likelySubtags.xml")
    except KeyError:
        return result
    document = ET.fromstring(text)
    for element in document.iter("likelySubtag"):
        source = element.get("from", "")
        target = element.get("to", "")
        parts = target.split("_")
        if len(parts) == 3:
            result[source.replace("_", "-")] = parts[2]
    return result


def locale_week_settings(
    locale: str,
    first_day: dict[str, int],
    min_days: dict[str, int],
    likely: dict[str, str],
) -> tuple[int, int]:
    parts = locale.replace("_", "-").split("-")
    region = None
    for part in parts[1:]:
        if (len(part) == 2 and part.isalpha()) or (
            len(part) == 3 and part.isdigit()
        ):
            region = part.upper()
            break
    if region is None:
        region = likely.get(locale.replace("_", "-"))
    if region is None:
        region = likely.get(parts[0])
    if region is None:
        region = "001"
    return first_day.get(region, 1), min_days.get(region, 1)


def load_numbering_systems(archive: zipfile.ZipFile) -> dict:
    try:
        text = archive.read("common/supplemental/numberingSystems.xml")
    except KeyError:
        return {}
    document = ET.fromstring(text)
    systems = {}
    for system in document.findall(".//numberingSystem"):
        if system.get("type") != "numeric":
            continue
        digits = system.get("digits")
        identifier = system.get("id")
        if identifier and digits and len(digits) == 10:
            systems[identifier] = digits
    return systems


def default_numbering_system(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
) -> str:
    if "numbering" in cache:
        numbering = cache["numbering"]
    else:
        numbering = {}
        cache["numbering"] = numbering
    if locale in numbering:
        return numbering[locale]
    for name in parent_chain(locale):
        filename = name.replace("-", "_")
        try:
            xml = archive.read(f"common/main/{filename}.xml").decode("utf-8")
        except KeyError:
            continue
        root = ET.fromstring(xml)
        value = root.findtext(".//numbers/defaultNumberingSystem")
        if value:
            numbering[locale] = value.strip()
            return numbering[locale]
    numbering[locale] = "latn"
    return "latn"


def load_calendar(archive: zipfile.ZipFile, locale: str, cache: dict) -> dict:
    if locale in cache:
        return cache[locale]
    try:
        filename = locale.replace("-", "_")
        xml = archive.read(f"common/main/{filename}.xml").decode("utf-8")
    except KeyError:
        cache[locale] = {}
        return cache[locale]
    root = ET.fromstring(xml)
    element = root.find('.//calendar[@type="gregorian"]')
    cache[locale] = calendar_dict(root, element) if element is not None else {}
    return cache[locale]


def resolved_calendar(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
    merged_cache: dict,
) -> dict:
    if locale in merged_cache:
        return merged_cache[locale]
    merged: dict = {}
    for name in reversed(parent_chain(locale)):
        merge_dict(merged, load_calendar(archive, name, cache))
    resolve_aliases(merged)
    merged_cache[locale] = merged
    return merged


def pattern_skeleton(pattern: str) -> str:
    """Derive the skeleton a date/time pattern was built from."""
    fields: list[tuple[str, int]] = []
    quoted = False
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if character == "'":
            if index + 1 < len(pattern) and pattern[index + 1] == "'":
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if not quoted and character.isascii() and character.isalpha():
            end = index
            while end < len(pattern) and pattern[end] == character:
                end += 1
            fields.append((character, end - index))
            index = end
            continue
        index += 1
    return canonical_skeleton(
        "".join(letter * count for letter, count in fields)
    )


def parse_locale_xml(
    archive: zipfile.ZipFile,
    locale: str,
    cache: dict,
    merged_cache: dict,
) -> tuple[str, dict]:
    gregorian = resolved_calendar(archive, locale, cache, merged_cache)

    def format_widths(section: str) -> dict:
        # CLDR falls back from a missing format width to the stand-alone
        # width of the same size before falling back to wider widths.
        data = gregorian.get(section, {})
        widths = dict(data.get("format", {}))
        standalone = data.get("stand-alone", {})
        for width in ("wide", "abbreviated", "narrow", "short"):
            if width not in widths and width in standalone:
                widths[width] = standalone[width]
        return widths

    months = format_widths("months")
    days = format_widths("days")
    quarters = format_widths("quarters")
    day_periods = format_widths("dayPeriods")

    def standalone_widths(section: str) -> dict:
        # Stand-alone names inherit from the stand-alone context, then from
        # the format context of the same width.
        data = gregorian.get(section, {})
        result = dict(data.get("stand-alone", {}))
        for width, values in data.get("format", {}).items():
            result.setdefault(width, values)
        return result

    months_standalone = standalone_widths("months")
    days_standalone = standalone_widths("days")
    quarters_standalone = standalone_widths("quarters")

    if "week" not in cache:
        first_day, min_days = load_week_data(archive)
        cache["week"] = (first_day, min_days, load_likely_regions(archive))
    first_day_of_week, minimal_days = locale_week_settings(
        locale,
        *cache["week"],
    )

    # Locales whose ICU data fills every am/pm width from the wide form.
    WIDE_FILL_DAY_PERIODS = {"ko", "ps"}

    def own_day_period(width: str):
        # am/pm inherit per width through the parent chain (including root);
        # a few locales use their wide form for every width. Flexible day
        # periods are the last resort.
        if locale in WIDE_FILL_DAY_PERIODS:
            widths = {
                "wide": ("wide",),
                "abbreviated": ("abbreviated", "wide"),
                "narrow": ("narrow", "abbreviated", "wide"),
            }.get(width, (width,))
        else:
            widths = (width,)
        for name in parent_chain(locale):
            calendar = load_calendar(archive, name, cache)
            periods = calendar.get("dayPeriods", {}).get("format", {})
            for candidate in widths:
                data = periods.get(candidate, {})
                am = data.get("am")
                pm = data.get("pm")
                if am or pm:
                    return am, pm
        for name in parent_chain(locale):
            if name == "root":
                break
            calendar = load_calendar(archive, name, cache)
            periods = calendar.get("dayPeriods", {}).get("format", {})
            for candidate in widths:
                data = periods.get(candidate, {})
                morning = data.get("morning2")
                afternoon = data.get("afternoon1")
                if morning or afternoon:
                    return morning, afternoon
        return None, None

    own_wide = own_day_period("wide")
    own_abbreviated = own_day_period("abbreviated")
    own_narrow = own_day_period("narrow")

    def day_period_value(chain, key, fallback):
        for value in chain:
            if value:
                return value
        return fallback

    eras = dict(gregorian.get("eras", {}))
    # CLDR falls back from a missing eraNames to eraAbbr when the locale has
    # no full era names of its own (root's names are a last resort).
    has_era_names = False
    for name in parent_chain(locale):
        if name == "root":
            continue
        chain_eras = load_calendar(archive, name, cache).get("eras", {})
        if chain_eras.get("eraNames"):
            has_era_names = True
            break
    if not has_era_names and eras.get("eraAbbr"):
        eras["eraNames"] = eras["eraAbbr"]
    # Per-era fallback: a missing era in the full or narrow names inherits
    # the abbreviated name of the same era.
    abbreviated = eras.get("eraAbbr", {})
    for key in ("eraNames", "eraNarrow"):
        values = dict(eras.get(key, {}))
        for era_type in ("0", "1"):
            if era_type not in values and era_type in abbreviated:
                values[era_type] = abbreviated[era_type]
        eras[key] = values
    date_formats = gregorian.get("dateFormats", {})
    time_formats = gregorian.get("timeFormats", {})
    date_time_formats = gregorian.get("dateTimeFormats", {})

    systems = load_numbering_systems(archive)
    system = default_numbering_system(archive, locale, cache)
    digits = systems.get(system, "0123456789")

    # ICU's DateTimePatternGenerator also registers the date and time style
    # patterns, which lets skeletons such as yMMMMEEEEd resolve to the full
    # date pattern of locales that do not list them in availableFormats.
    available_formats = dict(gregorian.get("availableFormats", {}))
    for style_pattern in (
        date_formats.get("full"),
        date_formats.get("long"),
        date_formats.get("medium"),
        date_formats.get("short"),
        time_formats.get("full"),
        time_formats.get("long"),
        time_formats.get("medium"),
        time_formats.get("short"),
    ):
        if style_pattern:
            available_formats.setdefault(
                pattern_skeleton(style_pattern), style_pattern
            )

    return locale, {
        "available_formats": available_formats,
        "digits": digits,
        "months_wide": names(months.get("wide", {}), MONTH_KEYS),
        "months_abbreviated": names(
            months.get("abbreviated", {}),
            MONTH_KEYS,
            months.get("wide", {}),
        ),
        "months_narrow": names(
            months.get("narrow", {}),
            MONTH_KEYS,
            months.get("abbreviated", {}),
        ),
        "months_standalone_wide": names(
            months_standalone.get("wide", {}),
            MONTH_KEYS,
            months.get("wide", {}),
        ),
        "months_standalone_abbreviated": names(
            months_standalone.get("abbreviated", {}),
            MONTH_KEYS,
            months_standalone.get("wide", {}),
            months.get("abbreviated", {}),
        ),
        "months_standalone_narrow": names(
            months_standalone.get("narrow", {}),
            MONTH_KEYS,
            months_standalone.get("abbreviated", {}),
            months.get("narrow", {}),
        ),
        "days_wide": names(days.get("wide", {}), DAY_KEYS),
        "days_abbreviated": names(
            days.get("abbreviated", {}),
            DAY_KEYS,
            days.get("wide", {}),
        ),
        "days_narrow": names(
            days.get("narrow", {}),
            DAY_KEYS,
            days.get("abbreviated", {}),
        ),
        "days_short": names(
            days.get("short", {}),
            DAY_KEYS,
            days.get("abbreviated", {}),
        ),
        "days_standalone_wide": names(
            days_standalone.get("wide", {}),
            DAY_KEYS,
            days.get("wide", {}),
        ),
        "days_standalone_abbreviated": names(
            days_standalone.get("abbreviated", {}),
            DAY_KEYS,
            days_standalone.get("wide", {}),
            days.get("abbreviated", {}),
        ),
        "days_standalone_narrow": names(
            days_standalone.get("narrow", {}),
            DAY_KEYS,
            days_standalone.get("abbreviated", {}),
            days.get("narrow", {}),
        ),
        "days_standalone_short": names(
            days_standalone.get("short", {}),
            DAY_KEYS,
            days_standalone.get("abbreviated", {}),
            days.get("short", {}),
        ),
        "quarters_wide": names(
            quarters.get("wide", {}),
            QUARTER_KEYS,
            quarters.get("abbreviated", {}),
        ),
        "quarters_abbreviated": names(
            quarters.get("abbreviated", {}),
            QUARTER_KEYS,
            quarters.get("wide", {}),
        ),
        "quarters_narrow": names(
            quarters.get("narrow", {}),
            QUARTER_KEYS,
            quarters.get("abbreviated", {}),
        ),
        "quarters_standalone_wide": names(
            quarters_standalone.get("wide", {}),
            QUARTER_KEYS,
            quarters.get("wide", {}),
        ),
        "quarters_standalone_abbreviated": names(
            quarters_standalone.get("abbreviated", {}),
            QUARTER_KEYS,
            quarters_standalone.get("wide", {}),
            quarters.get("abbreviated", {}),
        ),
        "quarters_standalone_narrow": names(
            quarters_standalone.get("narrow", {}),
            QUARTER_KEYS,
            quarters_standalone.get("abbreviated", {}),
            quarters.get("narrow", {}),
        ),
        "first_day_of_week": first_day_of_week,
        "minimal_days": minimal_days,
        "am_wide": day_period_value(
            (
                own_wide[0],
                day_periods.get("wide", {}).get("am"),
                day_periods.get("abbreviated", {}).get("am"),
            ),
            "am",
            "AM",
        ),
        "pm_wide": day_period_value(
            (
                own_wide[1],
                day_periods.get("wide", {}).get("pm"),
                day_periods.get("abbreviated", {}).get("pm"),
            ),
            "pm",
            "PM",
        ),
        "am_abbreviated": day_period_value(
            (
                own_abbreviated[0],
                own_wide[0],
                day_periods.get("abbreviated", {}).get("am"),
                day_periods.get("wide", {}).get("am"),
            ),
            "am",
            "AM",
        ),
        "pm_abbreviated": day_period_value(
            (
                own_abbreviated[1],
                own_wide[1],
                day_periods.get("abbreviated", {}).get("pm"),
                day_periods.get("wide", {}).get("pm"),
            ),
            "pm",
            "PM",
        ),
        "am_narrow": day_period_value(
            (
                own_narrow[0],
                own_abbreviated[0],
                own_wide[0],
                day_periods.get("narrow", {}).get("am"),
            ),
            "am",
            "a",
        ),
        "pm_narrow": day_period_value(
            (
                own_narrow[1],
                own_abbreviated[1],
                own_wide[1],
                day_periods.get("narrow", {}).get("pm"),
            ),
            "pm",
            "p",
        ),
        "era_wide": names(
            eras.get("eraNames", {}),
            ["0", "1"],
            {"0": "BC", "1": "AD"},
        ),
        "era_abbreviated": names(
            eras.get("eraAbbr", {}),
            ["0", "1"],
            {"0": "BC", "1": "AD"},
        ),
        "era_narrow": names(
            eras.get("eraNarrow", {}),
            ["0", "1"],
            {"0": "B", "1": "A"},
        ),
        "date_full": date_formats.get("full", "EEEE, MMMM d, y"),
        "date_long": date_formats.get("long", "MMMM d, y"),
        "date_medium": date_formats.get("medium", "MMM d, y"),
        "date_short": date_formats.get("short", "M/d/yy"),
        "time_full": time_formats.get("full", "h:mm:ss a zzzz"),
        "time_long": time_formats.get("long", "h:mm:ss a z"),
        "time_medium": time_formats.get("medium", "h:mm:ss a"),
        "time_short": time_formats.get("short", "h:mm a"),
        "date_time_full": date_time_formats.get("full", "{1}, {0}"),
        "date_time_long": date_time_formats.get("long", "{1}, {0}"),
        "date_time_medium": date_time_formats.get("medium", "{1}, {0}"),
        "date_time_short": date_time_formats.get("short", "{1}, {0}"),
        "date_time_interval": date_time_formats.get(
            "standard_medium", "{1}, {0}"
        ),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    merged_cache: dict = {}
    entries: list[tuple[str, dict]] = []
    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            entries.append(
                parse_locale_xml(archive, locale, cache, merged_cache)
            )
    if not entries:
        raise SystemExit("no locale data found")

    (out_dir / "dates_data.zig").write_text(render(entries), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
