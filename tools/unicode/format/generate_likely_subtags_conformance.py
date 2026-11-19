#!/usr/bin/env python3
"""Generate the likely-subtags conformance fixture with PyICU.

Usage:
    generate_likely_subtags_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

INPUTS = (
    "en", "fr", "de", "zh", "sr", "ja", "ko", "ar", "ru", "hi", "th",
    "he", "fa", "am", "sw", "tr", "vi", "id", "pl", "cs", "el", "fi",
    "und", "und_US", "und_GB", "und_Latn", "und_Arab", "und_Arab_EG",
    "und_ZZ", "und_Cyrl_RU", "en_US", "en_GB", "en_Latn_GB", "de_AT",
    "fr_CA", "pt_PT", "es_MX", "zh_Hant", "zh_Hant_HK", "zh_Hans",
    "sr_Latn", "sr_Latn_ME", "ja_Jpan_JP", "ko_Kore_KR", "sh", "qqq",
    "en_US_POSIX", "zh_Hant_TW",
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for value in INPUTS:
        expected = icu.Locale.addLikelySubtags(icu.Locale(value)).getName()
        cases.append((value, expected))
    blob = bytearray(b"CJLV")
    blob += struct.pack("<B3xI", 1, len(cases))
    for value, expected in cases:
        encoded_value = value.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BBH",
            len(encoded_value),
            len(encoded_expected),
            0,
        )
        blob += encoded_value
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
