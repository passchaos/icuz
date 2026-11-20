#!/usr/bin/env python3
"""Generate the ICU locale-data (ulocdata) conformance fixture.

Usage:
    generate_locale_data_conformance.py out_file
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

MAGIC = b"CJL3"
FORMAT_VERSION = 1

KIND_EXEMPLAR = 0
KIND_DELIMITER = 1
KIND_DISPLAY_PATTERN = 2
KIND_SEPARATOR = 3
KIND_MEASUREMENT = 4
KIND_PAPER = 5

LOCALES = [
    "en", "en-US", "en-GB", "fr-FR", "de", "ar", "he", "ja", "zh-Hant",
    "zh-Hans", "ru", "hi", "th", "ko", "es", "pt-BR", "es-MX", "tr", "pl",
    "cs", "sv", "fi", "da", "nl", "it", "el", "uk", "bg", "sr-Latn", "bn",
    "ta", "te", "ml", "my", "km", "lo", "fa", "ur", "sw", "am", "ha", "yo",
    "zu", "af", "id", "ms", "vi", "fil", "ca", "ro", "hu", "sk", "sl", "hr",
    "et", "lv", "lt", "is", "ga", "mt", "sq", "mk", "bs", "be", "kk", "ky",
    "uz", "az", "hy", "ka", "mn", "ne", "si", "pa", "gu", "or", "zz-ZZ", "xx",
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
        "open": fn(I18N, "ulocdata_open", P, [ctypes.c_char_p, S]),
        "close": fn(I18N, "ulocdata_close", None, [P]),
        "exemplar": fn(
            I18N,
            "ulocdata_getExemplarSet",
            P,
            [P, P, ctypes.c_uint32, ctypes.c_int32, S],
        ),
        "delimiter": fn(
            I18N,
            "ulocdata_getDelimiter",
            ctypes.c_int32,
            [P, ctypes.c_int32, ctypes.POINTER(U16), ctypes.c_int32, S],
        ),
        "display": fn(
            I18N,
            "ulocdata_getLocaleDisplayPattern",
            ctypes.c_int32,
            [P, ctypes.POINTER(U16), ctypes.c_int32, ctypes.POINTER(U16), ctypes.c_int32, S],
        ),
        "separator": fn(
            I18N,
            "ulocdata_getLocaleSeparator",
            ctypes.c_int32,
            [P, ctypes.POINTER(U16), ctypes.c_int32, S],
        ),
        "measurement": fn(
            I18N,
            "ulocdata_getMeasurementSystem",
            ctypes.c_int32,
            [ctypes.c_char_p, S],
        ),
        "paper": fn(
            I18N,
            "ulocdata_getPaperSize",
            None,
            [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32), S],
        ),
        "set_open": fn(UC, "uset_open", P, [P, S]),
        "set_close": fn(UC, "uset_close", None, [P]),
        "set_count": fn(UC, "uset_getItemCount", ctypes.c_int32, [P, S]),
        "set_item": fn(
            UC,
            "uset_getItem",
            ctypes.c_int32,
            [
                P,
                ctypes.c_int32,
                ctypes.POINTER(ctypes.c_int32),
                ctypes.POINTER(ctypes.c_int32),
                ctypes.POINTER(U16),
                ctypes.c_int32,
                S,
            ],
        ),
    }


FUNCS = {}


def encode_string(text: str) -> bytes:
    encoded = text.encode("utf-8")
    return struct.pack("<H", len(encoded)) + encoded


def utf16_text(buffer, length: int) -> str:
    return struct.pack(f"<{length}H", *buffer[:length]).decode("utf-16-le")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    global FUNCS
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(I18N, f"ulocdata_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned ulocdata symbols")
    FUNCS = bind(version)

    blobs: list[bytes] = []

    for locale in LOCALES:
        status = ctypes.c_int32(0)
        handle = FUNCS["open"](locale.encode(), ctypes.byref(status))
        if not handle:
            continue
        try:
            for kind in range(4):
                status.value = 0
                uset = FUNCS["set_open"](None, ctypes.byref(status))
                FUNCS["exemplar"](handle, uset, 0, kind, ctypes.byref(status))
                count = FUNCS["set_count"](uset, ctypes.byref(status))
                blob = bytearray([KIND_EXEMPLAR]) + encode_string(locale) + bytes([kind])
                blob += struct.pack("<I", count)
                for index in range(count):
                    start = ctypes.c_int32(0)
                    end = ctypes.c_int32(0)
                    buffer = (U16 * 64)()
                    length = FUNCS["set_item"](
                        uset,
                        index,
                        ctypes.byref(start),
                        ctypes.byref(end),
                        buffer,
                        64,
                        ctypes.byref(status),
                    )
                    if length > 0:
                        text = utf16_text(buffer, length)
                        blob += bytes([1]) + encode_string(text)
                    else:
                        blob += bytes([0]) + struct.pack("<ii", start.value, end.value)
                FUNCS["set_close"](uset)
                blobs.append(bytes(blob))

            for kind in range(4):
                buffer = (U16 * 128)()
                status.value = 0
                length = FUNCS["delimiter"](
                    handle, kind, buffer, 128, ctypes.byref(status)
                )
                text = utf16_text(buffer, length)
                blobs.append(
                    bytes([KIND_DELIMITER]) + encode_string(locale) + bytes([kind]) + encode_string(text)
                )

            pattern_buffer = (U16 * 128)()
            separator_buffer = (U16 * 128)()
            status.value = 0
            length = FUNCS["display"](
                handle,
                pattern_buffer,
                128,
                separator_buffer,
                128,
                ctypes.byref(status),
            )
            blobs.append(
                bytes([KIND_DISPLAY_PATTERN])
                + encode_string(locale)
                + encode_string(utf16_text(pattern_buffer, length))
            )

            status.value = 0
            length = FUNCS["separator"](handle, separator_buffer, 128, ctypes.byref(status))
            blobs.append(
                bytes([KIND_SEPARATOR])
                + encode_string(locale)
                + encode_string(utf16_text(separator_buffer, length))
            )
        finally:
            FUNCS["close"](handle)

        status.value = 0
        system = FUNCS["measurement"](locale.encode(), ctypes.byref(status))
        blobs.append(bytes([KIND_MEASUREMENT]) + encode_string(locale) + bytes([system]))

        height = ctypes.c_int32(0)
        width = ctypes.c_int32(0)
        status.value = 0
        FUNCS["paper"](
            locale.encode(), ctypes.byref(height), ctypes.byref(width), ctypes.byref(status)
        )
        blobs.append(
            bytes([KIND_PAPER])
            + encode_string(locale)
            + struct.pack("<ii", height.value, width.value)
        )

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, 0, 0, 0])
    output += struct.pack("<I", len(blobs))
    for blob in blobs:
        output += blob
    with open(sys.argv[1], "wb") as file:
        file.write(output)
    print(f"wrote {len(blobs)} locale-data cases ({len(output)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
