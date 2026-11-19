#!/usr/bin/env python3
"""Generate CLDR 48 locale collation tailorings.

Usage:
    generate_tailorings.py cldr-common-48.zip allkeys_CLDR.txt allkeys.txt out_dir

The compiler reads the CLDR `standard` collation rules, resolves imports, and
assigns tailored weights in the eight low bits reserved by the root collation
data. Locales whose rules use unsupported constructs are skipped with a warning
instead of producing incorrect data.
"""

from __future__ import annotations

import bisect
import hashlib
import re
import struct
import sys
import unicodedata
import zipfile
from pathlib import Path

from generate_data import (
    INPUT_SHA256 as ALLKEYS_SHA256,
    UCA_INPUT_SHA256,
    checked_text,
    parse_entries,
    parse_implicit,
)

CLDR_SHA256 = "06c7c698d6fd8d67cefac15a0206b0109b00e0ef1636f86f84449fa959561f74"
CLDR_VERSION = 48
WEIGHT_SCALE = 12
IMPLICIT_START = 0xFB40 << WEIGHT_SCALE
MAX_SEQUENCE = 8
COMMON_SECONDARY = 0x0020 << WEIGHT_SCALE
COMMON_TERTIARY = 0x0002 << WEIGHT_SCALE

# Tertiary lead values that carry the UCA uppercase case bits.
UPPER_TERTIARIES = frozenset((0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0E, 0x11, 0x12, 0x1D))


def sequence_case(sequence: tuple[int, ...]) -> str:
    text = "".join(chr(codepoint) for codepoint in sequence)
    if text.isupper():
        return "upper"
    if text.islower():
        return "lower"
    if any(character.isupper() for character in text) and any(
        character.islower() for character in text
    ):
        return "mixed"
    return "uncased"


def set_tertiary_case(tertiary: int, case: str) -> int:
    """Give a tailored tertiary weight the case bits of its source string."""
    value = tertiary >> WEIGHT_SCALE
    if case == "upper":
        if value in UPPER_TERTIARIES:
            return tertiary
        variant = value - 2 if value >= 2 else 0
        return (0x08 + variant) << WEIGHT_SCALE
    if case == "lower":
        if value in UPPER_TERTIARIES:
            return (0x02 + (value - 0x08)) << WEIGHT_SCALE
        return tertiary
    return tertiary

CE_RE = re.compile(
    r"\[([.*])([0-9A-Fa-f]{4})\.([0-9A-Fa-f]{4})\.([0-9A-Fa-f]{4})\]"
)

HANI_START = 0xFB40000
OTHERS_START = 0xFBC0000
RESERVED_START = 0xFFFD000
CONTINUATION_START = 0x8000000
OVERFLOW_START = 0x10000000

SPECIAL_REORDER_TOKENS = {
    "SPACE": "space",
    "PUNCTUATION": "punct",
    "SYMBOL": "symbol",
    "CURRENCY": "currency",
    "DIGIT": "digit",
    "unassigned": "others",
}


class ReorderGroup:
    __slots__ = ("token", "start", "end")

    def __init__(self, token: str, start: int, end: int = 0):
        self.token = token
        self.start = start
        self.end = end


class ReorderPlan:
    __slots__ = (
        "new_base",
        "pre_base",
        "pre_rank",
        "overflow_base",
        "overflow_rank",
        "cont_base",
        "primary_map",
    )

    def __init__(self, new_base, pre_base, pre_rank, overflow_base,
                 overflow_rank, cont_base, primary_map):
        self.new_base = new_base
        self.pre_base = pre_base
        self.pre_rank = pre_rank
        self.overflow_base = overflow_base
        self.overflow_rank = overflow_rank
        self.cont_base = cont_base
        self.primary_map = primary_map


def parse_reorder_groups(archive: zipfile.ZipFile) -> list[ReorderGroup]:
    """Derive CLDR reordering groups from FractionalUCA.txt.

    Each group marker is followed by the first real mapping of that group; its
    allkeys collation element (in the comment) gives the group's start in the
    same primary space as our root data.
    """
    text = archive.read("common/uca/FractionalUCA.txt").decode("utf-8")
    groups: list[ReorderGroup] = []
    seen: set[str] = set()
    pending: str | None = None
    for line in text.splitlines():
        if " first primary" in line and "#" in line:
            pending = line.split("#", 1)[1].split(" first primary")[0].strip()
            continue
        if pending is None:
            continue
        if not re.match(r"^[0-9A-Fa-f]{4,6};", line):
            continue
        comment = line.split("#", 1)[1] if "#" in line else ""
        match = re.search(r"\[([0-9A-Fa-f]{4})\.", comment)
        if match is None:
            continue
        if pending.startswith("REORDER_RESERVED"):
            pending = None
            continue
        token = SPECIAL_REORDER_TOKENS.get(pending)
        if token is None:
            token = comment.strip().split()[0]
        start = (
            OTHERS_START
            if pending == "unassigned"
            else int(match.group(1), 16) << WEIGHT_SCALE
        )
        pending = None
        if token in seen:
            continue
        seen.add(token)
        groups.append(ReorderGroup(token, start))
    if "others" not in seen:
        groups.append(ReorderGroup("others", OTHERS_START))
    groups.sort(key=lambda group: group.start)
    for index, group in enumerate(groups):
        group.end = (
            groups[index + 1].start
            if index + 1 < len(groups)
            else RESERVED_START
        )
    return groups


