#!/usr/bin/env python3
"""Generate the ICU converter-selector (ucnvsel) conformance fixture.

Usage:
    generate_selector_conformance.py out_file
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

MAGIC = b"CJVS"
FORMAT_VERSION = 1

CONVERTERS = [
    "UTF-8",
    "UTF-16LE",
    "UTF-16BE",
    "US-ASCII",
    "ISO-8859-1",
    "ISO-8859-2",
    "ISO-8859-5",
    "ISO-8859-6",
    "ISO-8859-7",
    "ISO-8859-8",
    "ISO-8859-15",
    "windows-1251",
    "windows-1252",
    "windows-1253",
    "windows-1254",
    "windows-1255",
    "windows-1256",
    "windows-1257",
    "windows-1258",
    "KOI8-R",
    "IBM866",
    "Shift_JIS",
    "GBK",
    "GB18030",
    "EUC-JP",
    "ISO-2022-JP",
]

CASES = [
    "",
    "hello",
    "café",
    "€",
    "αβγ",
    "Привет",
    "مرحبا",
    "עברית",
    "日本語",
    "中文",
    "한국어",
    "😀",
    "a€б日",
    "Œœß",
    "€£¥",
    "①②③",
    "\u00a0",
]

EXCLUDED_CASES = [
    ("[€]", "a€"),
    ("[α-ω]", "aαβ"),
    ("[😀]", "a😀"),
]


def load_library(name: str) -> ctypes.CDLL:
    candidates = []
    override = os.environ.get("ICU_I18N_LIB" if name == "icui18n" else "ICU_UC_LIB")
    if override:
        candidates.append(override)
    found = ctypes.util.find_library(name)
    if found:
        candidates.append(found)
    for pattern in (
        f"/usr/local/lib/lib{name}.*.dylib",
        f"/opt/homebrew/lib/lib{name}.*.dylib",
        os.path.expanduser(f"~/.pixi/envs/*/lib/lib{name}.*.dylib"),
    ):
        candidates.extend(sorted(glob.glob(pattern)))
    for candidate in candidates:
        try:
            return ctypes.CDLL(candidate)
        except OSError:
            continue
    raise SystemExit(f"could not load {name}")


I18N = load_library("icui18n")
UC = load_library("icuuc")
P = ctypes.c_void_p
S = ctypes.POINTER(ctypes.c_int32)
U16 = ctypes.c_uint16


def bind(version: str):
    def fn(library, name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    return {
        "open": fn(
            UC,
            "ucnvsel_open",
            P,
            [ctypes.POINTER(ctypes.c_char_p), ctypes.c_int32, P, ctypes.c_int32, S],
        ),
        "close": fn(UC, "ucnvsel_close", None, [P]),
        "select": fn(
            UC,
            "ucnvsel_selectForUTF8",
            P,
            [P, ctypes.c_char_p, ctypes.c_int32, S],
        ),
        "set_open_pattern": fn(
            UC,
            "uset_openPattern",
            P,
            [ctypes.POINTER(U16), ctypes.c_int32, S],
        ),
        "set_close": fn(UC, "uset_close", None, [P]),
        "next": fn(UC, "uenum_next", ctypes.c_char_p, [P, ctypes.POINTER(ctypes.c_int32), S]),
        "enum_close": fn(UC, "uenum_close", None, [P]),
    }


FUNCS = {}


def encode_string(text: str) -> bytes:
    encoded = text.encode("utf-8")
    return struct.pack("<H", len(encoded)) + encoded


def make_set(pattern: str):
    encoded = pattern.encode("utf-16-le")
    length = len(encoded) // 2
    data = (U16 * length).from_buffer_copy(encoded)
    status = ctypes.c_int32(0)
    handle = FUNCS["set_open_pattern"](data, length, ctypes.byref(status))
    if status.value > 0:
        raise RuntimeError(f"bad excluded pattern: {pattern}")
    return handle


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    global FUNCS
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(UC, f"ucnvsel_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ucnvsel symbols")
    FUNCS = bind(version)

    converter_array = (ctypes.c_char_p * len(CONVERTERS))(
        *(name.encode() for name in CONVERTERS)
    )

    blobs: list[bytes] = []
    cases = [(None, text) for text in CASES] + EXCLUDED_CASES
    for excluded_pattern, text in cases:
        status = ctypes.c_int32(0)
        excluded = make_set(excluded_pattern) if excluded_pattern else None
        selector = FUNCS["open"](
            converter_array,
            len(CONVERTERS),
            excluded,
            0,
            ctypes.byref(status),
        )
        if not selector:
            raise RuntimeError(f"ucnvsel_open failed: {status.value}")
        try:
            status.value = 0
            enumeration = FUNCS["select"](
                selector,
                text.encode("utf-8"),
                len(text.encode("utf-8")),
                ctypes.byref(status),
            )
            selected = []
            while enumeration:
                length = ctypes.c_int32(0)
                value = FUNCS["next"](enumeration, ctypes.byref(length), ctypes.byref(status))
                if not value:
                    break
                selected.append(value.decode("ascii"))
            if enumeration:
                FUNCS["enum_close"](enumeration)
        finally:
            FUNCS["close"](selector)
            if excluded:
                FUNCS["set_close"](excluded)

        blob = bytearray()
        blob += struct.pack("<H", len(CONVERTERS))
        for name in CONVERTERS:
            blob += encode_string(name)
        pattern_bytes = (excluded_pattern or "").encode("utf-8")
        blob += struct.pack("<H", len(pattern_bytes)) + pattern_bytes
        text_bytes = text.encode("utf-8")
        blob += struct.pack("<H", len(text_bytes)) + text_bytes
        blob += struct.pack("<H", len(selected))
        for name in selected:
            blob += encode_string(name)
        blobs.append(bytes(blob))

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, 0, 0, 0])
    output += struct.pack("<I", len(blobs))
    for blob in blobs:
        output += blob
    with open(sys.argv[1], "wb") as file:
        file.write(output)
    print(f"wrote {len(blobs)} converter-selector cases ({len(output)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
