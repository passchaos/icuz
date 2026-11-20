#!/usr/bin/env python3
"""Generate the Arabic shaping conformance fixture with PyICU.

Usage:
    generate_conformance.py src/unicode/shape/conformance.bin

The fixture exercises ICU's `u_shapeArabic` option matrix across every Arabic
letter in several joining contexts, Lam-Alef ligatures, tashkeel, presentation
forms, digits, and mixed-script text. It intentionally omits option
combinations where ICU's `handleGeneratedSpaces` resets the output length to
the source length after a resize pass, which leaves U+0000 padding slots;
`icuz` returns the compacted length instead (see README).
"""

from __future__ import annotations

import struct
import sys

import icu

MAGIC = b"CJSH"
FORMAT_VERSION = 1
UNICODE_VERSION = tuple(int(part) for part in icu.UNICODE_VERSION.split("."))
UNICODE_VERSION = (UNICODE_VERSION + (0, 0, 0))[:3]


def letters() -> list[str]:
    return [chr(codepoint) for codepoint in range(0x0622, 0x06D4)]


def texts() -> list[str]:
    result: list[str] = []
    for char in letters():
        result.extend(
            (
                char,
                "\u0628" + char,
                char + "\u0628",
                "\u0628" + char + "\u0628",
                "\u0644" + char,
                char + "\u0644",
            )
        )
    result.extend(
        (
            "سلام",
            "العربية",
            "لا",
            "لآ",
            "لأ",
            "لإ",
            "بِسْمِ",
            "ﷺ",
            "abc سلام 123",
            "ﻻ",
            "ﺑ",
            "ﺴﻼﻡ",
            "ﻟﺐ",
            "ﻵ",
            "ﻷ",
            "ﻹ",
            "ﻻ",
            "بًب",
            "بَب",
            "بِّب",
            "بّب",
            "بـًب",
            "بﹰب",
            "seen seen",
            "س س",
            "س\u200bس",
            "س\u0640س",
            "ي\u0621ى",
            "ءى",
            "يءى",
            "123",
            "١٢٣",
            "abc 123",
            "عربي 123 عربي",
            "عربي 123 abc",
            "abc 123 عربي",
            "مرحبا بالعالم",
            "اللغة العربية",
            "لا إله إلا الله",
            "\U0001F600 سلام \U0001F600",
            "a\u0301 سلام",
        )
    )
    for codepoint in range(0xFE70, 0xFEFD):
        char = chr(codepoint)
        result.extend((char, "\u0628" + char + "\u0628"))
    return result


def options() -> list[int]:
    # ICU U_SHAPE_* bits.
    shape = 8
    unshape = 0x10
    shape_isolated = 0x18
    lam_near, lam_end, lam_begin, lam_auto = 1, 2, 3, 0x10000
    tash_begin, tash_end, tash_resize, tash_tatweel = (
        0x40000,
        0x60000,
        0x80000,
        0xC0000,
    )
    visual = 4
    values = {
        shape,
        unshape,
        shape_isolated,
        shape | lam_near,
        shape | lam_end,
        shape | lam_begin,
        shape | lam_auto,
        shape | tash_begin,
        shape | tash_end,
        shape | tash_resize,
        shape | tash_tatweel,
        shape | 0x20,
        shape | 0x40,
        shape | 0x60,
        shape | 0x80,
        shape | 0x100,
        shape | 0x8000,
        shape | 0x200000,
        shape | 0x1000000,
        shape | 0x8000000,
        shape | visual,
        shape | visual | 0x4000000,
        shape_isolated | 0x4000,
        shape_isolated | 0x4000 | visual,
        unshape | 0x200000,
        unshape | 0x1000000,
        unshape | 0x200000 | 0x1000000,
        unshape | lam_auto,
        unshape | lam_near,
        unshape | lam_end,
        unshape | lam_begin,
        shape | lam_end | tash_end,
        shape | lam_near | tash_begin,
        shape | lam_auto | tash_end | 0x8000000,
    }
    return sorted(values)


def valid(raw: int) -> bool:
    if (raw & 0x4000) and (
        (raw & 0x18) != 0x18 or (raw & 0x10003) != 0 or (raw & 0xE0000) != 0
    ):
        return False
    lam = raw & 0x10003
    tashkeel = raw & 0xE0000
    lam_resize = lam == 0
    tashkeel_resize = tashkeel == 0x80000
    lam_placement = lam in (1, 2, 3, 0x10000)
    tashkeel_placement = tashkeel in (0x40000, 0x60000)
    if (lam_resize or tashkeel_resize) and (lam_placement or tashkeel_placement):
        return False
    return True


def build_cases() -> list[tuple[int, bytes, bytes]]:
    cases: list[tuple[int, bytes, bytes]] = []
    for raw in options():
        if not valid(raw):
            continue
        for text in texts():
            try:
                shaped = icu.Shape.shapeArabic(text, raw)
            except Exception:
                continue
            cases.append((raw, text.encode("utf-8"), shaped.encode("utf-8")))
    return cases


def write_fixture(path: str, cases: list[tuple[int, bytes, bytes]]) -> None:
    output = bytearray()
    output += MAGIC
    output += bytes((FORMAT_VERSION, *UNICODE_VERSION))
    output += struct.pack("<I", len(cases))
    for raw, source, expected in cases:
        output += struct.pack("<IHH", raw, len(source), len(expected))
        output += source
        output += expected
    with open(path, "wb") as handle:
        handle.write(output)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_conformance.py OUT")
    cases = build_cases()
    write_fixture(sys.argv[1], cases)
    print(f"wrote {len(cases)} shaping cases from ICU {icu.ICU_VERSION}")


if __name__ == "__main__":
    main()