def build_reorder_plan(state) -> ReorderPlan | None:
    tokens: list[str] = []
    for directive in state.reorders:
        tokens.extend(directive.split()[1:])
    token_to_index = {
        group.token: index for index, group in enumerate(state.groups)
    }
    listed: list[int | None] = []
    others_position: int | None = None
    seen: set[int] = set()
    for token in tokens:
        if token in ("others", "Zzzz"):
            if others_position is None:
                others_position = len(listed)
                listed.append(None)
            continue
        index = token_to_index.get(token)
        if index is None or index in seen:
            continue
        seen.add(index)
        listed.append(index)
    if not seen and others_position is None:
        return None
    unlisted = [
        index for index in range(len(state.groups)) if index not in seen
    ]
    if others_position is None:
        listed.extend(unlisted)
    else:
        listed[others_position : others_position + 1] = unlisted

    hani = state.hani_group
    others = next(
        (
            index
            for index, group in enumerate(state.groups)
            if group.token == "others"
        ),
        None,
    )

    def is_han_or_others(group):
        return group is not None and group in (hani, others)

    # Classify every tailored primary so that weights allocated outside their
    # group's normal range keep their order inside the reordered block.
    classes: dict[tuple[tuple[int, ...], int], tuple[str, int | None]] = {}
    pre_primaries: dict[int, set[int]] = {}
    overflow_primaries: dict[int, set[int]] = {}
    for sequence, ces in state.tailored.items():
        group = state.sequence_group.get(sequence)
        last_group_primary: int | None = None
        for ce_index, ce in enumerate(ces):
            primary = ce[0]
            if primary == 0:
                continue
            if primary >= OVERFLOW_START:
                target = group if group is not None else state.group_of(primary)
                classes[(sequence, ce_index)] = ("overflow", target)
                if target is not None:
                    overflow_primaries.setdefault(target, set()).add(primary)
                if is_han_or_others(target):
                    last_group_primary = primary
                continue
            if CONTINUATION_START <= primary < HANI_START:
                if last_group_primary is not None:
                    classes[(sequence, ce_index)] = ("continuation", group)
                    continue
                target = group if group is not None else state.group_of(primary)
                classes[(sequence, ce_index)] = ("pre", target)
                if target is not None:
                    pre_primaries.setdefault(target, set()).add(primary)
                continue
            if primary >= RESERVED_START:
                continue
            target = state.group_of(primary)
            classes[(sequence, ce_index)] = ("normal", target)
            if is_han_or_others(target):
                last_group_primary = primary

    pre_lists = {group: sorted(values) for group, values in pre_primaries.items()}
    overflow_lists = {
        group: sorted(values) for group, values in overflow_primaries.items()
    }
    pre_rank = {
        group: {primary: rank for rank, primary in enumerate(values)}
        for group, values in pre_lists.items()
    }
    overflow_rank = {
        group: {primary: rank for rank, primary in enumerate(values)}
        for group, values in overflow_lists.items()
    }

    group_count = len(state.groups)
    pre_base = [0] * group_count
    new_base = [0] * group_count
    overflow_base = [0] * group_count
    cursor = 0x10000
    for index in listed:
        group = state.groups[index]
        pre = pre_lists.get(index, [])
        pre_base[index] = cursor
        cursor += len(pre)
        new_base[index] = cursor
        cursor += group.end - group.start
        overflow = overflow_lists.get(index, [])
        overflow_base[index] = cursor
        cursor += len(overflow)
    cont_base = (cursor + 0xFFF) & ~0xFFF

    primary_map: dict[tuple[tuple[int, ...], int], int] = {}
    for (sequence, ce_index), (kind, group) in classes.items():
        primary = state.tailored[sequence][ce_index][0]
        if kind == "continuation":
            primary_map[(sequence, ce_index)] = (
                cont_base + (primary - CONTINUATION_START)
            )
        elif group is None:
            continue
        elif kind == "pre":
            primary_map[(sequence, ce_index)] = (
                pre_base[group] + pre_rank[group][primary]
            )
        elif kind == "overflow":
            primary_map[(sequence, ce_index)] = (
                overflow_base[group] + overflow_rank[group][primary]
            )
        else:
            primary_map[(sequence, ce_index)] = (
                new_base[group] + (primary - state.groups[group].start)
            )
    return ReorderPlan(
        new_base,
        pre_base,
        pre_rank,
        overflow_base,
        overflow_rank,
        cont_base,
        primary_map,
    )



