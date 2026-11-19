#!/usr/bin/env python3
"""Generate the localized number parsing conformance fixture with ICU.

Usage:
    generate_parse_conformance.py out_file

For each locale and value the generator formats the number with ICU, then
parses the formatted text with ICU's own parser. The fixture stores the
text plus the value ICU recovered, so the Zig parser is compared against
ICU's parsing semantics rather than against formatting precision. Set
ICU_I18N_LIB when the library is not in a standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

UNUM_DECIMAL = 1
UNUM_PERCENT = 3

LOCALES = (
    "en", "en_GB", "de", "fr", "es", "it", "pt_BR", "ru", "uk", "pl",
    "cs", "sv", "da", "fi", "nb", "nl", "tr", "ar", "fa", "hi",
    "bn", "th", "ja", "ko", "zh", "he", "el", "vi", "id", "ms",
)

VALUES = (
    0.0, 1.0, -1.0, 0.5, -0.5, 1234.5, -9876.543, 0.001, 1000000.25, 42.0,
)


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
    raise SystemExit(
        "could not load libicui18n; set ICU_I18N_LIB to the ICU i18n library"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path = sys.argv[1]

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"unum_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned unum symbols")

    unum_open = getattr(library, f"unum_open_{version}")
    unum_open.restype = ctypes.c_void_p
    unum_open.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    unum_format = getattr(library, f"unum_formatDouble_{version}")
    unum_format.restype = ctypes.c_int32
    unum_format.argtypes = [
        ctypes.c_void_p,
        ctypes.c_double,
        ctypes.c_void_p,
        ctypes.c_int32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    unum_parse = getattr(library, f"unum_parseDouble_{version}")
    unum_parse.restype = ctypes.c_double
    unum_parse.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_int),
    ]
    unum_close = getattr(library, f"unum_close_{version}")
    unum_close.argtypes = [ctypes.c_void_p]

    cases: list[tuple[float, int, str, str]] = []
    for locale in LOCALES:
        for style in (UNUM_DECIMAL, UNUM_PERCENT):
            status = ctypes.c_int(0)
            formatter = unum_open(
                style,
                None,
                0,
                locale.encode("utf-8"),
                None,
                ctypes.byref(status),
            )
            if status.value > 0 or not formatter:
                raise SystemExit(
                    f"unum_open failed for {locale} style {style}: "
                    f"{status.value}"
                )
            for value in VALUES:
                buffer = ctypes.create_string_buffer(256 * 2)
                status.value = 0
                length = unum_format(
                    formatter,
                    value,
                    buffer,
                    len(buffer),
                    None,
                    ctypes.byref(status),
                )
                if length < 0:
                    raise SystemExit(
                        f"unum_format failed for {locale} {value}"
                    )
                text_units = buffer.raw[: length * 2]
                position = ctypes.c_int32(0)
                status.value = 0
                parsed = unum_parse(
                    formatter,
                    ctypes.cast(buffer, ctypes.c_void_p),
                    length,
                    ctypes.byref(position),
                    ctypes.byref(status),
                )
                if status.value > 0:
                    raise SystemExit(
                        f"unum_parse failed for {locale} {value}: "
                        f"{status.value}"
                    )
                text = text_units.decode("utf-16-le")
                cases.append((parsed, style, locale, text))
            unum_close(formatter)

    blob = bytearray(b"CJXN")
    blob += struct.pack("<B3xI", 1, len(cases))
    for value, style, locale, text in cases:
        encoded_locale = locale.encode("utf-8")
        encoded_text = text.encode("utf-8")
        if len(encoded_locale) > 255 or len(encoded_text) > 0xFFFF:
            raise SystemExit("fixture field too long")
        blob += struct.pack(
            "<dBBH",
            value,
            style,
            len(encoded_locale),
            len(encoded_text),
        )
        blob += encoded_locale
        blob += encoded_text
    with open(out_path, "wb") as handle:
        handle.write(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(cases)} parse cases",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
