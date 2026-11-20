#!/usr/bin/env python3
"""Generate the DateTimePatternGenerator skeleton fixture with PyICU.

Usage:
    generate_pattern_generator_conformance.py OUT
"""

from __future__ import annotations

import struct
import sys

import icu

PATTERNS = (
    "y-MM-dd",
    "yyyy-MM-dd",
    "yyyyy-MM-dd",
    "MM/dd/yyyy",
    "M/d/yy",
    "d MMM y",
    "MMM d, y",
    "MMMM d, y",
    "EEEE, MMMM d, y",
    "EEE, MMM d, y",
    "EEEEEE, MMMM d, y",
    "H:mm",
    "HH:mm",
    "HH:mm:ss",
    "H:mm:ss.SSS",
    "h:mm a",
    "h:mm:ss a",
    "hh:mm a",
    "K:mm a",
    "k:mm",
    "j:mm",
    "J:mm",
    "C:mm",
    "m:ss",
    "m:ss.SSS",
    "m.SSS",
    "h:mm B",
    "B h:mm",
    "b h:mm",
    "a h:mm",
    "'at' h:mm a",
    "'day' d 'of' MMMM",
    "yyyy'年'M'月'd'日'",
    "G y",
    "GGGG y",
    "Q QQQ",
    "QQQQ y",
    "w W",
    "D",
    "F",
    "A",
    "g",
    "z",
    "zzzz",
    "Z",
    "ZZZZ",
    "O",
    "v",
    "vvvv",
    "V",
    "VVVV",
    "X",
    "XX",
    "XXX",
    "XXXX",
    "x",
    "xx",
    "L/d/y",
    "l/d/y",
    "c cccc",
    "e ee",
    "u",
    "U",
    "r",
    "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
)

SKELETONS = (
    "yMd",
    "yMMMd",
    "yMMMMd",
    "yMMMMEEEEd",
    "Hm",
    "hm",
    "Hms",
    "hms",
    "msS",
    "ahm",
    "Bhm",
    "bhm",
    "yQ",
    "yQQQ",
    "yw",
    "yD",
    "yMEd",
    "HmsS",
    "HmsSSS",
    "z",
    "zzzz",
    "Z",
    "ZZZZ",
    "V",
    "VVVV",
    "X",
    "XXXX",
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    generator = icu.DateTimePatternGenerator.createInstance(icu.Locale("en"))
    cases = []
    for pattern in PATTERNS:
        skeleton = generator.getSkeleton(pattern)
        cases.append((0, pattern, "", skeleton))
        cases.append((1, skeleton, "", generator.getBaseSkeleton(skeleton)))
        for candidate in SKELETONS:
            cases.append(
                (
                    2,
                    pattern,
                    candidate,
                    generator.replaceFieldTypes(pattern, candidate),
                )
            )

    blob = bytearray(b"CJPG")
    blob += struct.pack("<B3xI", 1, len(cases))
    for kind, first, second, expected in cases:
        encoded_first = first.encode("utf-8")
        encoded_second = second.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<BHHH",
            kind,
            len(encoded_first),
            len(encoded_second),
            len(encoded_expected),
        )
        blob += encoded_first
        blob += encoded_second
        blob += encoded_expected

    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} pattern-generator cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