class CompileError(Exception):
    pass


class State:
    def __init__(self, entries, implicit, groups):
        self.map: dict[tuple[int, ...], list[tuple[int, int, int, bool]]] = {
            sequence: list(ces) for sequence, ces in entries
        }
        self.groups = groups
        self.group_starts = [group.start for group in groups]
        self.hani_group = next(
            (
                index
                for index, group in enumerate(groups)
                if group.token == "Hani"
            ),
            None,
        )
        self.primary_group: dict[int, int | None] = {}
        self.sequence_group: dict[tuple[int, ...], int | None] = {}
        self.primaries = sorted(
            {ce[0] for ces in self.map.values() for ce in ces if ce[0]}
        )
        self.secondaries: dict[int, list[int]] = {}
        self.tertiaries: dict[tuple[int, int], list[int]] = {}
        for ces in self.map.values():
            if not ces:
                continue
            context = ces[0][0]
            for p, s, t, _ in ces:
                if s:
                    self._insert(self.secondaries.setdefault(context, []), s)
                if t:
                    self._insert(self.tertiaries.setdefault((p, s), []), t)
        self.implicit = implicit
        self.origin_by_base: dict[int, int] = {}
        for first, _, base in implicit:
            self.origin_by_base.setdefault(base, first)
        self.tailored: dict[tuple[int, ...], list[tuple[int, int, int, bool]]] = {}
        self.reorders: list[str] = []
        self.case_first = 0
        self.backwards = False
        self.overflow_primary = 0x10000000

    @staticmethod
    def _insert(values: list[int], value: int) -> None:
        index = bisect.bisect_left(values, value)
        if index == len(values) or values[index] != value:
            values.insert(index, value)

    def group_of(self, primary: int) -> int | None:
        if primary == 0:
            return None
        if primary in self.primary_group:
            group = self.primary_group[primary]
            if group is not None:
                return group
        if primary >= RESERVED_START:
            return None
        if CONTINUATION_START <= primary < HANI_START:
            # Implicit continuation weights and tailorings derived from them
            # belong to the Hani group; unassigned continuations only occur at
            # runtime, never in compiled root or tailoring data.
            return self.hani_group
        index = bisect.bisect_right(self.group_starts, primary) - 1
        if index < 0 or primary >= self.groups[index].end:
            return None
        return index

    def _record_ces(self, ces: list[tuple[int, int, int, bool]]) -> None:
        if not ces:
            return
        context = ces[0][0]
        for p, s, t, _ in ces:
            if p:
                self._insert(self.primaries, p)
            if s:
                self._insert(self.secondaries.setdefault(context, []), s)
            if t:
                self._insert(self.tertiaries.setdefault((p, s), []), t)

    def implicit_ces(self, codepoint: int) -> list[tuple[int, int, int, bool]]:
        for first, last, base in self.implicit:
            if first <= codepoint <= last:
                origin = self.origin_by_base[base]
                return [
                    (base << WEIGHT_SCALE, COMMON_SECONDARY, COMMON_TERTIARY, False),
                    (((codepoint - origin) | 0x8000) << WEIGHT_SCALE, 0, 0, False),
                ]
        if (0x4E00 <= codepoint <= 0x9FFF) or (0xF900 <= codepoint <= 0xFAFF):
            base = 0xFB40
        elif (0x3400 <= codepoint <= 0x4DBF) or (0x20000 <= codepoint <= 0x2FA1F):
            base = 0xFB80
        else:
            base = 0xFBC0
        return [
            ((base + (codepoint >> 15)) << WEIGHT_SCALE, COMMON_SECONDARY, COMMON_TERTIARY, False),
            (((codepoint & 0x7FFF) | 0x8000) << WEIGHT_SCALE, 0, 0, False),
        ]

    def ces_for(self, sequence: tuple[int, ...]) -> list[tuple[int, int, int, bool]]:
        result: list[tuple[int, int, int, bool]] = []
        index = 0
        while index < len(sequence):
            found = None
            for length in range(min(4, len(sequence) - index), 0, -1):
                key = sequence[index : index + length]
                if key in self.map:
                    found = (key, self.map[key])
                    break
            if found is None:
                result.extend(self.implicit_ces(sequence[index]))
                index += 1
            else:
                result.extend(found[1])
                index += len(found[0])
        return result

    def next_primary(self, value: int) -> int | None:
        index = bisect.bisect_right(self.primaries, value)
        return self.primaries[index] if index < len(self.primaries) else None

    def prev_primary(self, value: int) -> int | None:
        index = bisect.bisect_left(self.primaries, value) - 1
        return self.primaries[index] if index >= 0 else None

    def next_secondary(self, context: int, value: int) -> int | None:
        values = self.secondaries.get(context, [])
        index = bisect.bisect_right(values, value)
        return values[index] if index < len(values) else None

    def prev_secondary(self, context: int, value: int) -> int | None:
        values = self.secondaries.get(context, [])
        index = bisect.bisect_left(values, value) - 1
        return values[index] if index >= 0 else None

    def next_tertiary(self, key: tuple[int, int], value: int) -> int | None:
        values = self.tertiaries.get(key, [])
        index = bisect.bisect_right(values, value)
        return values[index] if index < len(values) else None

    def prev_tertiary(self, key: tuple[int, int], value: int) -> int | None:
        values = self.tertiaries.get(key, [])
        index = bisect.bisect_left(values, value) - 1
        return values[index] if index >= 0 else None

    @staticmethod
    def _free_after(values: list[int], start: int) -> int:
        index = bisect.bisect_right(values, start)
        candidate = start + 1 if start else 1
        while index < len(values):
            value = values[index]
            if value > candidate:
                break
            if value == candidate:
                if candidate % (1 << WEIGHT_SCALE) == 0:
                    raise CompileError(
                        f"no room after {start:08X}: root boundary at {candidate:08X}"
                    )
                candidate += 1
                index += 1
                continue
            break
        return candidate

    @staticmethod
    def _free_before(values: list[int], lower: int, end: int) -> int:
        if end - lower <= 1:
            raise CompileError(f"no room before {end:08X}")
        middle = lower + (end - lower) // 2
        occupied = set(values)
        for candidate in range(middle, lower, -1):
            if candidate not in occupied:
                return candidate
        for candidate in range(middle + 1, end):
            if candidate not in occupied:
                return candidate
        raise CompileError(f"no room before {end:08X}")

    def allocate_after(self, strength: int, ce: tuple[int, int, int, bool]):
        p, s, t, variable = ce
        if strength == 1:
            try:
                new = self._free_after(self.primaries, p)
            except CompileError:
                # Large generated tailorings (for example Chinese pinyin)
                # can exhaust the gap before the implicit weights. Allocate a
                # dedicated overflow range above every root and implicit
                # primary; the relative order inside the tailoring is kept.
                new = self.overflow_primary
                self.overflow_primary += 1
            self._insert(self.primaries, new)
            self.primary_group[new] = self.group_of(p)
            return (new, COMMON_SECONDARY, COMMON_TERTIARY, False)
        if strength == 2:
            context = p if p else 0
            values = self.secondaries.setdefault(context, [])
            new = self._free_after(values, s)
            self._insert(values, new)
            return (p, new, COMMON_TERTIARY, variable)
        if strength == 3:
            key = (p, s)
            values = self.tertiaries.setdefault(key, [])
            new = self._free_after(values, t)
            self._insert(values, new)
            return (p, s, new, variable)
        raise CompileError("quaternary relations are not supported")

    def allocate_before(self, strength: int, ce: tuple[int, int, int, bool]):
        p, s, t, variable = ce
        if strength == 1:
            lower = self.prev_primary(p)
            new = self._free_before(
                self.primaries,
                lower if lower is not None else 0,
                p,
            )
            self._insert(self.primaries, new)
            self.primary_group[new] = self.group_of(p)
            return (new, COMMON_SECONDARY, COMMON_TERTIARY, False)
        if strength == 2:
            context = p if p else 0
            lower = self.prev_secondary(context, s)
            values = self.secondaries.setdefault(context, [])
            new = self._free_before(
                values,
                lower if lower is not None else 0,
                s,
            )
            self._insert(values, new)
            return (p, new, COMMON_TERTIARY, variable)
        if strength == 3:
            key = (p, s)
            lower = self.prev_tertiary(key, t)
            values = self.tertiaries.setdefault(key, [])
            new = self._free_before(
                values,
                lower if lower is not None else 0,
                t,
            )
            self._insert(values, new)
            return (p, s, new, variable)
        raise CompileError("quaternary relations are not supported")


