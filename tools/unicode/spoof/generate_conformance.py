#!/usr/bin/env python3
"""Generate the UTS #39 skeleton conformance fixture with the ICU C API.

Usage:
    generate_conformance.py confusables.txt out_file

Every confusables source code point plus a set of identifier-like cases is
run through ICU's uspoof_getSkeletonUTF8, and the input/skeleton pairs are
stored in a compact fixture. Set ICU_I18N_LIB when the library is not in a
standard location.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import hashlib
import os
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "091c7f82fc39ef208faf8f94d29c244de99254675e09de163160c810d13ef22a"
U_BUFFER_OVERFLOW_ERROR = 15

CURATED = (
    "paypal",
    "p\u0430ypal",
    "PayPal",
    "\u0440\u0430\u0443\u0440\u0430l",
    "scope",
    "s\u0441ope",
    "\u0430\u0431\u0441",
    "abc",
    "\u0430\u0432\u0441",
    "rnicrosoft",
    "microsoft",
    "l",
    "1",
    "I",
    "\u0131",
    "\u03bf",
    "o",
    "0",
    "O",
    "\u041e",
    "vv",
    "w",
    "cl",
    "d",
    "hello",
    "he11o",
    "\u043dello",
    "test\u2010case",
    "test-case",
    "stra\u00dfe",
    "strasse",
    "caf\u00e9",
    "cafe\u0301",
    "\u00e9",
    "e\u0301",
    "\u212b",
    "\u00c5",
    "A\u030a",
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
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    data = source_path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != INPUT_SHA256:
        raise SystemExit(
            f"{source_path}: expected SHA-256 {INPUT_SHA256}, found {actual}"
        )

    inputs: list[str] = []
    for line in data.decode("utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(";")]
        if len(parts) < 2:
            continue
        inputs.append(chr(int(parts[0], 16)))
    inputs.extend(CURATED)

    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"uspoof_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned uspoof symbols")

    uspoof_open = getattr(library, f"uspoof_open_{version}")
    uspoof_open.restype = ctypes.c_void_p
    uspoof_open.argtypes = [ctypes.POINTER(ctypes.c_int)]
    uspoof_get_skeleton = getattr(
        library, f"uspoof_getSkeletonUTF8_{version}"
    )
    uspoof_get_skeleton.restype = ctypes.c_int32
    uspoof_get_skeleton.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_int),
    ]
    uspoof_close = getattr(library, f"uspoof_close_{version}")
    uspoof_close.argtypes = [ctypes.c_void_p]

    status = ctypes.c_int(0)
    checker = uspoof_open(ctypes.byref(status))
    if status.value != 0 or not checker:
        raise SystemExit(f"uspoof_open failed with status {status.value}")

    cases: list[tuple[bytes, bytes]] = []
    for text in inputs:
        encoded = text.encode("utf-8")
        status.value = 0
        needed = uspoof_get_skeleton(
            checker,
            0,
            encoded,
            len(encoded),
            None,
            0,
            ctypes.byref(status),
        )
        if needed < 0:
            raise SystemExit(f"uspoof_getSkeletonUTF8 failed for {text!r}")
        buffer = ctypes.create_string_buffer(needed + 1)
        status.value = 0
        written = uspoof_get_skeleton(
            checker,
            0,
            encoded,
            len(encoded),
            buffer,
            needed + 1,
            ctypes.byref(status),
        )
        if written < 0:
            raise SystemExit(f"uspoof_getSkeletonUTF8 failed for {text!r}")
        cases.append((encoded, buffer.raw[:written]))

    uspoof_close(checker)

    blob = bytearray(b"CJXS")
    blob += struct.pack("<B3xI", 1, len(cases))
    for encoded, skeleton in cases:
        blob += struct.pack("<HH", len(encoded), len(skeleton))
        blob += encoded
        blob += skeleton
    out_path.write_bytes(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(cases)} skeleton cases",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
