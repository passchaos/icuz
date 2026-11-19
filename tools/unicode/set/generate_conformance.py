#!/usr/bin/env python3
"""Generate the UnicodeSet algebra conformance fixture with PyICU.

Usage:
    generate_conformance.py out_file
"""

from __future__ import annotations

import struct
import sys

import icu

PATTERNS = (
    "[a-z]",
    "[m-p0-9]",
    "[^a-z]",
    "[\\p{Lu}]",
    "[\\p{sc=Greek}]",
    "[0-9]",
    "[a-zA-Z0-9]",
    "[\\u0000-\\u007f]",
    "[]",
    "[\\p{Nd}]",
)

SAMPLES = (
    0,
    1,
    9,
    0x20,
    0x30,
    0x39,
    0x41,
    0x4D,
    0x5A,
    0x61,
    0x6D,
    0x70,
    0x7A,
    0x7B,
    0xE9,
    0xC9,
    0x301,
    0x391,
    0x3B1,
    0x410,
    0x5D0,
    0x660,
    0x4E00,
    0xAC00,
    0x1F600,
    0x10FFFF,
)

OP_UNION = 0
OP_INTERSECTION = 1
OP_DIFFERENCE = 2
OP_COMPLEMENT = 3
OP_CONTAINS_ALL = 4
OP_CONTAINS_NONE = 5
OP_CONTAINS_SOME = 6


def ranges(unicode_set):
    return [
        (unicode_set.getRangeStart(index), unicode_set.getRangeEnd(index))
        for index in range(unicode_set.getRangeCount())
    ]


def contains_all(a_ranges, b_ranges):
    for first, last in b_ranges:
        covered = any(
            start <= first and end >= last for start, end in a_ranges
        )
        if not covered:
            return False
    return True


def contains_none(a_ranges, b_ranges):
    left = 0
    right = 0
    while left < len(a_ranges) and right < len(b_ranges):
        a_first, a_last = a_ranges[left]
        b_first, b_last = b_ranges[right]
        if a_last < b_first:
            left += 1
        elif b_last < a_first:
            right += 1
        else:
            return False
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    sets = {}
    for pattern in PATTERNS:
        try:
            sets[pattern] = icu.UnicodeSet(pattern)
        except Exception as error:  # pragma: no cover - fixture sanity
            raise SystemExit(f"PyICU rejected {pattern!r}: {error}")

    cases = []
    for first in PATTERNS:
        a = sets[first]
        for op in (OP_COMPLEMENT,):
            cases.append((op, first, "", a))
        for second in PATTERNS:
            b = sets[second]
            for op in (
                OP_UNION,
                OP_INTERSECTION,
                OP_DIFFERENCE,
                OP_CONTAINS_ALL,
                OP_CONTAINS_NONE,
                OP_CONTAINS_SOME,
            ):
                cases.append((op, first, second, (a, b)))

    blob = bytearray(b"CJSU")
    blob += struct.pack("<B3xI", 1, len(cases))
    for op, first, second, payload in cases:
        encoded_first = first.encode("utf-8")
        encoded_second = second.encode("utf-8")
        if op <= OP_COMPLEMENT:
            blob += struct.pack(
                "<BHHHHH",
                op,
                len(encoded_first),
                len(encoded_second),
                len(SAMPLES),
                0,
                0,
            )
            blob += encoded_first
            blob += encoded_second
            a = payload if op == OP_COMPLEMENT else payload[0]
            b = None if op == OP_COMPLEMENT else payload[1]
            for codepoint in SAMPLES:
                character = chr(codepoint)
                if op == OP_UNION:
                    expected = a.contains(character) or b.contains(character)
                elif op == OP_INTERSECTION:
                    expected = a.contains(character) and b.contains(character)
                elif op == OP_DIFFERENCE:
                    expected = a.contains(character) and not b.contains(character)
                else:
                    expected = not a.contains(character)
                blob += struct.pack("<IB", codepoint, 1 if expected else 0)
        else:
            a, b = payload
            a_ranges = ranges(a)
            b_ranges = ranges(b)
            if op == OP_CONTAINS_ALL:
                expected = contains_all(a_ranges, b_ranges)
            elif op == OP_CONTAINS_NONE:
                expected = contains_none(a_ranges, b_ranges)
            else:
                expected = not contains_none(a_ranges, b_ranges)
            blob += struct.pack(
                "<BHHHHH",
                op,
                len(encoded_first),
                len(encoded_second),
                0,
                0,
                0,
            )
            blob += encoded_first
            blob += encoded_second
            blob += bytes((1 if expected else 0,))

    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(blob))
    print(f"wrote {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
