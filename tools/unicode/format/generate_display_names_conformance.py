#!/usr/bin/env python3
"""Generate the locale display name conformance fixture with PyICU.

Usage:
    generate_display_names_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

DISPLAY_LOCALES = ("en", "fr", "de", "ja", "zh", "ko", "ru", "ar", "hi", "th")
LANGUAGES = ("en", "fr", "de", "zh", "sr", "und", "zgh", "qqq")
SCRIPTS = ("Latn", "Hant", "Hans", "Arab", "Zzzz")
REGIONS = ("US", "419", "ZZ", "EU", "CN", "DE")
VARIANTS = ("POSIX", "VALENCIA", "1901")
TARGETS = (
    "fr_CA", "en_US", "zh_Hant_TW", "sr_Latn_RS", "de_AT", "und_US",
    "es_419", "en", "en_Latn_US", "zh_Hans_CN", "en_US_POSIX",
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in DISPLAY_LOCALES:
        names = icu.LocaleDisplayNames.createInstance(icu.Locale(locale))
        for code in LANGUAGES:
            cases.append((0, locale, code, names.languageDisplayName(code)))
        for code in SCRIPTS:
            cases.append((1, locale, code, names.scriptDisplayName(code)))
        for code in REGIONS:
            cases.append((2, locale, code, names.regionDisplayName(code)))
        for code in VARIANTS:
            # CLDR 48 added a Korean VALENCIA variant name; ICU 78.3 still
            # returns the code.
            if locale == "ko" and code == "VALENCIA":
                continue
            cases.append((3, locale, code, names.variantDisplayName(code)))
        for target in TARGETS:
            cases.append(
                (4, locale, target, names.localeDisplayName(icu.Locale(target)))
            )

    blob = bytearray(b"CJLE")
    blob += struct.pack("<B3xI", 1, len(cases))
    for kind, locale, code, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_code = code.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBBBHHII",
            kind,
            len(encoded_locale),
            len(encoded_code),
            0,
            len(encoded_expected),
            0,
            0,
            0,
        )
        blob += encoded_locale
        blob += encoded_code
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
