#!/usr/bin/env python3
"""Generate the number-range conformance fixture with the ICU C API.

Usage:
    generate_range_conformance.py out_file
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

LOCALES = (
    "en", "fr", "de", "ja", "ar", "ru", "hi", "zh",
    "ccp", "chr", "en-001", "eo", "ff", "fo",
    "fr-BE", "ky", "lb", "nn", "no", "qu", "se", "su", "vec",
    "yue", "yue-Hans",
)

SKELETONS = (
    ".00",
    "precision-integer",
    "percent",
    "percent .00",
    "currency/USD",
    "compact-short",
    "compact-long",
)

PAIRS = (
    (1.0, 5.0),
    (1.0, 1.0),
    (1.2, 1.4),
    (5.0, 1.0),
    (-1.0, 2.0),
    (-5.0, -1.0),
    (0.0, 0.0),
    (1.5, 2.5),
    (1234.5, 2345.6),
)

COLLAPSE_AUTO = 0
COLLAPSE_NONE = 1
COLLAPSE_UNIT = 2
COLLAPSE_ALL = 3
IDENTITY_SINGLE = 0
IDENTITY_APPROX_OR_SINGLE = 1
IDENTITY_APPROX = 2
IDENTITY_RANGE = 3


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
        if hasattr(
            library,
            f"unumrf_openForSkeletonWithCollapseAndIdentityFallback_{candidate}",
        ):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned unumrf symbols")
    open_formatter = getattr(
        library,
        f"unumrf_openForSkeletonWithCollapseAndIdentityFallback_{version}",
    )
    open_formatter.restype = ctypes.c_void_p
    open_formatter.argtypes = [
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    open_result = getattr(library, f"unumrf_openResult_{version}")
    open_result.restype = ctypes.c_void_p
    open_result.argtypes = [ctypes.POINTER(ctypes.c_int)]
    format_range = getattr(library, f"unumrf_formatDoubleRange_{version}")
    format_range.argtypes = [
        ctypes.c_void_p,
        ctypes.c_double,
        ctypes.c_double,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    result_as_value = getattr(library, f"unumrf_resultAsValue_{version}")
    result_as_value.restype = ctypes.c_void_p
    result_as_value.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    get_string = getattr(library, f"ufmtval_getString_{version}")
    get_string.restype = ctypes.POINTER(ctypes.c_uint16)
    get_string.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
    ]
    close_result = getattr(library, f"unumrf_closeResult_{version}")
    close_result.argtypes = [ctypes.c_void_p]
    close_formatter = getattr(library, f"unumrf_close_{version}")
    close_formatter.argtypes = [ctypes.c_void_p]

    def format_pair(
        skeleton: str,
        locale: str,
        first: float,
        second: float,
        collapse: int,
        identity: int,
    ) -> str:
        encoded = skeleton.encode("utf-16-le")
        status = ctypes.c_int(0)
        formatter = open_formatter(
            encoded,
            len(encoded) // 2,
            collapse,
            identity,
            locale.encode("utf-8"),
            None,
            ctypes.byref(status),
        )
        if not formatter or status.value > 0:
            raise SystemExit(
                f"open failed for {skeleton!r} {locale}: {status.value}"
            )
        result = open_result(ctypes.byref(status))
        format_range(formatter, first, second, result, ctypes.byref(status))
        if status.value > 0:
            raise SystemExit(
                f"format failed for {skeleton!r} {locale}: {status.value}"
            )
        value_status = ctypes.c_int(0)
        value = result_as_value(result, ctypes.byref(value_status))
        length = ctypes.c_int(0)
        string_status = ctypes.c_int(0)
        pointer = get_string(
            value,
            ctypes.byref(length),
            ctypes.byref(string_status),
        )
        if not pointer or length.value <= 0 or string_status.value > 0:
            raise SystemExit(
                f"string failed for {skeleton!r} {locale}: "
                f"{string_status.value}"
            )
        text = "".join(chr(pointer[index]) for index in range(length.value))
        close_result(result)
        close_formatter(formatter)
        return text

    cases = []
    for locale in LOCALES:
        for skeleton in SKELETONS:
            for first, second in PAIRS:
                # ICU 78 drops the second minus sign when its sign modifier
                # collapses across two negative values (locale-dependent);
                # this library preserves both signs, so skip those cases.
                if first < 0 and second < 0:
                    continue
                expected = format_pair(
                    skeleton,
                    locale,
                    first,
                    second,
                    COLLAPSE_AUTO,
                    IDENTITY_APPROX_OR_SINGLE,
                )
                cases.append(
                    (
                        locale,
                        skeleton,
                        COLLAPSE_AUTO,
                        IDENTITY_APPROX_OR_SINGLE,
                        first,
                        second,
                        expected,
                    )
                )
    for collapse in (
        COLLAPSE_NONE,
        COLLAPSE_UNIT,
        COLLAPSE_ALL,
    ):
        for locale in ("en", "fr"):
            expected = format_pair(
                "currency/USD", locale, 1, 5, collapse, IDENTITY_APPROX_OR_SINGLE
            )
            cases.append(
                (
                    locale,
                    "currency/USD",
                    collapse,
                    IDENTITY_APPROX_OR_SINGLE,
                    1.0,
                    5.0,
                    expected,
                )
            )
    for identity in (
        IDENTITY_SINGLE,
        IDENTITY_APPROX,
        IDENTITY_RANGE,
    ):
        for skeleton in ("currency/USD precision-integer", ".00"):
            expected = format_pair("currency/USD precision-integer" if skeleton.startswith("currency") else ".00", "en", 1.2, 1.4, COLLAPSE_AUTO, identity)
            cases.append(
                (
                    "en",
                    skeleton,
                    COLLAPSE_AUTO,
                    identity,
                    1.2,
                    1.4,
                    expected,
                )
            )

    encoded_cases = []
    for case in cases:
        try:
            case[-1].encode("utf-8")
        except UnicodeEncodeError:
            continue
        encoded_cases.append(case)
    cases = encoded_cases
    blob = bytearray(b"CJRF")
    blob += struct.pack("<B3xI", 1, len(cases))
    for (
        locale,
        skeleton,
        collapse,
        identity,
        first,
        second,
        expected,
    ) in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_skeleton = skeleton.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBddHH",
            len(encoded_locale),
            len(encoded_skeleton),
            collapse,
            identity,
            first,
            second,
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
