#!/usr/bin/env python3
"""Generate localized non-Gregorian calendar data from CLDR.

Usage:
    generate_calendars.py cldr-common-48.zip out_dir

Reads `common/main/<locale>.xml` calendar blocks for the supported calendars,
resolves the CLDR parent chain, and emits a deduplicated `CJCD` v1 blob with
month names, era names, and full/long/medium/short date patterns.
"""

from __future__ import annotations

import hashlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

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
    "de-AT": "de", "de-CH": "de", "en-001": "en", "en-AU": "en-001",
    "en-CA": "en-001", "en-GB": "en-001", "en-IN": "en-001",
    "es-419": "es", "es-MX": "es-419", "fa-AF": "fa", "fr-BE": "fr",
    "fr-CA": "fr", "nb": "no", "nn": "no", "nl-BE": "nl", "pt-PT": "pt",
    "yue-Hans": "yue", "zh-Hant": "root",
}

# Calendar indices match src/unicode/format/calendar.zig.
CALENDARS = (
    (1, "buddhist", ()),
    (2, "japanese", ()),
    (3, "roc", ()),
    (4, "islamic-civil", ("islamic",)),
    (5, "islamic-tbla", ("islamic",)),
    (6, "islamic-umalqura", ("islamic",)),
    (7, "persian", ()),
    (8, "indian", ()),
    (9, "coptic", ()),
    (10, "ethiopic", ()),
    (11, "ethiopic-amete-alem", ("ethiopic",)),
    (12, "hebrew", ()),
    (13, "chinese", ()),
    (14, "iso8601", ()),
)

# Calendars whose months come from the Gregorian calendar.
GREGORIAN_MONTHS = {1, 2, 3, 14}
# Calendars with no month names at all in CLDR/ICU.
NO_MONTHS = {14}

MONTH_WIDTHS = ("wide", "abbreviated", "narrow")
WIDTH_FALLBACK = {
    "wide": ("wide",),
    "abbreviated": ("abbreviated", "wide"),
    "narrow": ("narrow", "abbreviated", "wide"),
}
STYLES = ("full", "long", "medium", "short")

FLAG_GREGORIAN_MONTHS = 1
FLAG_LEAP_MONTHS = 2


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


def load_document(archive: zipfile.ZipFile, locale: str, cache: dict):
    if locale in cache:
        return cache[locale]
    filename = locale.replace("-", "_")
    try:
        text = archive.read(f"common/main/{filename}.xml")
    except KeyError:
        cache[locale] = None
        return None
    document = ET.fromstring(text)
    cache[locale] = document
    return document


def calendar_element(document, name: str):
    if document is None:
        return None
    return document.find(f".//dates/calendars/calendar[@type='{name}']")


def month_data(element) -> dict:
    data = {}
    if element is None:
        return data
    for context in element.findall("months/monthContext"):
        context_type = context.get("type")
        for width in context.findall("monthWidth"):
            width_type = width.get("type")
            for month in width.findall("month"):
                value = (month.text or "").strip()
                if value:
                    data[
                        (
                            context_type,
                            width_type,
                            int(month.get("type")),
                            month.get("yeartype"),
                        )
                    ] = value
    return data


def era_data(element) -> dict:
    data = {}
    if element is None:
        return data
    for width, tag in (("wide", "eraNames"), ("abbreviated", "eraAbbr"),
                       ("narrow", "eraNarrow")):
        for era in element.findall(f"eras/{tag}/era"):
            value = (era.text or "").strip()
            if value:
                data[(width, int(era.get("type")))] = value
    return data


def month_pattern_data(element) -> dict:
    data = {}
    if element is None:
        return data
    patterns = element.find("monthPatterns")
    if patterns is None:
        return data
    for context in patterns.findall("monthPatternContext"):
        context_type = context.get("type")
        for width in context.findall("monthPatternWidth"):
            width_type = width.get("type")
            for pattern in width.findall("monthPattern"):
                if pattern.get("type") != "leap":
                    continue
                value = (pattern.text or "").strip()
                if value:
                    data[(context_type, width_type)] = value
    return data


