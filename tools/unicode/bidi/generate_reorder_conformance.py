#!/usr/bin/env python3
"""Generate the ubidi_writeReordered conformance fixture with the ICU C API.

Usage:
    generate_reorder_conformance.py out_file

Each curated string is resolved with ubidi_setPara and written with
ubidi_writeReordered under every relevant option combination and both
paragraph levels. Set ICU_UC_LIB when the ICU common library is not in a
standard location.

Fixture format (CJRD version 1):

    magic "CJRD", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 base level (0 = LTR, 1 = RTL)
        u8 options (ICU UBIDI_KEEP_BASE_COMBINING=1, DO_MIRRORING=2,
                    REMOVE_BIDI_CONTROLS=8, OUTPUT_REVERSE=16)
        u16 input_len, input UTF-8 bytes
        u16 output_len, output UTF-8 bytes
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys
from pathlib import Path

MAGIC = b"CJRD"
FORMAT_VERSION = 1

KEEP_BASE_COMBINING = 1
DO_MIRRORING = 2
REMOVE_BIDI_CONTROLS = 8
OUTPUT_REVERSE = 16

STRINGS = (
    "",
    "abc",
    "\u05d0\u05d1\u05d2",
    "\u0623\u0628\u062c",
    "abc \u05d0\u05d1\u05d2 def",
    "\u05d0\u05d1\u05d2 123 xyz",
    "(abc) [\u05d0\u05d1\u05d2] {def}",
    "\u05d0(\u05d1)\u05d2",
    "a(b)c",
    "\u05d0\u0301\u0302",
    "a\u0301\u05d0\u0302",
    "\u202babc\u202c",
    "a\u202eb\u202cc",
    "a\u202ab\u202cc",
    "a\u202db\u202ec",
    "\u2066abc\u2069",
    "a\u2067b\u2069c",
    "\u2068abc\u2069",
    "a\u200db",
    "a\u200cb",
    "a\u200eb\u200fc",
    "abc\u200d",
    "\u200dabc",
    "abc \u05d0\u05d1\u05d2 def \u0623\u0628\u062c 123",
    "\U0001F600 abc \u05d0\u05d1\u05d2",
    "\u05d0\U0001F600\u05d1",
    "123 456 \u05d0\u05d1\u05d2 789",
    "a\n\u05d0\u05d1\u05d2\nb",
    "\u05d0\u05d1\u05d2 \n",
    "abc   ",
    "\u202b\u202b\u202babc\u202c\u202c\u202c",
    "a\u202ab\u202cc",
    "\u2066a\u2069\u2066b\u2069",
    "x \u05d0 (b) \u05d1 [c] \u05d2",
    "\u0301\u0302",
    "\u0301abc",
    "a\u0301\u0302b",
    "\u05d0)\u05d1(\u05d2",
    "\u202b\u2066a\u2069\u202c",
    "a\u2066b\u2067c\u2069d\u2069e",
    "\u05d0\n\u05d1",
    "a\u0301\n\u05d0\u0302",
    "\u200eabc\u200f",
    "\U0001F600(\u05d0)\U0001F600",
    "\u05d0\u200d\u05d1\u200c\u05d2",
)

OPTIONS = (
    0,
    KEEP_BASE_COMBINING,
    DO_MIRRORING,
    REMOVE_BIDI_CONTROLS,
    OUTPUT_REVERSE,
    DO_MIRRORING | REMOVE_BIDI_CONTROLS,
    KEEP_BASE_COMBINING | DO_MIRRORING,
    OUTPUT_REVERSE | DO_MIRRORING,
    KEEP_BASE_COMBINING | OUTPUT_REVERSE,
    DO_MIRRORING | REMOVE_BIDI_CONTROLS | OUTPUT_REVERSE,
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

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    ubidi_open = bind("ubidi_open", ctypes.c_void_p, [])
    ubidi_close = bind("ubidi_close", None, [ctypes.c_void_p])
    ubidi_set_para = bind(
        "ubidi_setPara",
        None,
        [
            ctypes.c_void_p,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            ctypes.c_uint8,
            ctypes.POINTER(ctypes.c_uint8),
            P,
        ],
    )
    ubidi_write_reordered = bind(
        "ubidi_writeReordered",
        ctypes.c_int32,
        [
            ctypes.c_void_p,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            ctypes.c_uint16,
            P,
        ],
    )

    records: list[tuple[int, int, bytes, bytes]] = []
    for text in STRINGS:
        encoded = text.encode("utf-8")
        utf16 = text.encode("utf-16-le")
        units = (U16 * (len(utf16) // 2)).from_buffer_copy(utf16)
        for base_level in (0, 1):
            bidi = ubidi_open()
            status = ctypes.c_int(0)
            ubidi_set_para(
                bidi,
                units,
                len(utf16) // 2,
                base_level,
                None,
                ctypes.byref(status),
            )
            if status.value != 0:
                raise SystemExit(f"ubidi_setPara failed for {text!r}")
            for options in OPTIONS:
                capacity = len(utf16) // 2 * 4 + 16
                destination = (U16 * capacity)()
                status = ctypes.c_int(0)
                written = ubidi_write_reordered(
                    bidi,
                    destination,
                    capacity,
                    options,
                    ctypes.byref(status),
                )
                if status.value != 0:
                    raise SystemExit(
                        f"ubidi_writeReordered failed for {text!r} "
                        f"options={options:#x}"
                    )
                raw = ctypes.string_at(
                    ctypes.addressof(destination),
                    written * 2,
                )
                output = raw.decode("utf-16-le").encode("utf-8")
                records.append((base_level, options, encoded, output))
            ubidi_close(bidi)

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(records))
    for base_level, options, encoded, output in records:
        blob += struct.pack("<BBHH", base_level, options, len(encoded), len(output))
        blob += encoded
        blob += output
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(records)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
