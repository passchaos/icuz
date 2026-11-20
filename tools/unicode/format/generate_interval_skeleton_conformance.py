#!/usr/bin/env python3
"""Generate the skeleton date/time interval conformance fixture with PyICU.

Usage:
    generate_interval_skeleton_conformance.py out_file

Cases cover ICU DateIntervalFormat skeleton formatting: date-only, time-only,
and combined skeletons across the locale set.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

LOCALES = (
    "en", "fr", "de", "es", "it", "pt", "ru", "pl", "ar", "hi",
    "th", "ja", "zh", "ko", "fa", "tr", "vi", "nl", "sv", "da",
    "ak", "ccp", "chr", "ee", "en-001", "eo", "ff", "fo",
    "fr-BE", "ky", "lb", "no", "qu", "se", "su", "vec",
    "yue-Hans",
)

SKELETONS = (
    "yMd",
    "yMMMd",
    "yMMMMd",
    "yMMMMEEEEd",
    "yM",
    "y",
    "MMMd",
    "Md",
    "MMM",
    "M",
    "d",
    "yMMM",
    "Hm",
    "hm",
    "H",
    "h",
    "Hms",
    "hms",
    "yMMMdHm",
    "yMdHm",
    "yMMMdH",
    "yMMMdHms",
    "yMMMMEEEEdHm",
)

PAIRS = (
    # Same day, minute difference.
    (datetime.datetime(2024, 1, 15, 12, 0), datetime.datetime(2024, 1, 15, 12, 30)),
    # Same day, hour difference.
    (datetime.datetime(2024, 1, 15, 8, 0), datetime.datetime(2024, 1, 15, 10, 30)),
    # Same day, day-period crossing.
    (datetime.datetime(2024, 1, 15, 11, 30), datetime.datetime(2024, 1, 15, 13, 30)),
    # Same time, day difference.
    (datetime.datetime(2024, 1, 15, 12, 0), datetime.datetime(2024, 1, 18, 12, 0)),
    # Same time, month difference.
    (datetime.datetime(2024, 1, 15, 12, 0), datetime.datetime(2024, 3, 18, 12, 0)),
    # Same time, year difference.
    (datetime.datetime(2024, 1, 15, 12, 0), datetime.datetime(2025, 3, 18, 12, 0)),
    # Cross-day time range.
    (datetime.datetime(2024, 1, 15, 23, 30), datetime.datetime(2024, 1, 16, 1, 30)),
    # Combined: same day, time difference.
    (datetime.datetime(2024, 1, 15, 13, 45), datetime.datetime(2024, 1, 15, 17, 30)),
    # Combined: day difference.
    (datetime.datetime(2024, 1, 15, 13, 45), datetime.datetime(2024, 1, 18, 13, 45)),
    # Combined: day and time difference.
    (datetime.datetime(2024, 1, 15, 13, 45), datetime.datetime(2024, 1, 18, 17, 30)),
    # Combined: second difference.
    (datetime.datetime(2024, 1, 15, 13, 45, 10), datetime.datetime(2024, 1, 15, 13, 45, 50)),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    icu.TimeZone.setDefault(icu.TimeZone.createTimeZone("UTC"))
    cases = []
    for locale in LOCALES:
        icu_locale = icu.Locale(locale + "@calendar=gregorian")
        for skeleton in SKELETONS:
            formatter = icu.DateIntervalFormat.createInstance(skeleton, icu_locale)
            formatter.getDateFormat().setTimeZone(icu.TimeZone.createTimeZone("UTC"))
            for start, end in PAIRS:
                a = start.replace(tzinfo=datetime.timezone.utc)
                b = end.replace(tzinfo=datetime.timezone.utc)
                expected = formatter.format(icu.DateInterval(a, b))
                cases.append((locale, skeleton, start, end, expected))

    blob = bytearray(b"CJIS")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, skeleton, start, end, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_skeleton = skeleton.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBH hBBBBBx hBBBBBx HH",
            len(encoded_locale),
            len(encoded_skeleton),
            0,
            start.year,
            start.month,
            start.day,
            start.hour,
            start.minute,
            start.second,
            end.year,
            end.month,
            end.day,
            end.hour,
            end.minute,
            end.second,
            len(encoded_expected),
            0,
        )
        blob += encoded_locale
        blob += encoded_skeleton
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
