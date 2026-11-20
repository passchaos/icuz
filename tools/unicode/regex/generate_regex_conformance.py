#!/usr/bin/env python3
"""Generate the ICU regular-expression conformance fixture.

Usage:
    generate_regex_conformance.py out_file

The fixture records ICU 78 `uregex` results (compile status, match and
capture spans in UTF-16 code units, replace output, and split fields) for a
matrix of patterns, flags, regions, and inputs. It uses the ICU C API through
ctypes; set ICU_I18N_LIB when the library is not discoverable.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import os
import struct
import sys

MAGIC = b"CJRX"
FORMAT_VERSION = 1

FLAG_CASE_INSENSITIVE = 1
FLAG_COMMENTS = 2
FLAG_DOTALL = 4
FLAG_LITERAL = 8
FLAG_MULTILINE = 16
FLAG_UNIX_LINES = 32
FLAG_UWORD = 64
FLAG_ERROR_ON_UNKNOWN_ESCAPES = 128

ICU_FLAGS = {
    FLAG_CASE_INSENSITIVE: 2,
    FLAG_COMMENTS: 4,
    FLAG_DOTALL: 32,
    FLAG_LITERAL: 16,
    FLAG_MULTILINE: 8,
    FLAG_UNIX_LINES: 1,
    FLAG_UWORD: 256,
    FLAG_ERROR_ON_UNKNOWN_ESCAPES: 512,
}

KIND_MATCHES = 0
KIND_FIND = 1
KIND_LOOKING_AT = 2
KIND_REPLACE_ALL = 3
KIND_SPLIT = 4
KIND_REPLACE_FIRST = 5
KIND_FIND_ALL = 6

U16 = ctypes.c_uint16
P16 = ctypes.POINTER(U16)
P32 = ctypes.POINTER(ctypes.c_int32)


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


def utf16(text: str) -> tuple[ctypes.Array, int]:
    encoded = text.encode("utf-16-le")
    length = len(encoded) // 2
    return (U16 * length).from_buffer_copy(encoded), length


def bind(library: ctypes.CDLL, version: str) -> dict[str, ctypes._CFuncPtr]:
    def fn(name: str, restype, argtypes):
        func = getattr(library, f"uregex_{name}_{version}")
        func.restype = restype
        func.argtypes = argtypes
        return func

    return {
        "open": fn("open", ctypes.c_void_p, [P16, ctypes.c_int32, ctypes.c_uint32, ctypes.c_void_p, P32]),
        "close": fn("close", None, [ctypes.c_void_p]),
        "set_text": fn("setText", None, [ctypes.c_void_p, P16, ctypes.c_int32, P32]),
        "reset": fn("reset", None, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "matches": fn("matches", ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "looking_at": fn("lookingAt", ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "find_next": fn("findNext", ctypes.c_int32, [ctypes.c_void_p, P32]),
        "start": fn("start", ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "end": fn("end", ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "group_count": fn("groupCount", ctypes.c_int32, [ctypes.c_void_p, P32]),
        "set_region": fn("setRegion", None, [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, P32]),
        "transparent": fn("useTransparentBounds", None, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "anchoring": fn("useAnchoringBounds", None, [ctypes.c_void_p, ctypes.c_int32, P32]),
        "replace_all": fn("replaceAll", ctypes.c_int32, [ctypes.c_void_p, P16, ctypes.c_int32, P16, ctypes.c_int32, P32]),
        "replace_first": fn("replaceFirst", ctypes.c_int32, [ctypes.c_void_p, P16, ctypes.c_int32, P16, ctypes.c_int32, P32]),
        "split": fn(
            "split",
            ctypes.c_int32,
            [ctypes.c_void_p, P16, ctypes.c_int32, P32, ctypes.POINTER(P16), ctypes.c_int32, P32],
        ),
    }


class IcuRegex:
    def __init__(self, funcs, pattern: str, flags: int):
        self.funcs = funcs
        self.status = ctypes.c_int32(0)
        data, length = utf16(pattern)
        self.pattern_data = data
        self.handle = funcs["open"](data, length, flags, None, ctypes.byref(self.status))
        self.compile_ok = self.status.value <= 0
        self.text_units = 0
        self.text_data = None
        self.region = None
        self.bounds = (False, True)

    def close(self):
        if self.handle:
            self.funcs["close"](self.handle)
            self.handle = None

    def set_text(self, text: str):
        data, length = utf16(text)
        # uregex_setText keeps a pointer into the caller's buffer.
        self.text_data = data
        self.text_units = length
        self.funcs["set_text"](self.handle, data, length, ctypes.byref(self.status))

    def set_region(self, start: int, end: int):
        self.region = (start, end)
        self.funcs["set_region"](self.handle, start, end, ctypes.byref(self.status))

    def set_bounds(self, transparent: bool, anchoring: bool):
        self.bounds = (transparent, anchoring)
        self.funcs["transparent"](self.handle, 1 if transparent else 0, ctypes.byref(self.status))
        self.funcs["anchoring"](self.handle, 1 if anchoring else 0, ctypes.byref(self.status))

    def apply_region(self):
        if self.region is not None:
            self.funcs["set_region"](self.handle, self.region[0], self.region[1], ctypes.byref(self.status))
        transparent, anchoring = self.bounds
        self.funcs["transparent"](self.handle, 1 if transparent else 0, ctypes.byref(self.status))
        self.funcs["anchoring"](self.handle, 1 if anchoring else 0, ctypes.byref(self.status))

    def group_spans(self) -> list[tuple[int, int]]:
        count = self.funcs["group_count"](self.handle, ctypes.byref(self.status))
        spans = []
        for group in range(count + 1):
            start = self.funcs["start"](self.handle, group, ctypes.byref(self.status))
            end = self.funcs["end"](self.handle, group, ctypes.byref(self.status))
            if start < 0 or end < 0:
                spans.append((-1, -1))
            else:
                spans.append((start, end))
        return spans

    def match(self, kind: int) -> tuple[bool, list[tuple[int, int]] | list[list[tuple[int, int]]]]:
        self.status.value = 0
        if kind == KIND_MATCHES:
            ok = self.funcs["matches"](self.handle, -1, ctypes.byref(self.status))
            return bool(ok), self.group_spans() if ok else []
        if kind == KIND_LOOKING_AT:
            ok = self.funcs["looking_at"](self.handle, -1, ctypes.byref(self.status))
            return bool(ok), self.group_spans() if ok else []
        if kind == KIND_FIND:
            self.funcs["reset"](self.handle, 0, ctypes.byref(self.status))
            self.apply_region()
            ok = self.funcs["find_next"](self.handle, ctypes.byref(self.status))
            return bool(ok), self.group_spans() if ok else []
        if kind == KIND_FIND_ALL:
            self.funcs["reset"](self.handle, 0, ctypes.byref(self.status))
            self.apply_region()
            matches = []
            for _ in range(64):
                if not self.funcs["find_next"](self.handle, ctypes.byref(self.status)):
                    break
                matches.append(self.group_spans())
            return bool(matches), matches
        raise AssertionError(kind)

    def replace(self, replacement: str, first: bool) -> str:
        data, length = utf16(replacement)
        capacity = max(256, (self.text_units + length + 1) * 4)
        while True:
            buffer = (U16 * capacity)()
            self.status.value = 0
            func = self.funcs["replace_first"] if first else self.funcs["replace_all"]
            result_len = func(self.handle, data, length, buffer, capacity, ctypes.byref(self.status))
            if self.status.value == 15:  # U_BUFFER_OVERFLOW_ERROR
                capacity *= 2
                continue
            if self.status.value > 0:
                raise RuntimeError(f"replace failed: {self.status.value}")
            raw = struct.pack(f"<{result_len}H", *buffer[:result_len])
            return raw.decode("utf-16-le")

    def split(self) -> list[str]:
        capacity = max(256, (self.text_units + 1) * 4)
        fields_capacity = 64
        buffer = (U16 * capacity)()
        pointers = (P16 * fields_capacity)()
        required = ctypes.c_int32(0)
        self.status.value = 0
        count = self.funcs["split"](
            self.handle,
            buffer,
            capacity,
            ctypes.byref(required),
            pointers,
            fields_capacity,
            ctypes.byref(self.status),
        )
        if self.status.value > 0:
            raise RuntimeError(f"split failed: {self.status.value}")
        fields = []
        for index in range(count):
            pointer = pointers[index]
            units = []
            cursor = 0
            while pointer[cursor] != 0:
                units.append(pointer[cursor])
                cursor += 1
            fields.append(struct.pack(f"<{len(units)}H", *units).decode("utf-16-le"))
        return fields


CASES = [
    # kind, flags, pattern, text, replacement, region_start, region_end, transparent, anchoring
    (KIND_MATCHES, 0, "abc", "abc", "", None, None, False, True),
    (KIND_MATCHES, 0, "a|b", "b", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?:ab)+", "ababab", "", None, None, False, True),
    (KIND_MATCHES, 0, "a{2,3}", "aaa", "", None, None, False, True),
    (KIND_MATCHES, 0, "a{2,3}", "aaaa", "", None, None, False, True),
    (KIND_FIND, 0, "b+", "aabbbcc", "", None, None, False, True),
    (KIND_FIND, 0, "a*?a", "aaa", "", None, None, False, True),
    (KIND_MATCHES, 0, "a*+a", "aaa", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?>a*)a", "aaa", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?<word>[a-z]+)-(\\d+)", "abc-123", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "abc", "ABC", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "ß", "ss", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "ss", "ß", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "s", "ß", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "[ß]", "ss", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "[a-z]+", "\u212a", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "[^a]", "A", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "\\P{L}", "1", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "\\P{L}", "A", "", None, None, False, True),
    (KIND_MATCHES, FLAG_CASE_INSENSITIVE, "(a)\\1", "aA", "", None, None, False, True),
    (KIND_FIND, 0, "(?<=ab)c", "abc", "", None, None, False, True),
    (KIND_FIND, 0, "(?<=a|bc)d", "bcd", "", None, None, False, True),
    (KIND_FIND, 0, "(?=(a))a", "a", "", None, None, False, True),
    (KIND_FIND, 0, "a(?!b)", "ac", "", None, None, False, True),
    (KIND_MATCHES, 0, "(a)\\1", "aa", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?<x>a)\\k<x>", "aa", "", None, None, False, True),
    (KIND_FIND, 0, "\\G\\w", "ab cd", "", None, None, False, True),
    (KIND_FIND, 0, "abc$", "abc\n", "", None, None, False, True),
    (KIND_FIND, 0, "abc$", "abc\r\n", "", None, None, False, True),
    (KIND_FIND, 0, "abc\\Z", "abc\n", "", None, None, False, True),
    (KIND_FIND, 0, "abc\\z", "abc\n", "", None, None, False, True),
    (KIND_FIND, FLAG_MULTILINE, "^b", "a\nb", "", None, None, False, True),
    (KIND_FIND, FLAG_MULTILINE, "^b", "a\r\nb", "", None, None, False, True),
    (KIND_FIND, FLAG_MULTILINE, "a$", "a\r\nb", "", None, None, False, True),
    (KIND_FIND, FLAG_UNIX_LINES, "a$", "a\n", "", None, None, False, True),
    (KIND_FIND, FLAG_UNIX_LINES, "a$", "a\r", "", None, None, False, True),
    (KIND_MATCHES, FLAG_UNIX_LINES, ".", "\r", "", None, None, False, True),
    (KIND_MATCHES, 0, ".", "\u2028", "", None, None, False, True),
    (KIND_MATCHES, FLAG_DOTALL, ".", "\u2028", "", None, None, False, True),
    (KIND_FIND, 0, "\\bé", "x é", "", None, None, False, True),
    (KIND_FIND, 0, "\\bé", "aé", "", None, None, False, True),
    (KIND_FIND, FLAG_UWORD, "\\bé", "x é", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\w", "é", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\d", "\u0660", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\s", "\u2028", "", None, None, False, True),
    (KIND_MATCHES, 0, "[a-z&&[^aeiou]]+", "bcdf", "", None, None, False, True),
    (KIND_MATCHES, 0, "[a-z--[aeiou]]+", "bcdf", "", None, None, False, True),
    (KIND_MATCHES, 0, "[[:alpha:]]+", "abc", "", None, None, False, True),
    (KIND_MATCHES, 0, "[[:digit:]]", "\u0660", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\p{Script=Greek}+", "αβγ", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\p{Block=Basic_Latin}", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\p{Age=6.0}", "€", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\p{Word_Break=ALetter}", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\N{LATIN SMALL LETTER A}", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\0101", "A", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\x{1F600}", "\U0001f600", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\u0041", "A", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\cA", "\x01", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\Qa+b\\E", "a+b", "", None, None, False, True),
    (KIND_MATCHES, FLAG_COMMENTS, " a b # comment\n c", "abc", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\X", "e\u0301", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\R", "\r\n", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\R", "\u0085", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\R", "\u000b", "", None, None, False, True),
    (KIND_MATCHES, 0, "(a*)*", "aa", "", None, None, False, True),
    (KIND_MATCHES, 0, "(a?)+", "", "", None, None, False, True),
    (KIND_MATCHES, 0, "(a|)+", "a", "", None, None, False, True),
    (KIND_FIND_ALL, 0, "a*", "ba", "", None, None, False, True),
    (KIND_FIND_ALL, 0, "a*", "aaa", "", None, None, False, True),
    (KIND_FIND_ALL, 0, "\\w+", "one two three", "", None, None, False, True),
    (KIND_FIND, 0, "\\babc\\b", "xabcx", "", 1, 4, False, True),
    (KIND_MATCHES, 0, "\\babc\\b", "xabcx", "", 1, 4, False, True),
    (KIND_FIND, 0, "^abc$", "xabcx", "", 1, 4, False, True),
    (KIND_FIND, 0, "^abc$", "xabcx", "", 1, 4, False, False),
    (KIND_FIND, 0, "(?<=x)abc", "xabcx", "", 1, 4, False, True),
    (KIND_FIND, 0, "(?<=x)abc", "xabcx", "", 1, 4, True, True),
    (KIND_REPLACE_ALL, 0, "(\\w+)@(\\w+)", "a@b c@d", "$2:$1", None, None, False, True),
    (KIND_REPLACE_ALL, 0, "(?<user>\\w+)@(?<host>\\w+)", "a@b c@d", "${host}-${user}", None, None, False, True),
    (KIND_REPLACE_FIRST, 0, "(\\w+)@(\\w+)", "a@b c@d", "$2-$1", None, None, False, True),
    (KIND_SPLIT, 0, ",", "a,b,c", "", None, None, False, True),
    (KIND_SPLIT, 0, ",", "a,,b", "", None, None, False, True),
    (KIND_SPLIT, 0, ",", "a,b,", "", None, None, False, True),
    (KIND_SPLIT, 0, "(b)", "ab", "", None, None, False, True),
    (KIND_SPLIT, 0, "\\d", "a1b2c", "", None, None, False, True),
    (KIND_MATCHES, FLAG_LITERAL, "a+b", "a+b", "", None, None, False, True),
    (KIND_MATCHES, FLAG_LITERAL, "a+b", "aab", "", None, None, False, True),
    (KIND_MATCHES, FLAG_LITERAL | FLAG_CASE_INSENSITIVE, "a+b", "A+B", "", None, None, False, True),
    # Compile failures.
    (KIND_MATCHES, 0, "", "", "", None, None, False, True),
    (KIND_MATCHES, 0, "*a", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "a**", "aa", "", None, None, False, True),
    (KIND_MATCHES, 0, "(a)\\2", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?<1x>a)", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?<x>a)(?<x>b)", "ab", "", None, None, False, True),
    (KIND_MATCHES, 0, "[a-", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "\\p{Bogus}", "a", "", None, None, False, True),
    (KIND_MATCHES, 0, "(?<=a*)b", "b", "", None, None, False, True),
    (KIND_MATCHES, 0, "a{b}", "a", "", None, None, False, True),
]


def encode_case(case) -> bytes:
    kind, flags, pattern, text, replacement, region_start, region_end, transparent, anchoring = case
    icu_flags = 0
    for bit, value in ICU_FLAGS.items():
        if flags & bit:
            icu_flags |= value

    compiled = IcuRegex(FUNCS, pattern, icu_flags)
    try:
        out = bytearray()
        out += struct.pack(
            "<BBBBHH",
            flags,
            kind,
            int(transparent),
            int(anchoring),
            0xFFFF if region_start is None else region_start,
            0xFFFF if region_end is None else region_end,
        )
        pattern_bytes = pattern.encode("utf-8")
        text_bytes = text.encode("utf-8")
        replacement_bytes = replacement.encode("utf-8")
        out += struct.pack("<H", len(pattern_bytes)) + pattern_bytes
        out += struct.pack("<H", len(text_bytes)) + text_bytes
        out += struct.pack("<H", len(replacement_bytes)) + replacement_bytes
        out += bytes([1 if compiled.compile_ok else 0])
        if not compiled.compile_ok:
            return bytes(out)

        compiled.set_text(text)
        if region_start is not None:
            compiled.set_region(region_start, region_end)
        compiled.set_bounds(transparent, anchoring)

        if kind in (KIND_MATCHES, KIND_FIND, KIND_LOOKING_AT, KIND_FIND_ALL):
            matched, payload = compiled.match(kind)
            out += bytes([1 if matched else 0])
            if kind == KIND_FIND_ALL:
                spans_list = payload
                out += struct.pack("<H", len(spans_list))
                for spans in spans_list:
                    out += struct.pack("<H", len(spans) - 1)
                    for start, end in spans:
                        out += struct.pack("<ii", start, end)
            elif matched:
                spans = payload
                out += struct.pack("<H", len(spans) - 1)
                for start, end in spans:
                    out += struct.pack("<ii", start, end)
        elif kind == KIND_REPLACE_ALL:
            output = compiled.replace(replacement, first=False)
            encoded = output.encode("utf-8")
            out += struct.pack("<I", len(encoded)) + encoded
        elif kind == KIND_REPLACE_FIRST:
            output = compiled.replace(replacement, first=True)
            encoded = output.encode("utf-8")
            out += struct.pack("<I", len(encoded)) + encoded
        elif kind == KIND_SPLIT:
            fields = compiled.split()
            out += struct.pack("<H", len(fields))
            for field in fields:
                encoded = field.encode("utf-8")
                out += struct.pack("<H", len(encoded)) + encoded
        else:
            raise AssertionError(kind)
        return bytes(out)
    finally:
        compiled.close()


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    global FUNCS
    library = load_library()
    version = None
    for candidate in ("72", "73", "74", "75", "76", "77", "78", "79", "80"):
        if hasattr(library, f"uregex_open_{candidate}"):
            version = candidate
            break
    if version is None:
        raise SystemExit("could not find versioned uregex symbols")
    FUNCS = bind(library, version)

    body = bytearray()
    for case in CASES:
        body += encode_case(case)

    output = bytearray(MAGIC)
    output += bytes([FORMAT_VERSION, 0, 0, 0])
    output += struct.pack("<I", len(CASES))
    output += body
    with open(sys.argv[1], "wb") as file:
        file.write(output)
    print(f"wrote {len(CASES)} regex conformance cases")
    return 0


FUNCS = {}


if __name__ == "__main__":
    sys.exit(main())
