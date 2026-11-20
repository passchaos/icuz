#!/usr/bin/env python3
"""Generate the ICU locale metadata conformance fixture.

Usage:
    generate_metadata_conformance.py out_file
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

MAGIC = b"CJL4"
FORMAT_VERSION = 1

LOCALES = [
    "en", "en-US", "en-GB", "en-001", "es", "es-MX", "es-419", "fr", "fr-CA",
    "de", "it", "pt", "pt-BR", "ru", "uk", "pl", "cs", "sk", "hu", "ro",
    "bg", "sr", "sr-Latn", "hr", "sl", "mk", "el", "tr", "az", "he", "ar",
    "ar-EG", "fa", "ur", "pa-PK", "sd", "yi", "ug", "ckb", "hi", "bn", "ta",
    "te", "ml", "gu", "kn", "th", "lo", "km", "my", "vi", "id", "ms", "zh",
    "zh-Hans", "zh-Hant", "zh-TW", "ja", "ko", "mn", "ka", "hy", "am", "sw",
    "zu", "af", "nl", "sv", "da", "fi", "no", "is", "ga", "mt", "sq", "bs",
    "be", "kk", "ky", "uz", "ne", "si", "und", "root", "zz", "zz-ZZ",
]


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
    raise SystemExit("could not load libicui18n")


def encode_string(text: str) -> bytes:
    encoded = text.encode("utf-8")
    return struct.pack("<H", len(encoded)) + encoded


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"uloc_getCharacterOrientation_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned uloc symbols")

    def fn(name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    character = fn(
        "uloc_getCharacterOrientation", ctypes.c_int32, [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32)]
    )
    line = fn(
        "uloc_getLineOrientation", ctypes.c_int32, [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32)]
    )
    iso3_language = fn("uloc_getISO3Language", ctypes.c_char_p, [ctypes.c_char_p])
    iso3_country = fn("uloc_getISO3Country", ctypes.c_char_p, [ctypes.c_char_p])

    blobs: list[bytes] = []
    for locale in LOCALES:
        status = ctypes.c_int32(0)
        char = character(locale.encode(), ctypes.byref(status))
        status.value = 0
        line_value = line(locale.encode(), ctypes.byref(status))
        language = iso3_language(locale.encode()).decode("ascii")
        country = iso3_country(locale.encode()).decode("ascii")
        blob = bytearray()
        blob += encode_string(locale)
        blob += bytes([char & 0xFF, line_value & 0xFF])
        blob += encode_string(language)
        blob += encode_string(country)
        blobs.append(bytes(blob))

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, 0, 0, 0])
    output += struct.pack("<I", len(blobs))
    for blob in blobs:
        output += blob
    with open(sys.argv[1], "wb") as file:
        file.write(output)
    print(f"wrote {len(blobs)} locale metadata cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