def pattern_data(element) -> dict:
    data = {}
    if element is None:
        return data
    for length in element.findall("dateFormats/dateFormatLength"):
        style = length.get("type")
        pattern = length.findtext("dateFormat/pattern")
        if style in STYLES and pattern:
            data[style] = pattern
    return data


def merged_calendar_data(archive, locale: str, cache: dict) -> dict:
    """Collect month/era/pattern data for every calendar from the chain."""
    chain = parent_chain(locale)
    result = {index: {"months": {}, "eras": {}, "patterns": {}, "leap": {}}
              for index, _name, _fallbacks in CALENDARS}
    for name in chain:
        document = load_document(archive, name, cache)
        if document is None:
            continue
        for index, calendar_name, fallbacks in CALENDARS:
            for candidate in (calendar_name, *fallbacks):
                element = calendar_element(document, candidate)
                if element is None:
                    continue
                for key, value in month_data(element).items():
                    result[index]["months"].setdefault(key, value)
                for key, value in era_data(element).items():
                    result[index]["eras"].setdefault(key, value)
                for key, value in pattern_data(element).items():
                    result[index]["patterns"].setdefault(key, value)
                for key, value in month_pattern_data(element).items():
                    result[index]["leap"].setdefault(key, value)
    for name in chain:
        document = load_document(archive, name, cache)
        if document is None:
            continue
        generic = calendar_element(document, "generic")
        for key, value in pattern_data(generic).items():
            for index, _name, _fallbacks in CALENDARS:
                result[index]["patterns"].setdefault(key, value)
    return result


def root_calendar_data(archive, cache: dict) -> dict:
    return merged_calendar_data(archive, "root", cache)


def month_row(raw: dict, month: int, yeartype: str | None) -> tuple:
    row = []
    for width in MONTH_WIDTHS:
        value = ""
        # CLDR falls back through wider widths within the format context
        # before using stand-alone names.
        for context in ("format", "stand-alone"):
            for candidate_width in WIDTH_FALLBACK[width]:
                candidate = raw.get((context, candidate_width, month, yeartype))
                if not candidate and yeartype is not None:
                    candidate = raw.get((context, candidate_width, month, None))
                if candidate:
                    value = candidate
                    break
            if value:
                break
        row.append(value)
    return tuple(row)


def trim_rows(rows: list) -> list:
    while rows and not any(rows[-1]):
        rows.pop()
    return rows


def resolve_months(
    raw: dict,
    calendar_index: int,
) -> tuple[list, list]:
    if calendar_index in GREGORIAN_MONTHS or calendar_index in NO_MONTHS:
        return [], []
    has_leap = any(key[3] == "leap" for key in raw)
    if has_leap:
        # Hebrew-style calendars: leap years have 13 months; non-leap years
        # skip month 6 (Adar I).
        leap = trim_rows([month_row(raw, month, "leap") for month in range(1, 14)])
        non_leap = trim_rows(
            [
                month_row(raw, month, None)
                for month in (1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13)
            ]
        )
        return non_leap, leap
    return trim_rows([month_row(raw, month, None) for month in range(1, 14)]), []


def resolve_eras(raw: dict, calendar_index: int, root_raw: dict) -> list:
    types = sorted({key[1] for key in raw} | {key[1] for key in root_raw})
    eras = []
    for era_type in types:
        row = []
        for width in MONTH_WIDTHS:
            value = raw.get((width, era_type), "")
            if not value:
                value = root_raw.get((width, era_type), "")
            if not value:
                value = raw.get(("abbreviated", era_type), "")
            if not value:
                value = root_raw.get(("abbreviated", era_type), "")
            row.append(value)
        if any(row):
            eras.append((era_type, row[0], row[1], row[2]))
    return eras


