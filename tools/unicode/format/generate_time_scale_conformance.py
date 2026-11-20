#!/usr/bin/env python3
"""Generate the ICU time-scale conformance fixture.

Usage:
    generate_time_scale_conformance.py out_file

Uses the ICU 78 C API (`utmscale_fromInt64`, `utmscale_toInt64`).
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

SCALES = 10
UTSV_FROM_MIN = 2
UTSV_FROM_MAX = 3
UTSV_TO_MIN = 4
UTSV_TO_MAX = 5


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
    raise SystemExit(
        "could not load libicui18n; set ICU_I18N_LIB to the ICU i18n library"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"utmscale_fromInt64_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned utmscale symbols")

    from_int64 = getattr(library, f"utmscale_fromInt64_{version}")
    from_int64.restype = ctypes.c_int64
    from_int64.argtypes = [
        ctypes.c_int64,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int32),
    ]
    to_int64 = getattr(library, f"utmscale_toInt64_{version}")
    to_int64.restype = ctypes.c_int64
    to_int64.argtypes = [
        ctypes.c_int64,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int32),
    ]
    get_value = getattr(library, f"utmscale_getTimeScaleValue_{version}")
    get_value.restype = ctypes.c_int64
    get_value.argtypes = [
        ctypes.c_int32,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int32),
    ]

    cases = []
    common = (0, 1, -1, 123456789, -123456789, 1000000000, -1000000000)
    universal = (
        0,
        1,
        -1,
        123456789,
        -123456789,
        621355968000000000,
        -621355968000000000,
    )
    for scale in range(SCALES):
        status = ctypes.c_int32(0)
        from_min = get_value(scale, UTSV_FROM_MIN, ctypes.byref(status))
        from_max = get_value(scale, UTSV_FROM_MAX, ctypes.byref(status))
        to_min = get_value(scale, UTSV_TO_MIN, ctypes.byref(status))
        to_max = get_value(scale, UTSV_TO_MAX, ctypes.byref(status))
        for value in common + (from_min, from_max):
            status = ctypes.c_int32(0)
            expected = from_int64(value, scale, ctypes.byref(status))
            if status.value == 0:
                cases.append((0, scale, value, expected))
        for value in universal + (to_min, to_max):
            status = ctypes.c_int32(0)
            expected = to_int64(value, scale, ctypes.byref(status))
            if status.value == 0:
                cases.append((1, scale, value, expected))

    blob = bytearray(b"CJTS")
    blob += struct.pack("<B3xI", 1, len(cases))
    for kind, scale, value, expected in cases:
        blob += struct.pack("<BBxxqq", kind, scale, value, expected)
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} time-scale cases from ICU {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
