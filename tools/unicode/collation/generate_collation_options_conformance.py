#!/usr/bin/env python3
"""Generate the collation-options conformance fixture with the ICU C API.

Usage:
    generate_collation_options_conformance.py out_file

Covers numeric collation, case level, caseFirst, and shifted variable
weighting. PyICU does not expose these attributes, so the generator loads the
ICU library directly through ctypes. Set ICU_I18N_LIB when the library is not
in a standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

OPTION_NUMERIC = 1
OPTION_CASE_LEVEL = 2
OPTION_CASE_FIRST_UPPER = 4
OPTION_SHIFTED = 8

CASES = (
    (
        OPTION_NUMERIC,
        "en",
        (
            ("a2", "a10"),
            ("a10", "a2"),
            ("a02", "a2"),
            ("a0", "a00"),
            ("a1", "a01"),
            ("a0002", "a10"),
            ("1.5", "1.10"),
            ("x9y", "x10y"),
            ("2", "b"),
            ("2", "-"),
            ("\u0662", "2"),
            ("a\u0662", "a2"),
            ("99999999999999999999", "100000000000000000000"),
            ("2", "2"),
            ("02", "2"),
            ("10", "9"),
            ("abc", "abd"),
            ("file9", "file10"),
            ("v1.2.3", "v1.10.0"),
            ("007", "7"),
            ("0", "00"),
            ("12345678901234567890", "12345678901234567891"),
            ("a1b2", "a1b10"),
        ),
    ),
    (
        OPTION_NUMERIC,
        "sv",
        (("a2", "a10"), ("\u00e5 2", "\u00e5 10"), ("z9", "z10")),
    ),
    (
        OPTION_NUMERIC,
        "de",
        (("a2", "a10"), ("stra\u00dfe2", "stra\u00dfe10")),
    ),
    (
        OPTION_NUMERIC,
        "zh",
        (("\u4e00 2", "\u4e00 10"), ("\u4e00 9", "\u4e00 10")),
    ),
    (
        OPTION_NUMERIC,
        "ru",
        (("\u0430 2", "\u0430 10"), ("\u0430 02", "\u0430 2")),
    ),
    (
        OPTION_NUMERIC,
        "ar",
        (("\u0623 2", "\u0623 10"), ("\u0662", "2")),
    ),
    (
        OPTION_CASE_LEVEL,
        "en",
        (
            ("a", "A"),
            ("A", "a"),
            ("abc", "Abc"),
            ("aB", "Ab"),
            ("a1", "aA"),
            ("aA", "a1"),
            ("Hello", "hello"),
        ),
    ),
    (
        OPTION_CASE_LEVEL | OPTION_CASE_FIRST_UPPER,
        "en",
        (
            ("a", "A"),
            ("A", "a"),
            ("aB", "Ab"),
            ("a1", "aA"),
            ("Hello", "hello"),
        ),
    ),
    (
        OPTION_CASE_LEVEL | OPTION_SHIFTED,
        "en",
        (
            ("a b", "aB"),
            ("a-b", "aB"),
            ("a b", "a b"),
        ),
    ),
    (
        OPTION_NUMERIC | OPTION_CASE_LEVEL,
        "en",
        (
            ("a2", "a10"),
            ("02", "2"),
            ("aA2", "aa10"),
        ),
    ),
    (
        OPTION_CASE_LEVEL,
        "sv",
        (("a", "A"), ("\u00e5", "\u00c5")),
    ),
    (
        OPTION_CASE_LEVEL,
        "de",
        (("a", "A"), ("stra\u00dfe", "Stra\u00dfe")),
    ),
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
        if hasattr(library, f"ucol_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ucol symbols")
    ucol_open = getattr(library, f"ucol_open_{version}")
    ucol_open.restype = ctypes.c_void_p
    ucol_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
    ucol_set_attribute = getattr(library, f"ucol_setAttribute_{version}")
    ucol_set_attribute.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_int),
    ]
    ucol_strcoll_utf8 = getattr(library, f"ucol_strcollUTF8_{version}")
    ucol_strcoll_utf8.restype = ctypes.c_int
    ucol_strcoll_utf8.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int),
    ]
    ucol_close = getattr(library, f"ucol_close_{version}")
    ucol_close.argtypes = [ctypes.c_void_p]

    # Attribute and value numbers from ICU's ucol.h.
    ucol_alternate_handling = 1
    ucol_case_first = 2
    ucol_case_level = 3
    ucol_numeric = 7
    ucol_on = 17
    ucol_shifted = 20
    ucol_non_ignorable = 21
    ucol_lower_first = 24
    ucol_upper_first = 25

    cases = []
    for options, locale, pairs in CASES:
        status = ctypes.c_int(0)
        collator = ucol_open(locale.encode("utf-8"), ctypes.byref(status))
        if not collator or status.value > 0:
            raise SystemExit(f"ucol_open failed for {locale}: {status.value}")

        def set_attribute(attribute: int, value: int) -> None:
            attr_status = ctypes.c_int(0)
            ucol_set_attribute(
                collator, attribute, value, ctypes.byref(attr_status)
            )
            if attr_status.value > 0:
                raise SystemExit(
                    f"ucol_setAttribute({attribute}, {value}) failed: "
                    f"{attr_status.value}"
                )

        if options & OPTION_NUMERIC:
            set_attribute(ucol_numeric, ucol_on)
        if options & OPTION_CASE_LEVEL:
            set_attribute(ucol_case_level, ucol_on)
        if options & OPTION_CASE_FIRST_UPPER:
            set_attribute(ucol_case_first, ucol_upper_first)
        else:
            set_attribute(ucol_case_first, ucol_lower_first)
        if options & OPTION_SHIFTED:
            set_attribute(ucol_alternate_handling, ucol_shifted)
        else:
            set_attribute(ucol_alternate_handling, ucol_non_ignorable)

        for first, second in pairs:
            status = ctypes.c_int(0)
            result = ucol_strcoll_utf8(
                collator,
                first.encode("utf-8"),
                -1,
                second.encode("utf-8"),
                -1,
                ctypes.byref(status),
            )
            if status.value > 0:
                raise SystemExit(f"strcoll failed: {status.value}")
            cases.append((options, locale, first, second, result))
        ucol_close(collator)

    blob = bytearray(b"CJNC")
    blob += struct.pack("<B3xI", 2, len(cases))
    for options, locale, first, second, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_first = first.encode("utf-8")
        encoded_second = second.encode("utf-8")
        blob += struct.pack(
            "<BHHbBB",
            len(encoded_locale),
            len(encoded_first),
            len(encoded_second),
            expected,
            options,
            0,
        )
        blob += encoded_locale
        blob += encoded_first
        blob += encoded_second
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
