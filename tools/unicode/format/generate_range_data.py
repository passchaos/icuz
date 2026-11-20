#!/usr/bin/env python3
"""Generate number-range infix and approximately-prefix data with the ICU C API.

Usage:
    generate_range_data.py out_file

CLDR 48 no longer ships number range patterns; ICU 78 supplies the default
"{0}–{1}" plus per-locale infixes and approximately prefixes. This generator
extracts them from ICU so the runtime matches ICU behavior. Set ICU_I18N_LIB
when the ICU library is not in a standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

LOCALES = (
    "af", "ak", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "ccp",
    "chr", "cs", "cy", "da", "de", "de-AT", "de-CH", "ee", "el", "en",
    "en-001", "en-AU", "en-CA", "en-GB", "en-IN", "eo", "es", "es-419",
    "es-MX", "et", "eu", "fa", "fa-AF", "ff", "fi", "fil", "fo", "fr",
    "fr-BE", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky",
    "lb", "lo", "lrc", "lt", "lv", "mk", "ml", "mn", "mr", "ms",
    "mt", "my", "nb", "ne", "nl", "nl-BE", "nn", "no", "pa", "pl", "ps",
    "pt", "pt-PT", "qu", "ro", "ru", "se", "si", "sk", "sl", "sq", "sr",
    "su", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
    "uz", "vec", "vi", "yue", "yue-Hans", "zh", "zh-Hant", "zu",
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
    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(
            library,
            f"unumrf_openForSkeletonWithCollapseAndIdentityFallback_{candidate}",
        ):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned unumrf symbols")

    open_formatter = getattr(
        library,
        f"unumrf_openForSkeletonWithCollapseAndIdentityFallback_{version}",
    )
    open_formatter.restype = ctypes.c_void_p
    open_formatter.argtypes = [
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    open_result = getattr(library, f"unumrf_openResult_{version}")
    open_result.restype = ctypes.c_void_p
    open_result.argtypes = [ctypes.POINTER(ctypes.c_int)]
    format_range = getattr(library, f"unumrf_formatDoubleRange_{version}")
    format_range.argtypes = [
        ctypes.c_void_p,
        ctypes.c_double,
        ctypes.c_double,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
    ]
    result_as_value = getattr(library, f"unumrf_resultAsValue_{version}")
    result_as_value.restype = ctypes.c_void_p
    result_as_value.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    get_string = getattr(library, f"ufmtval_getString_{version}")
    get_string.restype = ctypes.POINTER(ctypes.c_uint16)
    get_string.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
    ]
    close_result = getattr(library, f"unumrf_closeResult_{version}")
    close_result.argtypes = [ctypes.c_void_p]
    close_formatter = getattr(library, f"unumrf_close_{version}")
    close_formatter.argtypes = [ctypes.c_void_p]

    def format_pair(
        skeleton: str,
        locale: str,
        first: float,
        second: float,
        collapse: int = 0,
        identity: int = 1,
    ) -> str:
        encoded = skeleton.encode("utf-16-le")
        status = ctypes.c_int(0)
        formatter = open_formatter(
            encoded,
            len(encoded) // 2,
            collapse,
            identity,
            locale.encode("utf-8"),
            None,
            ctypes.byref(status),
        )
        if not formatter or status.value > 0:
            raise SystemExit(
                f"open failed for {skeleton!r} {locale}: {status.value}"
            )
        result = open_result(ctypes.byref(status))
        format_range(formatter, first, second, result, ctypes.byref(status))
        if status.value > 0:
            raise SystemExit(
                f"format failed for {skeleton!r} {locale}: {status.value}"
            )
        value_status = ctypes.c_int(0)
        value = result_as_value(result, ctypes.byref(value_status))
        length = ctypes.c_int(0)
        string_status = ctypes.c_int(0)
        pointer = get_string(
            value,
            ctypes.byref(length),
            ctypes.byref(string_status),
        )
        if not pointer or length.value <= 0 or string_status.value > 0:
            raise SystemExit(
                f"string failed for {skeleton!r} {locale}: "
                f"{string_status.value}"
            )
        text = "".join(chr(pointer[index]) for index in range(length.value))
        close_result(result)
        close_formatter(formatter)
        return text

    entries = []
    for locale in LOCALES:
        one = format_pair(".00", locale, 1, 1)
        five = format_pair(".00", locale, 5, 5)
        combined = format_pair(".00", locale, 1, 5)
        first_index = combined.find(one)
        second_index = combined.find(five)
        if first_index < 0 or second_index < 0:
            raise SystemExit(f"could not extract range infix for {locale}")
        infix = combined[first_index + len(one) : second_index]

        approximately = format_pair("precision-integer", locale, 1.2, 1.4)
        single = format_pair("precision-integer", locale, 1, 1)
        prefix = ""
        if single in approximately:
            index = approximately.find(single)
            prefix = approximately[:index]
        entries.append((locale, infix, prefix))

    strings = bytearray(b"\x00")
    offsets = {"": 0}

    def intern(value: str) -> int:
        if not value:
            return 0
        if value in offsets:
            return offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        offsets[value] = offset
        return offset

    locale_bytes = bytearray()
    for locale, infix, prefix in entries:
        id_offset = intern(locale)
        locale_bytes += struct.pack(
            "<IB3xII",
            id_offset,
            len(locale.encode("utf-8")),
            intern(infix),
            intern(prefix),
        )
    header = bytearray(b"CJRG")
    header += struct.pack(
        "<B3xHHII",
        1,
        len(entries),
        len(entries),
        len(strings),
        0,
    )
    with open(sys.argv[1], "wb") as handle:
        handle.write(bytes(header + locale_bytes + strings))
    print(f"wrote {len(entries)} locales", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
