#!/usr/bin/env python3
"""Generate a differential RBNF fixture with PyICU.

Usage:
    generate_rbnf_conformance.py out_file

The fixture stores (locale, tag, value, expected) cases produced by ICU's
RuleBasedNumberFormat for CLDR spellout and ordinal rule sets.
"""

from __future__ import annotations

import struct
import sys

import icu

LOCALES = (
    "en", "de", "es", "fr", "it", "pt", "nl", "sv", "da", "fi",
    "pl", "cs", "sk", "sl", "hr", "sr", "bg", "uk", "ru", "el",
    "tr", "ro", "hu", "et", "lv", "lt", "is", "ca", "gl", "eu",
    "ja", "zh", "ko", "th", "vi", "id", "ms", "ar", "he", "hi",
    "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "ur", "fa",
    "sw", "af", "az", "kk", "ky", "uz", "hy", "ka", "am", "ne",
)

VALUES = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 25, 30, 40, 50, 80, 90, 99, 100, 101, 105,
    110, 123, 200, 500, 999, 1000, 1001, 1234, 2000, 10000, 12345,
    100000, 1000000, 1234567, 1000000000, -1, -5, -21, -100, 1.5,
    0.5, 12.34, 100.25, 2.5,
)

TAGS = (
    (icu.URBNFRuleSetTag.SPELLOUT, 0),
    (icu.URBNFRuleSetTag.ORDINAL, 1),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for locale in LOCALES:
        for tag, tag_id in TAGS:
            try:
                formatter = icu.RuleBasedNumberFormat(tag, icu.Locale(locale))
            except Exception:
                continue
            for value in VALUES:
                try:
                    expected = formatter.format(value)
                except Exception:
                    continue
                cases.append((locale, tag_id, value, expected))

    output = bytearray(b"CJRN")
    output += struct.pack("<BBBB I", 1, 48, 0, 0, len(cases))
    for locale, tag_id, value, expected in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        output += struct.pack(
            "<BBHQ",
            len(encoded_locale),
            tag_id,
            len(encoded_expected),
            struct.unpack("<Q", struct.pack("<d", value))[0],
        )
        output += encoded_locale
        output += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(output))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
