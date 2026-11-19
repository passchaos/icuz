#!/usr/bin/env python3
"""Generate the number-skeleton conformance fixture with the ICU C API.

Usage:
    generate_skeleton_conformance.py out_file

PyICU does not expose NumberFormatter skeleton formatting, so this generator
loads the ICU library directly through ctypes. Set ICU_I18N_LIB when the
library is not in a standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

LOCALES = ("en", "de", "fr", "ja", "ar", "hi", "ru")

SKELETONS = (
    "percent",
    "percent .00",
    "permille",
    "precision-integer",
    ".0#",
    ".##",
    "integer-width/000",
    "group-off",
    "group-min2",
    "group-thousands",
    "sign-always",
    "sign-except-zero",
    "sign-accounting",
    "sign-accounting-always",
    "scale/100",
    "compact-short",
    "compact-long",
    "engineering",
    "engineering/+ee",
    "scientific/+ee",
    "@@@",
    "@##",
    "currency/USD",
    "currency/USD unit-width-iso-code",
    "currency/USD unit-width-full-name",
    "currency/USD unit-width-hidden",
    "currency/JPY",
    "compact-short currency/USD",
    "compact-long currency/EUR",
    "measure-unit/length-meter",
    "measure-unit/length-meter unit-width-full-name",
    "compact-short measure-unit/length-meter",
    "compact-long measure-unit/length-meter",
    "measure-unit/speed-kilometer-per-hour",
    "measure-unit/duration-hour",
    "compact-short measure-unit/duration-hour",
    "measure-unit/temperature-celsius",
)

VALUES = (0.0, 0.25, 5.0, -5.0, 1234.5, -1234.5, 1234567.0, 0.1234)


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
        if hasattr(library, f"unumf_openForSkeletonAndLocale_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned unumf symbols")

    open_formatter = getattr(
        library, f"unumf_openForSkeletonAndLocale_{version}"
    )
    open_formatter.restype = ctypes.c_void_p
    open_formatter.argtypes = [
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    open_result = getattr(library, f"unumf_openResult_{version}")
    open_result.restype = ctypes.c_void_p
    open_result.argtypes = [ctypes.POINTER(ctypes.c_int)]
    format_double = getattr(library, f"unumf_formatDouble_{version}")
    format_double.argtypes = [
        ctypes.c_void_p,
        ctypes.c_double,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    result_to_string = getattr(library, f"unumf_resultToString_{version}")
    result_to_string.restype = ctypes.c_int32
    result_to_string.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int),
    ]
    close_formatter = getattr(library, f"unumf_close_{version}")
    close_formatter.argtypes = [ctypes.c_void_p]
    close_result = getattr(library, f"unumf_closeResult_{version}")
    close_result.argtypes = [ctypes.c_void_p]

    def format_skeleton(skeleton: str, locale: str, value: float) -> str:
        encoded = skeleton.encode("utf-16-le")
        status = ctypes.c_int(0)
        formatter = open_formatter(
            encoded,
            len(encoded) // 2,
            locale.encode("utf-8"),
            ctypes.byref(status),
        )
        if not formatter or status.value > 0:
            raise SystemExit(
                f"open failed for {skeleton!r} {locale}: {status.value}"
            )
        result = open_result(ctypes.byref(status))
        format_double(formatter, value, result, ctypes.byref(status))
        if status.value > 0:
            raise SystemExit(
                f"format failed for {skeleton!r} {locale}: {status.value}"
            )
        buffer = (ctypes.c_uint16 * 512)()
        length = result_to_string(
            result, buffer, 512, ctypes.byref(status)
        )
        if length < 0 or status.value > 0:
            raise SystemExit(
                f"string failed for {skeleton!r} {locale}: {status.value}"
            )
        text = "".join(chr(buffer[index]) for index in range(length))
        close_result(result)
        close_formatter(formatter)
        return text

    cases = []
    for locale in LOCALES:
        for skeleton in SKELETONS:
            for value in VALUES:
                expected = format_skeleton(skeleton, locale, value)
                cases.append((locale, skeleton, value, expected))

    blob = bytearray(b"CJKS")
    blob += struct.pack("<B3xI", 1, len(cases))
    for locale, skeleton, value, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_skeleton = skeleton.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBHdHH",
            len(encoded_locale),
            len(encoded_skeleton),
            len(encoded_expected),
            value,
            0,
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