def render(locale_records: dict, cache: dict) -> bytes:
    strings = bytearray(b"\x00")
    string_offsets: dict[str, int] = {"": 0}

    def intern(value: str) -> int:
        if not value:
            return 0
        if value in string_offsets:
            return string_offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        string_offsets[value] = offset
        return offset

    record_index: dict[str, int] = {}
    records = []
    month_bytes = bytearray()
    era_bytes = bytearray()
    locale_bytes = bytearray()
    locale_calendar_bytes = bytearray()
    for locale in sorted(locale_records):
        entries = locale_records[locale]
        cal_start = len(locale_calendar_bytes) // 4
        for calendar_index in sorted(entries):
            months, leap_months, eras, patterns, leap_patterns = entries[calendar_index]
            key = hashlib.sha256(
                repr((months, eras, patterns)).encode("utf-8")
            ).hexdigest()
            record = record_index.get(key)
            if record is None:
                record = len(records)
                record_index[key] = record
                month_start = len(month_bytes) // 12
                for row in months:
                    month_bytes += struct.pack(
                        "<III", *(intern(value) for value in row)
                    )
                leap_start = len(month_bytes) // 12
                for row in leap_months:
                    month_bytes += struct.pack(
                        "<III", *(intern(value) for value in row)
                    )
                era_start = len(era_bytes) // 16
                for era_type, wide, abbreviated, narrow in eras:
                    era_bytes += struct.pack(
                        "<HHIII",
                        era_type,
                        0,
                        intern(wide),
                        intern(abbreviated),
                        intern(narrow),
                    )
                flags = FLAG_GREGORIAN_MONTHS if calendar_index in GREGORIAN_MONTHS else 0
                if calendar_index in NO_MONTHS:
                    flags = 0
                if leap_months:
                    flags |= FLAG_LEAP_MONTHS
                records.append(
                    (
                        calendar_index,
                        flags,
                        len(months),
                        len(leap_months),
                        month_start,
                        era_start,
                        len(eras),
                        leap_start if leap_months else 0,
                        *(intern(patterns.get(style, "")) for style in STYLES),
                        intern(leap_patterns["wide"]),
                        intern(leap_patterns["abbreviated"]),
                        intern(leap_patterns["narrow"]),
                        intern(leap_patterns["numeric"]),
                    )
                )
            locale_calendar_bytes += struct.pack(
                "<BBH", calendar_index, 0, record
            )
        id_offset = intern(locale)
        locale_bytes += struct.pack(
            "<IBBHHH",
            id_offset,
            len(locale.encode("utf-8")),
            0,
            cal_start,
            len(entries),
            0,
        )

    record_bytes = bytearray()
    for record in records:
        record_bytes += struct.pack("<BBBBIIHHIIIIIIII", *record)

    header = bytearray(b"CJKD")
    header += struct.pack(
        "<B3xHHHHIIII4x",
        1,
        len(locale_records),
        len(records),
        len(locale_calendar_bytes) // 4,
        0,
        len(month_bytes) // 12,
        len(era_bytes) // 16,
        len(strings),
        0,
    )
    return bytes(
        header
        + locale_bytes
        + locale_calendar_bytes
        + record_bytes
        + month_bytes
        + era_bytes
        + strings
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    locale_records = {}
    with zipfile.ZipFile(archive_path) as archive:
        root_raw = root_calendar_data(archive, cache)
        for locale in LOCALES:
            merged = merged_calendar_data(archive, locale, cache)
            entries = {}
            for index, _name, _fallbacks in CALENDARS:
                months, leap_months = resolve_months(
                    merged[index]["months"], index
                )
                eras = resolve_eras(
                    merged[index]["eras"], index, root_raw[index]["eras"]
                )
                patterns = dict(merged[index]["patterns"])
                for style in STYLES:
                    if not patterns.get(style):
                        patterns[style] = root_raw[index]["patterns"].get(style, "")
                raw_leap = dict(root_raw[index]["leap"])
                raw_leap.update(merged[index]["leap"])
                wide = raw_leap.get(("format", "wide"), "")
                leap_patterns = {
                    "wide": wide,
                    "abbreviated": raw_leap.get(("format", "abbreviated"), wide),
                    "narrow": raw_leap.get(
                        ("format", "narrow"),
                        raw_leap.get(("stand-alone", "narrow"), wide),
                    ),
                    "numeric": raw_leap.get(("numeric", "all"), wide),
                }
                entries[index] = (
                    months,
                    leap_months,
                    eras,
                    patterns,
                    leap_patterns,
                )
            locale_records[locale] = entries

    blob = render(locale_records, cache)
    (out_dir / "calendars_data.bin").write_bytes(blob)
    print(
        f"generated {len(locale_records)} locales, {len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
