#!/usr/bin/env python3
"""Generate the localized non-Gregorian date formatting fixture with PyICU.

Usage:
    generate_calendar_format_conformance.py out_file

Cases cover four explicit patterns and the four CLDR date styles across
locales, calendars, and sample dates at noon UTC.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "es", "it", "pt", "ru", "pl", "ar", "hi",
    "th", "ja", "zh", "ko", "fa", "am", "sw", "tr", "vi", "nl",
    "ak", "ccp", "chr", "en-001", "eo", "ff", "fo",
    "fr-BE", "ky", "lb", "nn", "no", "qu", "se", "su", "vec",
    "yue", "yue-Hans",
)

CALENDARS = (
    ("buddhist", 1),
    ("japanese", 2),
    ("roc", 3),
    ("islamic-civil", 4),
    ("islamic-tbla", 5),
    ("islamic-umalqura", 6),
    ("persian", 7),
    ("indian", 8),
    ("coptic", 9),
    ("ethiopic", 10),
    ("ethiopic-amete-alem", 11),
    ("hebrew", 12),
    ("chinese", 13),
    ("iso8601", 14),
)

PATTERNS = (
    "G y-MM-dd",
    "MMMM d, y",
    "EEEE, MMMM d, y",
    "MMM d, y",
)

DATES = (
    datetime.datetime(2024, 1, 15, 12, tzinfo=datetime.timezone.utc),
    datetime.datetime(2024, 7, 15, 12, tzinfo=datetime.timezone.utc),
    datetime.datetime(2019, 5, 1, 12, tzinfo=datetime.timezone.utc),
    datetime.datetime(2000, 2, 29, 12, tzinfo=datetime.timezone.utc),
    datetime.datetime(1990, 12, 31, 12, tzinfo=datetime.timezone.utc),
    datetime.datetime(2023, 3, 22, 12, tzinfo=datetime.timezone.utc),
)

STYLES = (
    (icu.DateFormat.kFull, 0),
    (icu.DateFormat.kLong, 1),
    (icu.DateFormat.kMedium, 2),
    (icu.DateFormat.kShort, 3),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for calendar_name, calendar_index in CALENDARS:
            # CLDR 48 renamed the Amharic Coptic era; ICU 78.3 still reports
            # the older English abbreviation, so this pair is excluded.
            if locale == "am" and calendar_name == "coptic":
                continue
            # CLDR 48 added German Chinese month names; ICU 78.3 still falls
            # back to the root M01..M12 names for this pair.
            if locale == "de" and calendar_name == "chinese":
                continue
            tag = locale + "@calendar=" + calendar_name
            for moment in DATES:
                instant = int(moment.timestamp())
                for index, pattern in enumerate(PATTERNS):
                    formatter = icu.SimpleDateFormat(pattern, icu.Locale(tag))
                    formatter.setTimeZone(icu.TimeZone.createTimeZone("UTC"))
                    cases.append(
                        (locale, calendar_index, index, instant,
                         formatter.format(moment))
                    )
                if calendar_name == "chinese":
                    # Chinese style patterns use the cyclic year fields (r/U)
                    # that this library does not format yet.
                    continue
                for style, style_index in STYLES:
                    formatter = icu.DateFormat.createDateInstance(
                        style, icu.Locale(tag)
                    )
                    formatter.setTimeZone(icu.TimeZone.createTimeZone("UTC"))
                    cases.append(
                        (locale, calendar_index, 0x80 | style_index, instant,
                         formatter.format(moment))
                    )

    blob = bytearray(b"CJKF")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, calendar_index, kind, instant, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBqHH",
            len(encoded_locale),
            calendar_index,
            kind,
            0,
            instant,
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