def nfd(text: str) -> tuple[int, ...]:
    return tuple(ord(character) for character in unicodedata.normalize("NFD", text))


def find_last(ces, strength):
    for index in range(len(ces) - 1, -1, -1):
        p, s, t, _ = ces[index]
        if strength == 1 and p:
            return index
        if strength == 2 and (p or s):
            return index
        if strength == 3 and (p or s or t):
            return index
    return None


def apply_relation(state, current, sequence, strength, *, before=False, extension=None):
    if strength == 0:
        new = list(current)
    else:
        index = find_last(current, strength)
        if index is None:
            base = (0, 0, 0, False)
            new = []
        else:
            base = current[index]
            new = current[:index]
        changed = (
            state.allocate_before(strength, base)
            if before
            else state.allocate_after(strength, base)
        )
        new.append(changed)
    extension_ces: list[tuple[int, int, int, bool]] = []
    if extension:
        normalized = unicodedata.normalize(
            "NFD", "".join(chr(codepoint) for codepoint in extension)
        )
        extension_ces = state.ces_for(
            tuple(ord(character) for character in normalized)
        )
        new.extend(extension_ces)
    case = sequence_case(sequence)
    if case in ("upper", "lower"):
        main_count = len(new) - len(extension_ces)
        for index in range(main_count):
            p, s, t, variable = new[index]
            if p:
                new[index] = (p, s, set_tertiary_case(t, case), variable)
    group = state.group_of(base[0]) if strength > 0 and index is not None else None
    if group is None:
        for p, _, _, _ in new:
            group = state.group_of(p)
            if group is not None:
                break
    state.sequence_group[sequence] = group
    state.map[sequence] = new
    state.tailored[sequence] = new
    state._record_ces(new)
    return new


