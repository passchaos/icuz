#!/usr/bin/env python3
"""Generate the ICU-rule transliteration conformance fixture with PyICU.

Usage:
    generate_rules_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

CASES = (
    ("a > b;", ("banana", "aaa", "")),
    ("ab > X; a > y;", ("ab a", "aab", "abab")),
    ("a { b } > c;", ("ab ba", "abc", "bab")),
    ("{ a } b > X;", ("ab ac", "aab")),
    ("$v = [aeiou]; $v > X;", ("banana", "AEIOU", "xyz")),
    ("$s = xy; a > $s;", ("banana", "aaa")),
    ("a+ > X;", ("baaa b", "aaaa", "b")),
    ("a? b > X;", ("ab b", "b", "aab")),
    ("a* b > X;", ("aaab b", "b")),
    ("(ab)+ > X;", ("abab ab", "ababab", "xaby")),
    ("[a-c] > X;", ("abcdef", "cba")),
    (". > X;", ("ab", "aé")),
    ("a > ;", ("banana", "aaa")),
    ("a > b|;", ("aa", "banana")),
    ("::[a]; a > X; b > Y;", ("ab", "cab")),
    ("'a b' > X;", ("a b ab",)),
    ("'ab'+ > X;", ("abab ab",)),
    ("a b+ > X;", ("abb ab",)),
    ("ß > ss; ä > ae;", ("maß bär",)),
    ("\\u00e9 > e; \\u00e8 > e;", ("café mère",)),
    ("a <> b;", ("ab", "bb")),
    ("a < b;", ("ab",)),
    ("x { a } > A; y { a } > B; a > C;", ("xayaza", "xa ya za")),
    ("$c = [b-d]; a $c > X;", ("ab ac ad ae",)),
    ("(a)(b) > $2$1;", ("ab",)),
    ("((a)(b)) > $3$2$1;", ("ab",)),
    ("(a)+ > $1;", ("aaa",)),
    ("([ab])+ > $1;", ("ab", "ba")),
    ("((a)(b))+ > $2$3;", ("abab",)),
    ("(a) b (c) > $1$2;", ("abc",)),
    ("(a) b (c)? > $1$2;", ("ab",)),
    ("x (a) > $1;", ("xa",)),
    ("(a) x > $1;", ("ax",)),
    ("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j) > $10;", ("abcdefghij",)),
    ("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j) > $9$10;", ("abcdefghij",)),
    ("(a)? b > x$1;", ("ab", "b")),
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cases = []
    for rules, inputs in CASES:
        try:
            transliterator = icu.Transliterator.createFromRules(
                "Conformance", rules, icu.UTransDirection.FORWARD
            )
        except Exception as error:  # pragma: no cover - fixture sanity
            raise SystemExit(f"PyICU rejected rules {rules!r}: {error}")
        for text in inputs:
            cases.append((rules, text, transliterator.transliterate(text)))
    blob = bytearray(b"CJRL")
    blob += struct.pack("<B3xI", 1, len(cases))
    for rules, text, expected in cases:
        encoded_rules = rules.encode("utf-8")
        encoded_text = text.encode("utf-8")
        encoded_expected = expected.encode("utf-8")
        blob += struct.pack(
            "<HHHH",
            len(encoded_rules),
            len(encoded_text),
            len(encoded_expected),
            0,
        )
        blob += encoded_rules
        blob += encoded_text
        blob += encoded_expected
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
