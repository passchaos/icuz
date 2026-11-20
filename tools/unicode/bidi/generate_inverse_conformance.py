#!/usr/bin/env python3
"""Generate the inverse-bidi level conformance fixture with the ICU C API.

Usage:
    generate_inverse_conformance.py out_file

Each string is resolved with ubidi_setInverse(true) and
UBIDI_REORDER_INVERSE_LIKE_DIRECT for both paragraph levels; the resulting
ubidi_getLevels values are stored. Set ICU_UC_LIB when the ICU common
library is not in a standard location.

Fixture format (CJIW version 1):

    magic "CJIW", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 base level (0 = LTR, 1 = RTL)
        u16 input_len, input UTF-8 bytes
        u16 level_count, level_count bytes
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys
from pathlib import Path

MAGIC = b"CJIW"
FORMAT_VERSION = 1
INVERSE_LIKE_DIRECT = 5

STRINGS = (
    "abc",
    "\u05d0\u05d1\u05d2",
    "\u0623\u0628\u062c",
    "abc \u05d0\u05d1\u05d2 def",
    "\u05d0\u05d1\u05d2 123 xyz",
    "a(b)c",
    "\u05d0(\u05d1)\u05d2",
    "1\u0662",
    "\u05d0\u0661\u05d1",
    "\u05d0 12 \u05d1",
    "abc 123 \u05d0\u05d1\u05d2 456 def",
    "\u0623\u0628\u062c 123 abc",
    "\u05d0\u0301\u0302",
    "a\u0301\u05d0\u0302",
    "abc   ",
    "\u05d0\u05d1\u05d2 ",
    "\u202babc\u202c",
    "a\u202eb\u202cc",
    "a\u202ab\u202cc",
    "\u2066abc\u2069",
    "a\u2067b\u2069c",
    "\u05d0\u200d\u05d1",
    "a\n\u05d0\u05d1\u05d2\nb",
    "123",
    "\u05d0\u05d1 456 \u05d2\u05d3",
    "abc \u05d0 123 \u05d1 def",
    "\u05d0 1 \u05d1 2 \u05d2",
    "x \u05d0 (b) \u05d1 [c] \u05d2",
    "\u05d0\u05d1\u05d2 abc \u05d3\u05d4\u05d5",
)


def load_library() -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_UC_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library("icuuc")
    if found:
        candidates.append(found)
    for pattern in (
        "/usr/local/lib/libicuuc.*.dylib",
        "/opt/homebrew/lib/libicuuc.*.dylib",
        os.path.expanduser("~/.pixi/envs/*/lib/libicuuc.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit("could not load libicuuc; set ICU_UC_LIB")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = Path(sys.argv[1])

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"ubidi_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ubidi symbols")

    P = ctypes.POINTER(ctypes.c_int)
    U16 = ctypes.c_uint16
    VP = ctypes.c_void_p

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    ubidi_open = bind("ubidi_open", VP, [])
    ubidi_close = bind("ubidi_close", None, [VP])
    ubidi_set_inverse = bind(
        "ubidi_setInverse",
        None,
        [VP, ctypes.c_int8],
    )
    ubidi_set_mode = bind(
        "ubidi_setReorderingMode",
        None,
        [VP, ctypes.c_int32],
    )
    ubidi_set_para = bind(
        "ubidi_setPara",
        None,
        [VP, ctypes.POINTER(U16), ctypes.c_int32, ctypes.c_uint8, VP, P],
    )
    ubidi_get_levels = bind(
        "ubidi_getLevels",
        ctypes.POINTER(ctypes.c_uint8),
        [VP, P],
    )

    cases: list[tuple[int, bytes, bytes]] = []
    for text in STRINGS:
        utf8 = text.encode("utf-8")
        utf16 = text.encode("utf-16-le")
        units = (U16 * (len(utf16) // 2)).from_buffer_copy(utf16)
        for base_level in (0, 1):
            bidi = ubidi_open()
            ubidi_set_inverse(bidi, 1)
            ubidi_set_mode(bidi, INVERSE_LIKE_DIRECT)
            status = ctypes.c_int(0)
            ubidi_set_para(
                bidi,
                units,
                len(utf16) // 2,
                base_level,
                None,
                ctypes.byref(status),
            )
            if status.value > 0:
                raise SystemExit(f"ubidi_setPara failed for {text!r}")
            status = ctypes.c_int(0)
            levels = ubidi_get_levels(bidi, ctypes.byref(status))
            if status.value > 0:
                raise SystemExit(f"ubidi_getLevels failed for {text!r}")
            count = len(utf16) // 2
            cases.append(
                (
                    base_level,
                    utf8,
                    bytes(levels[index] for index in range(count)),
                )
            )
            ubidi_close(bidi)

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(cases))
    for base_level, utf8, levels in cases:
        blob += struct.pack("<BHH", base_level, len(utf8), len(levels))
        blob += utf8
        blob += levels
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