class Reader:
    def __init__(self, text: str):
        self.text = text
        self.index = 0

    def eof(self) -> bool:
        return self.index >= len(self.text)

    def peek(self) -> str:
        return self.text[self.index] if self.index < len(self.text) else ""

    def skip_space(self) -> None:
        while self.index < len(self.text):
            character = self.text[self.index]
            if character in " \t\r\n":
                self.index += 1
            elif character == "#":
                while self.index < len(self.text) and self.text[self.index] != "\n":
                    self.index += 1
            else:
                return

    def read_directive(self) -> str:
        if self.text[self.index] != "[":
            raise CompileError("expected directive")
        start = self.index + 1
        depth = 1
        quote = False
        while self.index + 1 < len(self.text):
            self.index += 1
            character = self.text[self.index]
            if quote:
                if character == "'":
                    quote = False
                continue
            if character == "'":
                quote = True
            elif character == "[":
                depth += 1
            elif character == "]":
                depth -= 1
                if depth == 0:
                    self.index += 1
                    return self.text[start : self.index - 1]
        raise CompileError("unterminated directive")

    def read_token(self, *, star: bool = False):
        self.skip_space()
        items: list[int | str] = []
        extension: list[int] | None = None
        target = items
        buffer: list[int] = []
        quoted = False

        def flush():
            nonlocal buffer
            target.extend(buffer)
            buffer = []

        while self.index < len(self.text):
            character = self.text[self.index]
            if quoted:
                if character == "'":
                    if (
                        self.index + 1 < len(self.text)
                        and self.text[self.index + 1] == "'"
                    ):
                        buffer.append(0x27)
                        self.index += 2
                        continue
                    quoted = False
                    self.index += 1
                    continue
                if character == "\\":
                    codepoint, consumed = read_escape(self.text, self.index)
                    buffer.append(codepoint)
                    self.index += consumed
                    continue
                buffer.append(ord(character))
                self.index += 1
                continue
            if character in " \t\r\n" or character in "&<=[":
                break
            if character == "'":
                quoted = True
                self.index += 1
                continue
            if character == "\\":
                codepoint, consumed = read_escape(self.text, self.index)
                buffer.append(codepoint)
                self.index += consumed
                continue
            if character == "/":
                flush()
                if extension is None:
                    extension = []
                    target = extension
                self.index += 1
                continue
            if character == "|":
                raise CompileError("prefix context is not supported")
            if star and character == "-" and target is items:
                flush()
                items.append("-")
                self.index += 1
                continue
            buffer.append(ord(character))
            self.index += 1
        flush()
        if star:
            return expand_star_items(items), extension
        return tuple(items), extension


def read_escape(text: str, index: int) -> tuple[int, int]:
    kind = text[index + 1] if index + 1 < len(text) else ""
    if kind == "u":
        return int(text[index + 2 : index + 6], 16), 6
    if kind == "U":
        return int(text[index + 2 : index + 10], 16), 10
    simple = {"t": 9, "n": 10, "r": 13, "\\": 92, "'": 39}
    if kind in simple:
        return simple[kind], 2
    return ord(kind), 2


