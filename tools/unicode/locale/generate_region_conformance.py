#!/usr/bin/env python3
"""Generate the ICU region conformance fixture.

Usage:
    generate_region_conformance.py out_file

Records ICU 78 `uregion` results for code and numeric lookups, region types,
numeric codes, containing regions, contained regions, available regions,
preferred values, and containment queries.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

MAGIC = b"CJRC"
FORMAT_VERSION = 1

KIND_LOOKUP = 0
KIND_NUMERIC = 1
KIND_AVAILABLE = 2
KIND_CHILDREN = 3
KIND_CONTAINS = 4
KIND_PREFERRED = 5


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


def bind(version: str) -> dict[str, ctypes._CFuncPtr]:
    def fn(library, name, restype, argtypes):
        func = getattr(library, f"{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    return {
        "from_code": fn(I18N, "uregion_getRegionFromCode", P, [ctypes.c_char_p, S]),
        "from_numeric": fn(I18N, "uregion_getRegionFromNumericCode", P, [ctypes.c_int32, S]),
        "code": fn(I18N, "uregion_getRegionCode", ctypes.c_char_p, [P, S]),
        "numeric": fn(I18N, "uregion_getNumericCode", ctypes.c_int32, [P, S]),
        "type": fn(I18N, "uregion_getType", ctypes.c_int32, [P]),
        "containing": fn(I18N, "uregion_getContainingRegion", P, [P]),
        "children": fn(I18N, "uregion_getContainedRegions", P, [P, S]),
        "preferred": fn(I18N, "uregion_getPreferredValues", P, [P, S]),
        "contains": fn(I18N, "uregion_contains", ctypes.c_int8, [P, P]),
        "available": fn(I18N, "uregion_getAvailable", P, [ctypes.c_int32, S]),
        "next": fn(UC, "uenum_next", ctypes.c_char_p, [P, ctypes.POINTER(ctypes.c_int32), S]),
        "close": fn(UC, "uenum_close", None, [P]),
    }


FUNCS = {}


def enumerate_regions(enumeration) -> list[str]:
    if not enumeration:
        return []
    result = []
    while True:
        length = ctypes.c_int32(0)
        status = ctypes.c_int32(0)
        value = FUNCS["next"](enumeration, ctypes.byref(length), ctypes.byref(status))
        if not value:
            break
        result.append(value.decode("ascii"))
    FUNCS["close"](enumeration)
    return result


def region_code(handle) -> str | None:
    if not handle:
        return None
    status = ctypes.c_int32(0)
    return FUNCS["code"](handle, ctypes.byref(status)).decode("ascii")


def lookup_code(text: str):
    status = ctypes.c_int32(0)
    handle = FUNCS["from_code"](text.encode("ascii"), ctypes.byref(status))
    return handle, status.value


def lookup_numeric(value: int):
    status = ctypes.c_int32(0)
    handle = FUNCS["from_numeric"](value, ctypes.byref(status))
    return handle, status.value


def encode_string(text: str) -> bytes:
    encoded = text.encode("ascii")
    return struct.pack("<H", len(encoded)) + encoded


def encode_region(handle) -> bytes:
    code = region_code(handle)
    if code is None:
        return bytes([0])
    status = ctypes.c_int32(0)
    numeric = FUNCS["numeric"](handle, ctypes.byref(status))
    kind = FUNCS["type"](handle)
    parent = region_code(FUNCS["containing"](handle))
    out = bytearray()
    out += bytes([1])
    out += encode_string(code)
    out += bytes([kind])
    out += struct.pack("<i", numeric)
    out += encode_string(parent or "")
    return bytes(out)


LOOKUP_CODES = [
    "001", "002", "019", "021", "US", "EU", "UN", "QU", "AN", "ZZ", "ZZZ",
    "us", "", "QO", "419", "150", "XK", "AA", "AC", "CP", "DG", "EA", "IC",
    "TA", "EZ", "202", "003", "840", "USA", "ANT", "XKK", "QUU", "BU", "BUR",
    "CS", "SU", "YU", "NT", "CT", "DY", "HV", "JT", "MI", "NH", "NQ", "PZ",
    "RH", "VD", "WK", "UK", "230", "280", "736", "886", "062", "172", "200",
    "532", "582", "830", "890", "968", "972", "977", "985", "986", "SUN",
    "YUG", "XBB", "XCC", "XDD", "AAA", "AND", "ARG",
]

NUMERIC_CODES = [1, 2, 19, 21, 840, 967, 530, 999, 0, -1, 1000, 20, 958, 4]

AVAILABLE_TYPES = list(range(7))

CHILDREN_CODES = [
    "001", "002", "019", "142", "150", "009", "EU", "EZ", "UN", "003", "202",
    "419", "AN", "US", "QO", "039", "015",
]

PREFERRED_CODES = ["AN", "CS", "NT", "SU", "YU", "ANT", "SUN", "QU", "BU", "AAA", "968"]

CONTAINS_PAIRS = [
    ("001", "US"), ("US", "001"), ("US", "US"), ("EU", "AT"), ("EU", "US"),
    ("003", "US"), ("002", "US"), ("019", "US"), ("021", "US"), ("QO", "AC"),
    ("009", "QO"), ("150", "DE"), ("419", "BR"), ("UN", "US"), ("001", "ZZ"),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    global FUNCS
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(I18N, f"uregion_getRegionFromCode_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned uregion symbols")
    FUNCS = bind(version)

    case_blobs: list[bytes] = []

    for code in LOOKUP_CODES:
        handle, status = lookup_code(code)
        case_blobs.append(bytes([KIND_LOOKUP]) + encode_string(code) + encode_region(handle))

    for value in NUMERIC_CODES:
        handle, status = lookup_numeric(value)
        case_blobs.append(bytes([KIND_NUMERIC]) + struct.pack("<i", value) + encode_region(handle))

    for kind in AVAILABLE_TYPES:
        status = ctypes.c_int32(0)
        enumeration = FUNCS["available"](kind, ctypes.byref(status))
        codes = enumerate_regions(enumeration)
        blob = bytearray([KIND_AVAILABLE, kind])
        blob += struct.pack("<H", len(codes))
        for code in codes:
            blob += encode_string(code)
        case_blobs.append(bytes(blob))

    for code in CHILDREN_CODES:
        handle, _ = lookup_code(code)
        codes = enumerate_regions(FUNCS["children"](handle, ctypes.byref(ctypes.c_int32(0)))) if handle else []
        blob = bytearray([KIND_CHILDREN]) + encode_string(code)
        blob += struct.pack("<H", len(codes))
        for child in codes:
            blob += encode_string(child)
        case_blobs.append(bytes(blob))

    for code in PREFERRED_CODES:
        handle, _ = lookup_code(code)
        codes = enumerate_regions(FUNCS["preferred"](handle, ctypes.byref(ctypes.c_int32(0)))) if handle else []
        blob = bytearray([KIND_PREFERRED]) + encode_string(code)
        blob += struct.pack("<H", len(codes))
        for target in codes:
            blob += encode_string(target)
        case_blobs.append(bytes(blob))

    for first, second in CONTAINS_PAIRS:
        first_handle, _ = lookup_code(first)
        second_handle, _ = lookup_code(second)
        result = FUNCS["contains"](first_handle, second_handle) if first_handle and second_handle else 0
        case_blobs.append(bytes([KIND_CONTAINS]) + encode_string(first + "|" + second) + bytes([1 if result else 0]))

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, 0, 0, 0])
    output += struct.pack("<I", len(case_blobs))
    for blob in case_blobs:
        output += blob
    with open(sys.argv[1], "wb") as file:
        file.write(output)
    print(f"wrote region conformance fixture ({len(output)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
