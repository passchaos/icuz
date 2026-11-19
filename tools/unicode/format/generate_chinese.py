#!/usr/bin/env python3
"""Generate the Chinese lunisolar calendar table with PyICU.

Usage:
    generate_chinese.py out_dir

The table covers complete Chinese years from roughly 1850 through 2150 and
stores each year's first day, cycle era, year-in-cycle, leap month, and
month-length mask. Runtime conversion is a binary search over these records.
"""

from __future__ import annotations

import datetime
import struct
import sys

import icu

START = datetime.date(1849, 6, 1)
END = datetime.date(2151, 12, 31)
EPOCH = datetime.date(1970, 1, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_dir = __import__("pathlib").Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)

    calendar = icu.Calendar.createInstance(icu.Locale("en@calendar=chinese"))
    calendar.setTimeZone(icu.TimeZone.createTimeZone("UTC"))

    def fields(date):
        moment = datetime.datetime(
            date.year, date.month, date.day, tzinfo=datetime.timezone.utc
        )
        calendar.setTime(moment)
        return (
            calendar.get(calendar.ERA),
            calendar.get(calendar.YEAR),
            calendar.get(calendar.MONTH) + 1,
            calendar.get(calendar.DATE),
            calendar.getActualMaximum(calendar.DATE),
        )

    # Find the first month start.
    date = START
    while True:
        _era, _year, _month, day, _length = fields(date)
        if day == 1:
            break
        date += datetime.timedelta(days=1)

    years = []
    current = None
    previous_month = None
    while date <= END:
        era, year, month, day, length = fields(date)
        leap = previous_month == month
        if current is None or current["era"] != era or current["year"] != year:
            if current is not None:
                years.append(current)
            current = {
                "start": (date - EPOCH).days,
                "era": era,
                "year": year,
                "leap_month": 0,
                "lengths": [],
            }
        if leap:
            current["leap_month"] = month
        current["lengths"].append(length)
        previous_month = month
        date += datetime.timedelta(days=length)
    if current is not None:
        years.append(current)

    # Drop the first and last years: the scan may clip them.
    complete = years[1:-1]
    for record in complete:
        count = len(record["lengths"])
        if count not in (12, 13):
            raise SystemExit(f"unexpected month count {count}")
        mask = 0
        for index, length in enumerate(record["lengths"]):
            if length == 30:
                mask |= 1 << index
        record["mask"] = mask

    blob = bytearray(b"CJK1")
    blob += struct.pack("<B3xHH", 1, len(complete), 0)
    for record in complete:
        blob += struct.pack(
            "<iHBBBBH",
            record["start"],
            record["era"],
            record["year"],
            len(record["lengths"]),
            record["leap_month"],
            0,
            record["mask"],
        )
    (out_dir / "chinese_data.bin").write_bytes(bytes(blob))
    print(
        f"generated {len(complete)} Chinese years, {len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