def expand_star_items(items: list[int | str]) -> list[int]:
    result: list[int] = []
    index = 0
    while index < len(items):
        item = items[index]
        if item == "-":
            raise CompileError("dangling range marker")
        if index + 2 < len(items) and items[index + 1] == "-":
            end = items[index + 2]
            if not isinstance(item, int) or not isinstance(end, int) or end < item:
                raise CompileError("invalid starred range")
            result.extend(range(item, end + 1))
            index += 3
        else:
            result.append(item)
            index += 1
    return result


def logical_reset(state: State, directive: str):
    name = directive.strip()
    if name == "last regular":
        value = max(
            p
            for ces in state.map.values()
            for p, _, _, variable in ces
            if p and not variable and p < IMPLICIT_START
        )
        return [(value, COMMON_SECONDARY, COMMON_TERTIARY, False)]
    if name == "first regular":
        value = min(
            p
            for ces in state.map.values()
            for p, _, _, variable in ces
            if p and not variable and p < IMPLICIT_START
        )
        return [(value, COMMON_SECONDARY, COMMON_TERTIARY, False)]
    if name == "last primary ignorable":
        value = max(
            s
            for ces in state.map.values()
            for p, s, _, _ in ces
            if p == 0 and s
        )
        return [(0, value, COMMON_TERTIARY, False)]
    if name == "first primary ignorable":
        value = min(
            s
            for ces in state.map.values()
            for p, s, _, _ in ces
            if p == 0 and s
        )
        return [(0, value, COMMON_TERTIARY, False)]
    if name == "last variable":
        value = max(
            p
            for ces in state.map.values()
            for p, _, _, variable in ces
            if p and variable
        )
        return [(value, COMMON_SECONDARY, COMMON_TERTIARY, True)]
    if name == "first variable":
        value = min(
            p
            for ces in state.map.values()
            for p, _, _, variable in ces
            if p and variable
        )
        return [(value, COMMON_SECONDARY, COMMON_TERTIARY, True)]
    if name == "last tertiary ignorable":
        values = [
            t
            for ces in state.map.values()
            for p, s, t, _ in ces
            if p == 0 and s == 0 and t
        ]
        return [(0, 0, max(values) if values else 0, False)]
    if name == "first tertiary ignorable":
        values = [
            t
            for ces in state.map.values()
            for p, s, t, _ in ces
            if p == 0 and s == 0 and t
        ]
        return [(0, 0, min(values) if values else 0, False)]
    if name in ("first secondary ignorable", "last secondary ignorable"):
        return [(0, 0, 0, False)]
    raise CompileError(f"unsupported logical reset {name!r}")


def parse_rules(state: State, text: str, stack: list[tuple[str, str]], locale: str):
    # CLDR rule files embed bidi control characters for readability; they are
    # not part of the rules.
    text = text.replace("\u200e", "").replace("\u200f", "").replace("\u061c", "")
    reader = Reader(text)
    current = None
    before_strength = None
    while True:
        reader.skip_space()
        if reader.eof():
            break
        character = reader.peek()
        if character == "[":
            directive = reader.read_directive().strip()
            if directive.startswith("import "):
                do_import(state, directive.split(None, 1)[1].strip(), stack, locale)
            elif directive.startswith("reorder "):
                state.reorders.append(directive)
            elif directive.startswith("caseFirst"):
                parts = directive.split()
                value = parts[1].lower() if len(parts) > 1 else "off"
                state.case_first = {"off": 0, "upper": 1, "lower": 2}.get(
                    value, 0
                )
            elif directive.startswith("backwards"):
                parts = directive.split()
                state.backwards = len(parts) == 1 or parts[1] != "0"
            elif directive.startswith("before "):
                raise CompileError("before directive outside a reset")
            # Other settings are accepted but not compiled.
            continue
        if character == "&":
            reader.index += 1
            before_strength = None
            current = None
            logical = False
            while True:
                reader.skip_space()
                if reader.peek() != "[":
                    break
                directive = reader.read_directive().strip()
                if directive.startswith("before "):
                    before_strength = int(directive.split()[1])
                elif directive.startswith("first ") or directive.startswith("last "):
                    current = logical_reset(state, directive)
                    logical = True
                elif directive.startswith("import "):
                    do_import(state, directive.split(None, 1)[1].strip(), stack, locale)
                else:
                    raise CompileError(f"unsupported reset directive {directive!r}")
            if not logical:
                sequence, _ = reader.read_token()
                normalized = unicodedata.normalize(
                    "NFD", "".join(chr(codepoint) for codepoint in sequence)
                )
                current = state.ces_for(
                    tuple(ord(character) for character in normalized)
                )
            continue
        if character == "=":
            reader.index += 1
            strength = 0
        elif character == "<":
            strength = 0
            while reader.peek() == "<":
                strength += 1
                reader.index += 1
        else:
            raise CompileError(f"unexpected character {character!r}")
        if strength > 3:
            raise CompileError("quaternary relations are not supported")
        starred = reader.peek() == "*"
        if starred:
            reader.index += 1
        if current is None:
            raise CompileError("relation without reset")
        if starred:
            items, extension = reader.read_token(star=True)
            for codepoint in items:
                sequence = nfd(chr(codepoint))
                current = apply_relation(
                    state,
                    current,
                    sequence,
                    strength,
                    before=before_strength is not None,
                    extension=extension,
                )
                before_strength = None
        else:
            sequence, extension = reader.read_token()
            sequence = tuple(
                ord(character)
                for character in unicodedata.normalize(
                    "NFD", "".join(chr(codepoint) for codepoint in sequence)
                )
            )
            current = apply_relation(
                state,
                current,
                sequence,
                strength,
                before=before_strength is not None,
                extension=extension,
            )
            before_strength = None


