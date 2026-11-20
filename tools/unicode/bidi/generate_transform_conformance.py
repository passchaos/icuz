#!/usr/bin/env python3
"""Generate the ubiditransform conformance fixture with the ICU C API.

Usage:
    generate_transform_conformance.py out_file

Every supported scheme (all except the two runs-only combinations) is run
over a curated string set with both mirroring settings and two shaping
option sets. Set ICU_I18N_LIB when the ICU i18n library is not in a standard
location.

Fixture format (CJTF version 1):

    magic "CJTF", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 in level, u8 out level, u8 in order, u8 out order
        u8 mirroring, u32 shaping options
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

MAGIC = b"CJTF"
FORMAT_VERSION = 1

LTR = 0
RTL = 1
DEFAULT_LTR = 0xFE
DEFAULT_RTL = 0xFF
LOGICAL = 0
VISUAL = 1
MIRRORING_OFF = 0
MIRRORING_ON = 1

STRINGS = (
    "",
    "abc",
    "\u05d0\u05d1\u05d2",
    "\u0623\u0628\u062c",
    "abc \u05d0\u05d1\u05d2 def",
    "\u05d0\u05d1\u05d2 123 xyz",
    "a(b)c",
    "\u05d0(\u05d1)\u05d2",
    "x \u05d0 (b) \u05d1 [c] \u05d2",
    "1\u0662",
    "\u05d0 12 \u05d1",
    "abc 123 \u05d0\u05d1\u05d2 456 def",
    "\u0623\u0628\u062c 123 abc",
    "\u05d0\u0301\u0302",
    "a\u0301\u05d0\u0302",
    "\u202babc\u202c",
    "a\u202eb\u202cc",
    "\u2066abc\u2069",
    "a\u2067b\u2069c",
    "\u05d0\u200d\u05d1",
    "a\n\u05d0\u05d1\u05d2\nb",
)

LEVELS = (LTR, RTL, DEFAULT_LTR, DEFAULT_RTL)
ORDERS = (LOGICAL, VISUAL)
SHAPING = (0, 0x8)


def load_library() -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_I18N_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library("icui18n")
    if found:
        candidates.append(found)
    for pattern in (
        "/usr/local/lib/libicui18n.*.dylib",
        "/opt/homebrew/lib/libicui18n.*.dylib",
        os.path.expanduser("~/.pixi/envs/*/lib/libicui18n.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit("could not load libicui18n; set ICU_I18N_LIB")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = Path(sys.argv[1])

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"ubiditransform_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ubiditransform symbols")

    P = ctypes.POINTER(ctypes.c_int)
    U16 = ctypes.c_uint16
    VP = ctypes.c_void_p

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    transform_open = bind("ubiditransform_open", VP, [P])
    transform_close = bind("ubiditransform_close", None, [VP])
    transform = bind(
        "ubiditransform_transform",
        ctypes.c_int32,
        [
            VP,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            ctypes.POINTER(U16),
            ctypes.c_int32,
            ctypes.c_uint8,
            ctypes.c_int32,
            ctypes.c_uint8,
            ctypes.c_int32,
            ctypes.c_int32,
            ctypes.c_uint32,
            P,
        ],
    )

    records: list[tuple[int, int, int, int, int, int, bytes, bytes]] = []
    for text in STRINGS:
        utf8 = text.encode("utf-8")
        utf16 = text.encode("utf-16-le")
        units = (U16 * (len(utf16) // 2)).from_buffer_copy(utf16)
        for in_level in LEVELS:
            for out_level in LEVELS:
                for in_order in ORDERS:
                    for out_order in ORDERS:
                        if in_order == LOGICAL and out_order == LOGICAL and (
                            (in_level == LTR and out_level == RTL)
                            or (in_level == RTL and out_level == LTR)
                        ):
                            # Runs-only schemes are not supported by icuz yet.
                            pass
                        for mirroring in (MIRRORING_OFF, MIRRORING_ON):
                            for shaping in SHAPING:
                                status = ctypes.c_int(0)
                                handle = transform_open(ctypes.byref(status))
                                if status.value > 0 or not handle:
                                    raise SystemExit("ubiditransform_open failed")
                                destination = (U16 * (len(utf16) // 2 * 4 + 32))()
                                status = ctypes.c_int(0)
                                written = transform(
                                    handle,
                                    units,
                                    len(utf16) // 2,
                                    destination,
                                    len(destination),
                                    in_level,
                                    in_order,
                                    out_level,
                                    out_order,
                                    mirroring,
                                    shaping,
                                    ctypes.byref(status),
                                )
                                transform_close(handle)
                                if status.value > 0 or written < 0:
                                    raise SystemExit(
                                        f"ubiditransform_transform failed for "
                                        f"{text!r} levels={in_level}/{out_level} "
                                        f"orders={in_order}/{out_order}"
                                    )
                                raw = ctypes.string_at(
                                    ctypes.addressof(destination),
                                    written * 2,
                                )
                                output = raw.decode("utf-16-le").encode("utf-8")
                                records.append(
                                    (
                                        in_level,
                                        out_level,
                                        in_order,
                                        out_order,
                                        mirroring,
                                        shaping,
                                        utf8,
                                        output,
                                    )
                                )

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(records))
    for (
        in_level,
        out_level,
        in_order,
        out_order,
        mirroring,
        shaping,
        utf8,
        output,
    ) in records:
        blob += struct.pack(
            "<BBBBBIHH",
            in_level,
            out_level,
            in_order,
            out_order,
            mirroring,
            shaping,
            len(utf8),
            len(output),
        )
        blob += utf8
        blob += output
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(records)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
