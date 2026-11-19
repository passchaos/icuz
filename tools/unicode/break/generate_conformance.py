#!/usr/bin/env python3
"""Generate the break-rule conformance fixture with PyICU.

Usage:
    generate_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

CASES = (
    (
        "$l = [A-Za-z]; $l+;",
        ("abc def", "ab1cd", "123", ""),
    ),
    (
        "$l = [A-Za-z]; $l+; [\\u0020]+;",
        ("abc def ghi", "abc", " a b "),
    ),
    (
        "$l = [A-Za-z]; $l+ {100}; [\\u0020]+ {200};",
        ("abc def", " a b "),
    ),
    (
        "$l = [A-Za-z]; ($l | [0-9])+;",
        ("ab12cd", "abc", "12"),
    ),
    (
        "[0-9]+; $l = [A-Za-z]; $l+;",
        ("abc123", "123abc"),
    ),
    (
        "$d = [0-9]; $d+; $l = [A-Za-z]; $l+; $s = [\\u0020]; $s+;",
        ("ab12 cd", "12ab"),
    ),
    (
        "$l = [A-Za-z]; ($l $l)+;",
        ("abcd", "abcde"),
    ),
    (
        "$x = [\\p{sc=Greek}]; $x+; [\\u0020]+;",
        ("αβγ de",),
    ),
    (
        "$l = [A-Za-z]; $l+ / [\\u0020]; [\\u0020]+;",
        ("abc def ghi", "abc"),
    ),
    (
        "$l = [A-Za-z]; $l+; $l+ / [0-9]; [0-9]+;",
        ("abc123",),
    ),
    (
        "$l = [A-Za-z]; $l+ / [\\u0020] {100}; [\\u0020]+ {200};",
        ("abc def",),
    ),
    (
        "$l = [A-Za-z]; !$l+; $l+;",
        ("abc def",),
    ),
    (
        "$l = [A-Za-z]; !$l+; [\\u0020]+;",
        ("abc def",),
    ),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for rules, texts in CASES:
        for text in texts:
            iterator = icu.RuleBasedBreakIterator(rules)
            iterator.setText(text)
            boundaries = []
            while True:
                position = iterator.nextBoundary()
                if position == -1:
                    break
                boundaries.append((position, iterator.getRuleStatus()))
            cases.append((rules, text, boundaries))
    blob = bytearray(b"CJGF")
    blob += struct.pack("<B3xI", 1, len(cases))
    for rules, text, boundaries in cases:
        encoded_rules = rules.encode("utf-8")
        encoded_text = text.encode("utf-8")
        blob += struct.pack(
            "<HHHH",
            len(encoded_rules),
            len(encoded_text),
            len(boundaries),
            0,
        )
        blob += encoded_rules
        blob += encoded_text
        for position, status in boundaries:
            blob += struct.pack("<II", position, status)
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