def load_xml(archive: zipfile.ZipFile, locale: str) -> str:
    return archive.read(f"common/collation/{locale}.xml").decode("utf-8")


def extract_collations(xml: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for match in re.finditer(
        r"<collation\s+([^>]*)>(.*?)</collation>",
        xml,
        re.S,
    ):
        attributes = match.group(1)
        if "alt=" in attributes:
            continue
        type_match = re.search(r"type=['\"]([^'\"]+)['\"]", attributes)
        if type_match is None:
            continue
        rules = "\n".join(
            re.findall(r"<cr><!\[CDATA\[(.*?)\]\]></cr>", match.group(2), re.S)
        )
        result[type_match.group(1)] = rules
    return result


def extract_collation(xml: str, collation_type: str) -> str | None:
    return extract_collations(xml).get(collation_type)


def do_import(state: State, target: str, stack: list[tuple[str, str]], locale: str):
    match = re.match(
        r"^([A-Za-z0-9_]+)(?:-u-co-([a-z0-9]+))?$",
        target,
    )
    if match is None:
        return
    imported_locale = match.group(1)
    collation_type = match.group(2) or "standard"
    if imported_locale == "und":
        return
    key = (imported_locale, collation_type)
    if key in stack or key == (locale, "standard"):
        return
    with zipfile.ZipFile(CLDR_ZIP) as archive:
        try:
            xml = load_xml(archive, imported_locale)
        except KeyError:
            return
    rules = extract_collation(xml, collation_type)
    if rules is None:
        return
    parse_rules(state, rules, stack + [key], imported_locale)


def compile_locale(locale: str, collation_type: str, entries, implicit, groups):
    with zipfile.ZipFile(CLDR_ZIP) as archive:
        try:
            xml = load_xml(archive, locale)
        except KeyError:
            return None
    rules = extract_collation(xml, collation_type)
    if rules is None:
        return None
    state = State(entries, implicit, groups)
    parse_rules(state, rules, [(locale, collation_type)], locale)
    return state


def render_blob(compiled: dict[tuple[str, str], State], groups) -> bytes:
    keys = sorted(compiled)
    plans: dict[tuple[str, str], ReorderPlan] = {}
    map_indices: dict[tuple[str, str], int] = {}
    for key in keys:
        state = compiled[key]
        if not state.reorders:
            continue
        plan = build_reorder_plan(state)
        if plan is None:
            continue
        map_indices[key] = len(plans)
        plans[key] = plan
    rules: list[tuple[tuple[str, str], tuple[int, ...], list[tuple[int, int, int, bool]]]] = []
    for key in keys:
        state = compiled[key]
        for sequence, ces in state.tailored.items():
            if not sequence or len(sequence) > MAX_SEQUENCE:
                raise CompileError(f"{key}: sequence length out of range")
            rules.append((key, sequence, ces))
    rules.sort(
        key=lambda item: (
            item[0][0],
            item[0][1],
            item[1][0],
            -len(item[1]),
            item[1],
        )
    )

    names = bytearray()
    string_offsets: dict[str, int] = {}
    for key in keys:
        for value in key:
            if value in string_offsets:
                continue
            string_offsets[value] = len(names)
            names.extend(value.encode("utf-8"))

    codepoints = bytearray()
    ce_pool = bytearray()
    rule_records: list[tuple[int, int, int, int, int]] = []
    for key, sequence, ces in rules:
        sequence_offset = len(codepoints) // 4
        for codepoint in sequence:
            codepoints.extend(struct.pack("<I", codepoint))
        ce_offset = len(ce_pool) // 16
        plan = plans.get(key)
        for ce_index, ce in enumerate(ces):
            p, s, t, variable = ce
            if plan is not None:
                p = plan.primary_map.get((sequence, ce_index), p)
            ce_pool.extend(struct.pack("<IIIB3x", p, s, t, 1 if variable else 0))
        rule_records.append(
            (sequence_offset, len(sequence), ce_offset, len(ces), sequence[0])
        )

    locale_records = []
    rule_index = 0
    for key in keys:
        count = sum(1 for item in rules if item[0] == key)
        locale, collation_type = key
        state = compiled[key]
        flags = (1 if state.backwards else 0) | (state.case_first << 1)
        if key in map_indices:
            flags |= 8
        locale_records.append(
            (
                string_offsets[locale],
                len(locale.encode("utf-8")),
                string_offsets[collation_type],
                len(collation_type.encode("utf-8")),
                rule_index,
                count,
                flags,
                map_indices.get(key, 0),
            )
        )
        rule_index += count

    header = bytearray(b"CJTL")
    header += struct.pack(
        "<B3BHIIIIH",
        5,
        CLDR_VERSION,
        0,
        0,
        len(keys),
        len(rules),
        len(ce_pool) // 16,
        len(names),
        len(codepoints) // 4,
        0,
    )
    for (
        name_offset,
        name_length,
        type_offset,
        type_length,
        rule_start,
        rule_count,
        flags,
        reorder_map,
    ) in locale_records:
        header += struct.pack(
            "<HBHBIIBB",
            name_offset,
            name_length,
            type_offset,
            type_length,
            rule_start,
            rule_count,
            flags,
            reorder_map,
        )
    for (
        sequence_offset,
        sequence_length,
        ce_offset,
        ce_count,
        first_codepoint,
    ) in rule_records:
        header += struct.pack(
            "<IBIBHI",
            sequence_offset,
            sequence_length,
            ce_offset,
            ce_count,
            0,
            first_codepoint,
        )

    reorder = bytearray()
    hani_group = next(
        (index for index, group in enumerate(groups) if group.token == "Hani"),
        0xFFFF,
    )
    others_group = next(
        (index for index, group in enumerate(groups) if group.token == "others"),
        0xFFFF,
    )
    reorder += struct.pack(
        "<HHHHI",
        len(groups),
        hani_group,
        others_group,
        len(plans),
        0,
    )
    for group in groups:
        reorder += struct.pack("<II", group.start, group.end)
    for key in keys:
        plan = plans.get(key)
        if plan is None:
            continue
        reorder += struct.pack("<I", plan.cont_base)
        for value in plan.new_base:
            reorder += struct.pack("<I", value)
    return bytes(header + names + codepoints + ce_pool + reorder)


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    global CLDR_ZIP
    CLDR_ZIP = Path(sys.argv[1])
    allkeys_path = Path(sys.argv[2])
    uca_path = Path(sys.argv[3])
    out_dir = Path(sys.argv[4])
    out_dir.mkdir(parents=True, exist_ok=True)

    archive_bytes = CLDR_ZIP.read_bytes()
    actual = hashlib.sha256(archive_bytes).hexdigest()
    if actual != CLDR_SHA256:
        raise SystemExit(
            f"{CLDR_ZIP}: expected CLDR 48 SHA-256 {CLDR_SHA256}, found {actual}"
        )

    entries = parse_entries(checked_text(allkeys_path, ALLKEYS_SHA256))
    implicit = parse_implicit(checked_text(uca_path, UCA_INPUT_SHA256))
    with zipfile.ZipFile(CLDR_ZIP) as archive:
        locales = sorted(
            name[len("common/collation/") : -len(".xml")]
            for name in archive.namelist()
            if name.startswith("common/collation/") and name.endswith(".xml")
        )
        groups = parse_reorder_groups(archive)

    compiled: dict[tuple[str, str], State] = {}
    skipped: list[tuple[str, str]] = []
    with zipfile.ZipFile(CLDR_ZIP) as archive:
        for locale in locales:
            try:
                xml = load_xml(archive, locale)
            except KeyError:
                continue
            for collation_type, rules in extract_collations(xml).items():
                try:
                    state = State(entries, implicit, groups)
                    parse_rules(
                        state,
                        rules,
                        [(locale, collation_type)],
                        locale,
                    )
                except CompileError as error:
                    skipped.append((f"{locale}/{collation_type}", str(error)))
                    continue
                compiled[(locale, collation_type)] = state

    (out_dir / "tailorings.bin").write_bytes(render_blob(compiled, groups))
    print(
        f"compiled {len(compiled)} locale/type entries, skipped {len(skipped)} "
        f"({sum(len(state.tailored) for state in compiled.values())} rules)",
        file=sys.stderr,
    )
    for key, reason in skipped:
        print(f"  skipped {key}: {reason}", file=sys.stderr)
    return 0


CLDR_ZIP: Path

if __name__ == "__main__":
    raise SystemExit(main())
