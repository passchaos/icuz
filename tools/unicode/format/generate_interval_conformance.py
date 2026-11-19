#!/usr/bin/env python3
"""Generate the date/time interval conformance fixture with PyICU.

Usage:
    generate_interval_conformance.py cldr-common-48.zip out_file

Cases cover the interval skeletons this library stores directly (yMd,
yMMMd, Hm/hm), selected from the locale's CLDR intervalFormats so that
fallback-derived patterns are not compared.
"""

from __future__ import annotations

import datetime
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import icu

LOCALES = (
    "en", "fr", "de", "es", "it", "pt", "ru", "pl", "ar", "hi",
    "th", "ja", "zh", "ko", "fa", "tr", "vi", "nl", "sv", "da",
)

PARENT = {
    "de-AT": "de", "de-CH": "de", "en-AU": "en-001", "en-CA": "en-001",
    "en-GB": "en-001", "en-IN": "en-001", "es-419": "es", "es-MX": "es-419",
    "fr-CA": "fr", "nb": "no", "nl-BE": "nl", "pt-PT": "pt", "zh-Hant": "root",
}

DATE_CASES = (
    # (skeleton, style index, start, end, greatest-difference key)
    ("yMd", 3, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2024, 1, 18, 12), "d"),
    ("yMd", 3, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2024, 3, 18, 12), "M"),
    ("yMd", 3, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2025, 3, 18, 12), "y"),
    ("yMMMd", 2, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2024, 1, 18, 12), "d"),
    ("yMMMd", 2, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2024, 3, 18, 12), "M"),
    ("yMMMd", 2, datetime.datetime(2024, 1, 15, 12), datetime.datetime(2025, 3, 18, 12), "y"),
)

TIME_CASES = (
    # (start, end, greatest-difference key)
    (datetime.datetime(2024, 1, 15, 12, 0), datetime.datetime(2024, 1, 15, 12, 30), "m"),
    (datetime.datetime(2024, 1, 15, 8, 0), datetime.datetime(2024, 1, 15, 10, 30), "H"),
    (datetime.datetime(2024, 1, 15, 11, 30), datetime.datetime(2024, 1, 15, 13, 30), "a"),
)


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
            parent = current.split("-")[0]
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def interval_keys(archive: zipfile.ZipFile, locale: str, skeleton: str) -> set[str]:
    keys: set[str] = set()
    for name in parent_chain(locale):
        filename = name.replace("-", "_")
        try:
            text = archive.read(f"common/main/{filename}.xml")
        except KeyError:
            continue
        document = ET.fromstring(text)
        element = document.find(
            ".//dates/calendars/calendar[@type='gregorian']/dateTimeFormats/intervalFormats"
        )
        if element is None:
            continue
        for item in element.findall("intervalFormatItem"):
            if item.get("id") != skeleton:
                continue
            for difference in item.findall("greatestDifference"):
                keys.add(difference.get("id"))
    return keys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    icu.TimeZone.setDefault(icu.TimeZone.createTimeZone("UTC"))
    cases = []
    with zipfile.ZipFile(archive_path) as archive:
        for locale in LOCALES:
            icu_locale = icu.Locale(locale + "@calendar=gregorian")
            short_pattern = icu.DateFormat.createTimeInstance(
                icu.DateFormat.kShort, icu_locale
            ).toPattern()
            twelve = "h" in short_pattern
            time_skeleton = "hm" if twelve else "Hm"
            time_keys = interval_keys(archive, locale, time_skeleton)
            for skeleton, style, start, end, key in DATE_CASES:
                if key not in interval_keys(archive, locale, skeleton):
                    continue
                formatter = icu.DateIntervalFormat.createInstance(
                    skeleton, icu_locale
                )
                formatter.getDateFormat().setTimeZone(
                    icu.TimeZone.createTimeZone("UTC")
                )
                a = start.replace(tzinfo=datetime.timezone.utc)
                b = end.replace(tzinfo=datetime.timezone.utc)
                expected = formatter.format(icu.DateInterval(a, b))
                cases.append(
                    (locale, 0, style, int(a.timestamp()), int(b.timestamp()),
                     expected)
                )
            for start, end, key in TIME_CASES:
                if key not in time_keys:
                    continue
                formatter = icu.DateIntervalFormat.createInstance(
                    time_skeleton, icu_locale
                )
                formatter.getDateFormat().setTimeZone(
                    icu.TimeZone.createTimeZone("UTC")
                )
                a = start.replace(tzinfo=datetime.timezone.utc)
                b = end.replace(tzinfo=datetime.timezone.utc)
                expected = formatter.format(icu.DateInterval(a, b))
                cases.append(
                    (locale, 1, 3, int(a.timestamp()), int(b.timestamp()),
                     expected)
                )

    blob = bytearray(b"CJI1")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, kind, style, start, end, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBqqH H",
            len(encoded_locale),
            kind,
            style,
            0,
            start,
            end,
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_expected
    with open(sys.argv[2], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
