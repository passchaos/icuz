#!/usr/bin/env python3
"""Generate the UText conformance fixture with the ICU C API.

Usage:
    generate_conformance.py out_file

UTF-8 and UTF-16 providers are driven through utext_openUTF8 /
utext_openUChars. Each case records forward and backward iteration, index
snapping, moveIndex32, and extract results. Set ICU_UC_LIB when the ICU
common library is not in a standard location.

Fixture format (CJUT version 1):

    magic "CJUT", u8 version, 3 reserved bytes, u32 case_count
    per case:
        u8 kind (0 = UTF-8, 1 = UTF-16)
        u16 input_len, input bytes (UTF-8 or UTF-16LE)
        u32 op_count
        per op:
            u8 opcode (0 set, 1 next, 2 previous, 3 move, 4 extract)
            i64 arg0, i64 arg1, i64 result
            u32 extra_count, extra_count * u32
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys
from pathlib import Path

MAGIC = b"CJUT"
FORMAT_VERSION = 1

STRINGS = (
    "",
    "abc",
    "a b\tc\n",
    "caf\u00e9",
    "e\u0301",
    "\u00e9\u00e8\u00ea",
    "\u65e5\u672c\u8a9e",
    "\U0001F600",
    "a\U0001F600b",
    "\U0001F600\U0001F601",
    "a\u05d0\u05d1b",
    "\u05d0\u0301\u0302",
    "\u200d\U0001F600\u200d",
    "x\u0301\U0001F600y",
    "\u0e01\u0e02\u0e03",
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
        if hasattr(library, f"utext_openUTF8_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned utext symbols")

    P = ctypes.POINTER(ctypes.c_int)
    U16 = ctypes.c_uint16
    VP = ctypes.c_void_p

    def bind(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    utext_open_utf8 = bind(
        "utext_openUTF8",
        VP,
        [VP, ctypes.c_char_p, ctypes.c_int64, P],
    )
    utext_open_u16 = bind(
        "utext_openUChars",
        VP,
        [VP, ctypes.POINTER(U16), ctypes.c_int64, P],
    )
    utext_close = bind("utext_close", VP, [VP])
    utext_native_length = bind("utext_nativeLength", ctypes.c_int64, [VP])
    utext_get_index = bind("utext_getNativeIndex", ctypes.c_int64, [VP])
    utext_set_index = bind(
        "utext_setNativeIndex",
        None,
        [VP, ctypes.c_int64],
    )
    utext_next32 = bind("utext_next32", ctypes.c_int32, [VP])
    utext_previous32 = bind("utext_previous32", ctypes.c_int32, [VP])
    utext_move = bind(
        "utext_moveIndex32",
        ctypes.c_int32,
        [VP, ctypes.c_int32],
    )
    utext_extract = bind(
        "utext_extract",
        ctypes.c_int32,
        [VP, ctypes.c_int64, ctypes.c_int64, ctypes.POINTER(U16), ctypes.c_int32, P],
    )

    cases: list[tuple[int, bytes, list[tuple]]] = []
    for text in STRINGS:
        utf8 = text.encode("utf-8")
        utf16 = text.encode("utf-16-le")
        units = (U16 * (len(utf16) // 2)).from_buffer_copy(utf16)
        for kind, payload in ((0, utf8), (1, utf16)):
            if kind == 0:
                status = ctypes.c_int(0)
                ut = utext_open_utf8(None, payload, len(payload), ctypes.byref(status))
            else:
                status = ctypes.c_int(0)
                ut = utext_open_u16(
                    None,
                    units,
                    len(utf16) // 2,
                    ctypes.byref(status),
                )
            if status.value != 0 or not ut:
                raise SystemExit(f"utext open failed for {text!r} kind {kind}")

            length = utext_native_length(ut)
            ops: list[tuple] = []

            utext_set_index(ut, 0)
            while True:
                codepoint = utext_next32(ut)
                ops.append((1, 0, 0, codepoint, []))
                if codepoint == -1:
                    break

            utext_set_index(ut, length)
            while True:
                codepoint = utext_previous32(ut)
                ops.append((2, 0, 0, codepoint, []))
                if codepoint == -1:
                    break

            for index in range(length + 1):
                utext_set_index(ut, index)
                snapped = utext_get_index(ut)
                ops.append((0, index, 0, snapped, []))
                ops.append((1, 0, 0, utext_next32(ut), []))

            for start in (0, length):
                for delta in (-2, -1, 0, 1, 2, 5):
                    utext_set_index(ut, start)
                    ops.append((0, start, 0, utext_get_index(ut), []))
                    ok = utext_move(ut, delta)
                    ops.append((3, delta, utext_get_index(ut), ok, []))

            boundaries = {0}
            position = 0
            for character in text:
                if kind == 0:
                    position += len(character.encode("utf-8"))
                else:
                    position += len(character.encode("utf-16-le")) // 2
                boundaries.add(position)
            ranges = ((0, 1), (0, length), (1, length), (1, length - 1), (length // 2, length))
            for start, limit in ranges:
                if start < 0 or limit < start or limit > length:
                    continue
                if start not in boundaries or limit not in boundaries:
                    continue
                buffer = (U16 * (length * 2 + 8))()
                status = ctypes.c_int(0)
                written = utext_extract(
                    ut,
                    start,
                    limit,
                    buffer,
                    len(buffer),
                    ctypes.byref(status),
                )
                if status.value != 0 or written < 0:
                    raise SystemExit(
                        f"utext_extract failed for {text!r} kind {kind}"
                    )
                raw = ctypes.string_at(ctypes.addressof(buffer), written * 2)
                extracted = raw.decode("utf-16-le")
                codepoints = [ord(ch) for ch in extracted]
                ops.append((4, start, limit, len(codepoints), codepoints))

            utext_close(ut)
            cases.append((kind, payload, ops))

    blob = bytearray(MAGIC)
    blob += struct.pack("<B3xI", FORMAT_VERSION, len(cases))
    for kind, payload, ops in cases:
        blob += struct.pack("<BH", kind, len(payload))
        blob += payload
        blob += struct.pack("<I", len(ops))
        for opcode, arg0, arg1, result, extra in ops:
            blob += struct.pack("<BqqqI", opcode, arg0, arg1, result, len(extra))
            for codepoint in extra:
                blob += struct.pack("<I", codepoint)
    out_path.write_bytes(bytes(blob))
    print(f"wrote {len(blob)} bytes, {len(cases)} cases", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
