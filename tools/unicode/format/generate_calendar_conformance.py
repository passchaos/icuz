#!/usr/bin/env python3
"""Generate the non-Gregorian calendar conversion fixture with PyICU.

Usage:
    generate_calendar_conformance.py out_file

Each case stores the CLDR calendar index, days since 1970-01-01, and the
era/year/month/day that ICU computes for that instant in UTC.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

# Indices match the `Calendar` enum in src/unicode/format/calendar.zig.
CALENDARS = (
    ("gregorian", 0),
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
    ("iso8601", 14),
)

START = datetime.date(1900, 1, 1)
END = datetime.date(2100, 12, 31)
STEP = 45


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    epoch = datetime.date(1970, 1, 1)
    dates = []
    current = START
    while current <= END:
        dates.append(current)
        current += datetime.timedelta(days=STEP)
    for extra in (
        datetime.date(1900, 2, 28),
        datetime.date(1900, 3, 1),
        datetime.date(2000, 2, 29),
        datetime.date(2019, 4, 30),
        datetime.date(2019, 5, 1),
        datetime.date(2024, 3, 20),
        datetime.date(2024, 3, 21),
        datetime.date(2024, 3, 22),
        datetime.date(2023, 9, 11),
        datetime.date(2023, 9, 12),
        datetime.date(2100, 1, 1),
    ):
        if extra not in dates:
            dates.append(extra)

    cases = []
    for name, index in CALENDARS:
        calendar = icu.Calendar.createInstance(
            icu.Locale("en@calendar=" + name)
        )
        calendar.setTimeZone(icu.TimeZone.createTimeZone("UTC"))
        month_formatter = icu.SimpleDateFormat(
            "M", icu.Locale("en@calendar=" + name)
        )
        month_formatter.setTimeZone(icu.TimeZone.createTimeZone("UTC"))
        for date in dates:
            moment = datetime.datetime(
                date.year, date.month, date.day, tzinfo=datetime.timezone.utc
            )
            calendar.setTime(moment)
            era = calendar.get(calendar.ERA)
            year = calendar.get(calendar.YEAR)
            month = int(month_formatter.format(moment))
            day = calendar.get(calendar.DATE)
            days = (date - epoch).days
            cases.append((index, era, year, month, day, days))

    blob = bytearray(b"CJKC")
    blob += struct.pack("<B3xI", 1, len(cases))
    for index, era, year, month, day, days in cases:
        blob += struct.pack(
            "<BBBBHH i q",
            index,
            month,
            day,
            0,
            era,
            0,
            year,
            days,
        )
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
