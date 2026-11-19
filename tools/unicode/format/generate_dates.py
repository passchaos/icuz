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

LOCALES = (
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "de-AT", "de-CH", "el", "en", "en-AU", "en-CA",
    "en-GB", "en-IN", "es", "es-419", "es-MX", "et", "eu", "fa", "fi",
    "fil", "fr", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "lo",
    "lt", "lv", "mk", "ml", "mn", "mr", "ms", "mt", "my", "nb", "ne",
    "nl", "nl-BE", "pa", "pl", "ps", "pt", "pt-PT", "ro", "ru", "si",
    "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk",
    "ur", "uz", "vi", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-AU": "en-001",
    "en-CA": "en-001",
    "en-GB": "en-001",
    "en-IN": "en-001",
    "es-419": "es",
    "es-MX": "es-419",
    "fr-CA": "fr",
    "nb": "no",
    "nl-BE": "nl",
    "pt-PT": "pt",
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


def names(values: dict, keys: list[str], fallback: dict | None = None) -> list[str]:
    result: list[str] = []
    for key in keys:
        value = values.get(key)
        if value is None and fallback is not None:
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


SKELETON_ORDER = "GyMdkHmsSEDFwWahKzZ"


def canonical_skeleton(skeleton: str) -> str:
    fields: list[tuple[str, int]] = []
    index = 0
    while index < len(skeleton):
        letter = skeleton[index]
        end = index
        while end < len(skeleton) and skeleton[end] == letter:
            end += 1
        fields.append((letter, end - index))
        index = end

    def order(field: tuple[str, int]) -> int:
        position = SKELETON_ORDER.find(field[0])
        return position if position >= 0 else len(SKELETON_ORDER)

    fields.sort(key=order)
    return "".join(letter * count for letter, count in fields)


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
        "    days_wide: [7][]const u8,",
        "    days_abbreviated: [7][]const u8,",
        "    days_narrow: [7][]const u8,",
        "    days_short: [7][]const u8,",
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
            f".days_wide = {string_array('days_wide')}, "
            f".days_abbreviated = {string_array('days_abbreviated')}, "
            f".days_narrow = {string_array('days_narrow')}, "
            f".days_short = {string_array('days_short')}, "
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
            f".date_time_short = {zig_string(values['date_time_short'])} "
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
        for fmt in length:
            if fmt.tag != "dateTimeFormat":
                continue
            if fmt.get("type", "standard") != "standard":
                continue
            for pattern in fmt:
                if pattern.tag != "pattern":
                    continue
                if pattern.get("alt") is not None:
                    continue
                result[length_type] = pattern.text or ""
                break
            if length_type in result:
                break
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
    day_periods = format_widths("dayPeriods")

    def own_day_period(width: str):
        # am/pm inherit per locale across widths, then through the parent
        # chain (including root). Flexible day periods are the last resort.
        widths = [width] + [
            other for other in ("wide", "abbreviated", "narrow")
            if other != width
        ]
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

    return locale, {
        "available_formats": gregorian.get("availableFormats", {}),
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
