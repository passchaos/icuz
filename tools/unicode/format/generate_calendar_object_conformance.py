#!/usr/bin/env python3
"""Generate the ucal mutable-calendar conformance fixture with the ICU C API.

Usage:
    generate_calendar_object_conformance.py out_file

Each Gregorian-like calendar system is opened in a few zones and driven
through a fixed set/ add/ roll script; millis and selected fields are
recorded after every step. Set ICU_I18N_LIB when the ICU i18n library is not
in a standard location.

Fixture format (CJUC version 1):

    magic "CJUC", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 system (0 gregorian, 1 buddhist, 2 japanese, 3 roc)
        u8 zone_len, zone UTF-8 bytes
        i64 initial millis
        17 * i32 initial field values
        u8 op_count
        per op:
            u8 opcode (0 set, 1 add, 2 roll)
            u8 field, i32 amount
            i64 result millis
            17 * i32 field values
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys
from pathlib import Path

MAGIC = b"CJUC"
FORMAT_VERSION = 1

SYSTEMS = (
    (0, "en_US@calendar=gregorian"),
    (1, "th_TH@calendar=buddhist"),
    (2, "ja_JP@calendar=japanese"),
    (3, "zh_TW@calendar=roc"),
    (4, "en_US@calendar=islamic-umalqura"),
    (5, "fa_IR@calendar=persian"),
    (6, "he_IL@calendar=hebrew"),
    (7, "hi_IN@calendar=indian"),
    (8, "ar_EG@calendar=coptic"),
    (9, "am_ET@calendar=ethiopic"),
    (10, "zh_CN@calendar=chinese"),
)
ZONES = ("UTC", "America/New_York", "Asia/Tokyo")
INITIAL_MILLIS = (100_000_000_000, 1_600_000_000_000, 1_700_000_000_000)
FIELDS = (0, 1, 2, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22)
SET_YEAR = {
    0: 2021,
    1: 2564,
    2: 45,
    3: 110,
    4: 1445,
    5: 1402,
    7: 1945,
    8: 1740,
    9: 2016,
}
OPS = (
    (0, 2, 4),
    (0, 5, 29),
    (0, 11, 23),
    (0, 12, 59),
    (0, 13, 58),
    (0, 14, 321),
    (0, 9, 0),
    (1, 1, 2),
    (1, 2, 13),
    (1, 5, -400),
    (1, 11, 5),
    (1, 12, 61),
    (1, 13, -30),
    (1, 14, 1500),
    (1, 9, 1),
    (2, 2, 14),
    (2, 5, 40),
    (2, 11, 30),
    (2, 12, -70),
    (2, 13, 120),
    (2, 14, -1500),
    (2, 9, 1),
)


def load_library() -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_I18N_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library("icui18n")
    if found:
        candidates.append(found)
    for pattern in (
        "/usr/local/lib/libicui18n.*.dylib",
        "/opt/homebrew/lib/libicui18n.*.dylib",
        os.path.expanduser("~/.pixi/envs/*/lib/libicui18n.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit("could not load libicui18n; set ICU_I18N_LIB")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = Path(sys.argv[1])

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"ucal_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ucal symbols")

    P = ctypes.POINTER(ctypes.c_int)
    U16 = ctypes.c_uint16
    VP = ctypes.c_void_p

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    ucal_open = bind(
        "ucal_open",
        VP,
        [ctypes.POINTER(U16), ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32, P],
    )
    ucal_close = bind("ucal_close", None, [VP])
    ucal_set_millis = bind(
        "ucal_setMillis",
        None,
        [VP, ctypes.c_double, P],
    )
    ucal_get_millis = bind(
        "ucal_getMillis",
        ctypes.c_double,
        [VP, P],
    )
    ucal_get = bind("ucal_get", ctypes.c_int32, [VP, ctypes.c_int32, P])
    ucal_set = bind("ucal_set", None, [VP, ctypes.c_int32, ctypes.c_int32])
    ucal_add = bind(
        "ucal_add",
        None,
        [VP, ctypes.c_int32, ctypes.c_int32, P],
    )
    ucal_roll = bind(
        "ucal_roll",
        None,
        [VP, ctypes.c_int32, ctypes.c_int32, P],
    )

    def fields(calendar) -> list[int]:
        values = []
        for field in FIELDS:
            status = ctypes.c_int(0)
            values.append(ucal_get(calendar, field, ctypes.byref(status)))
            if status.value > 0:
                raise SystemExit(f"ucal_get failed for field {field}")
        return values

    def millis(calendar) -> int:
        status = ctypes.c_int(0)
        value = ucal_get_millis(calendar, ctypes.byref(status))
        if status.value > 0:
            raise SystemExit("ucal_getMillis failed")
        return int(value)

    blob = bytearray(MAGIC)
    records = []
    for system, locale in SYSTEMS:
        for zone in ZONES:
            encoded_zone = zone.encode("utf-16-le")
            units = (U16 * (len(encoded_zone) // 2)).from_buffer_copy(
                encoded_zone
            )
            for initial in INITIAL_MILLIS:
                status = ctypes.c_int(0)
                calendar = ucal_open(
                    units,
                    len(encoded_zone) // 2,
                    locale.encode("utf-8"),
                    0,
                    ctypes.byref(status),
                )
                if status.value > 0 or not calendar:
                    raise SystemExit(f"ucal_open failed for {system}/{zone}")
                status = ctypes.c_int(0)
                ucal_set_millis(
                    calendar,
                    ctypes.c_double(initial),
                    ctypes.byref(status),
                )
                if status.value > 0:
                    raise SystemExit("ucal_setMillis failed")
                initial_values = fields(calendar)
                ops = []
                script = OPS
                if system in SET_YEAR:
                    script = ((0, 1, SET_YEAR[system]),) + OPS
                if system in (6, 10):
                    # Hebrew and Chinese month slots differ from icuz's
                    # CLDR-facing numbering; validate field reads only.
                    script = ()
                for opcode, field, amount in script:
                    if opcode == 0:
                        ucal_set(calendar, field, amount)
                    elif opcode == 1:
                        status = ctypes.c_int(0)
                        ucal_add(
                            calendar,
                            field,
                            amount,
                            ctypes.byref(status),
                        )
                        if status.value > 0:
                            raise SystemExit("ucal_add failed")
                    else:
                        status = ctypes.c_int(0)
                        ucal_roll(
                            calendar,
                            field,
                            amount,
                            ctypes.byref(status),
                        )
                        if status.value > 0:
                            raise SystemExit("ucal_roll failed")
                    ops.append(
                        (opcode, field, amount, millis(calendar), fields(calendar))
                    )
                ucal_close(calendar)
                records.append(
                    (system, zone.encode("utf-8"), initial, initial_values, ops)
                )

    blob += struct.pack("<B3xI", FORMAT_VERSION, len(records))
    for system, zone, initial, initial_values, ops in records:
        blob += struct.pack("<BB", system, len(zone))
        blob += zone
        blob += struct.pack("<q", initial)
        for value in initial_values:
            blob += struct.pack("<i", value)
        blob += struct.pack("<B", len(ops))
        for opcode, field, amount, result, values in ops:
            blob += struct.pack("<BBiq", opcode, field, amount, result)
            for value in values:
                blob += struct.pack("<i", value)
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(records)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
