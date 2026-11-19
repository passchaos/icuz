#!/usr/bin/env python3
"""Generate localized time zone names from CLDR.

Usage:
    generate_names.py cldr-common-48.zip tzdata_dir out_dir

Reads `common/main/<locale>.xml` timeZoneNames and territory display names,
`common/supplemental/metaZones.xml` zone-to-metazone periods, and the IANA
`zone1970.tab`/`backward` files for zone-to-country mappings. The output is a
`CJZN` v1 blob consumed by src/unicode/timezone/root.zig.
"""

from __future__ import annotations

import datetime
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from pathlib import Path

LOCALES = (
    "af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs",
    "cy", "da", "de", "de-AT", "de-CH", "el", "en", "en-AU", "en-CA",
    "en-GB", "en-IN", "es", "es-419", "es-MX", "et", "eu", "fa", "fi",
    "fil", "fr", "fr-CA", "ga", "gl", "gu", "he", "hi", "hr", "hu",
    "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "lo",
    "lt", "lv", "mk", "ml", "mn", "mr", "ms", "mt", "my", "nb", "ne",
    "nl", "nl-BE", "pa", "pl", "ps", "pt", "pt-PT", "ro", "ru", "si",
    "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk",
    "ur", "uz", "vi", "zh", "zh-Hant", "zu",
)

PARENT = {
    "de-AT": "de",
    "de-CH": "de",
    "en-AU": "en-001",
    "en-CA": "en-001",
    "en-GB": "en-001",
    "en-IN": "en-001",
    "es-419": "es",
    "es-MX": "es-419",
    "fr-CA": "fr",
    "nb": "no",
    "nl-BE": "nl",
    "pt-PT": "pt",
    "zh-Hant": "root",
}

FORMAT_DEFAULTS = {
    "hourFormat": "+HH:mm;-HH:mm",
    "gmtFormat": "GMT{0}",
    "gmtZeroFormat": "GMT",
    "regionFormat": "{0}",
    "fallbackFormat": "{1} ({0})",
}

NAME_FIELDS = (
    "long_generic",
    "long_standard",
    "long_daylight",
    "short_generic",
    "short_standard",
    "short_daylight",
)

MIN_TIME = -(2**63)
MAX_TIME = 2**63 - 1

# ICU's `primaryZones` table for multi-zone countries (icu4c
# source/data/misc/metaZones.txt). Countries with a single canonical zone are
# primary without an entry here.
PRIMARY_ZONES = {
    "CL": "America/Santiago",
    "CN": "Asia/Shanghai",
    "DE": "Europe/Berlin",
    "EC": "America/Guayaquil",
    "ES": "Europe/Madrid",
    "MH": "Pacific/Majuro",
    "MY": "Asia/Kuala_Lumpur",
    "NZ": "Pacific/Auckland",
    "PT": "Europe/Lisbon",
    "UA": "Europe/Kiev",
    "UZ": "Asia/Tashkent",
}


def parent_chain(locale: str) -> list[str]:
    chain = []
    current = locale
    seen: set[str] = set()
    while current not in seen:
        seen.add(current)
        chain.append(current)
        if current == "root":
            break
        parent = PARENT.get(current)
        if parent is None:
            parent = re.split(r"[-_]", current)[0]
        if parent == current:
            parent = "root"
        current = parent
    if chain[-1] != "root":
        chain.append("root")
    return chain


def parse_metazone_time(text: str | None, default: int) -> int:
    if not text:
        return default
    moment = datetime.datetime.strptime(text.strip(), "%Y-%m-%d %H:%M")
    return int(moment.replace(tzinfo=datetime.timezone.utc).timestamp())


def parse_metazone_uses(archive: zipfile.ZipFile):
    document = ET.fromstring(archive.read("common/supplemental/metaZones.xml"))
    uses = []
    for timezone in document.findall(".//metazoneInfo/timezone"):
        zone = timezone.get("type")
        for use in timezone.findall("usesMetazone"):
            metazone = use.get("mzone")
            if not metazone:
                continue
            uses.append(
                (
                    zone,
                    parse_metazone_time(use.get("from"), MIN_TIME),
                    parse_metazone_time(use.get("to"), MAX_TIME),
                    metazone,
                )
            )
    return uses


def parse_zone_countries(tzdata_dir: Path):
    links = {}
    backward = tzdata_dir / "backward"
    if backward.is_file():
        for line in backward.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line.startswith("Link"):
                continue
            parts = line.split()
            if len(parts) >= 3:
                links[parts[2]] = parts[1]
    countries = {}
    zone_tab = tzdata_dir / "zone1970.tab"
    if not zone_tab.is_file():
        zone_tab = tzdata_dir / "zone.tab"
    for line in zone_tab.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        countries[parts[2]] = parts[0].split(",")[0]

    def resolve(name: str) -> str:
        seen: set[str] = set()
        while name in links and name not in seen:
            seen.add(name)
            name = links[name]
        return name

    mapping = {}
    for name in set(countries) | set(links):
        if name in countries:
            mapping[name] = countries[name]
            continue
        canonical = resolve(name)
        if canonical in countries:
            mapping[name] = countries[canonical]
    canonical_countries = {}
    for name, country in mapping.items():
        canonical_countries.setdefault(resolve(name) if name not in countries else name, country)
    counts = Counter(canonical_countries.values())
    result = {}
    for name, country in mapping.items():
        canonical = resolve(name)
        primary = counts[country] == 1
        if not primary:
            configured = PRIMARY_ZONES.get(country)
            if configured is not None and resolve(configured) == canonical:
                primary = True
        result[name] = (canonical, country, primary)
    return result, resolve


def parse_locale(archive: zipfile.ZipFile, locale: str, cache: dict) -> dict:
    if locale in cache:
        return cache[locale]
    merged = {
        "formats": {},
        "zones": {},
        "metazones": {},
        "territories": {},
    }
    for name in reversed(parent_chain(locale)):
        filename = name.replace("-", "_")
        try:
            text = archive.read(f"common/main/{filename}.xml")
        except KeyError:
            continue
        document = ET.fromstring(text)
        names = document.find(".//timeZoneNames")
        if names is not None:
            for tag in FORMAT_DEFAULTS:
                for element in names.findall(tag):
                    if element.get("type") or element.get("alt"):
                        continue
                    value = (element.text or "").strip()
                    if value:
                        merged["formats"][tag] = value
                    break
            for zone in names.findall("zone"):
                identifier = zone.get("type")
                if not identifier:
                    continue
                entry = merged["zones"].setdefault(identifier, {})
                city = zone.findtext("exemplarCity")
                if city is not None and city.strip():
                    entry["city"] = city.strip()
                for width in ("long", "short"):
                    element = zone.find(width)
                    if element is None:
                        continue
                    for kind in ("generic", "standard", "daylight"):
                        value = element.find(kind)
                        if value is None or value.get("draft") == "unconfirmed":
                            continue
                        if value.text is not None and value.text.strip():
                            entry[f"{width}_{kind}"] = value.text.strip()
            for metazone in names.findall("metazone"):
                identifier = metazone.get("type")
                if not identifier:
                    continue
                entry = merged["metazones"].setdefault(identifier, {})
                for width in ("long", "short"):
                    element = metazone.find(width)
                    if element is None:
                        continue
                    for kind in ("generic", "standard", "daylight"):
                        value = element.find(kind)
                        if value is None or value.get("draft") == "unconfirmed":
                            continue
                        if value.text is not None and value.text.strip():
                            entry[f"{width}_{kind}"] = value.text.strip()
        display = document.find(".//localeDisplayNames/territories")
        if display is not None:
            for territory in display.findall("territory"):
                code = territory.get("type")
                if territory.get("alt"):
                    continue
                value = (territory.text or "").strip()
                if code and value:
                    merged["territories"][code] = value
    cache[locale] = merged
    return merged


def render(
    locales: list[tuple[str, dict]],
    metazone_uses: list[tuple[str, int, int, str]],
    zone_info: dict[str, tuple[str, str, bool]],
) -> bytes:
    strings = bytearray()
    string_offsets: dict[str, int] = {}

    def intern(value: str) -> int:
        if value in string_offsets:
            return string_offsets[value]
        offset = len(strings)
        strings.extend(value.encode("utf-8"))
        strings.append(0)
        string_offsets[value] = offset
        return offset

    empty = intern("")

    def string(value: str | None) -> int:
        return intern(value) if value else empty

    # Shared tables.
    use_bytes = bytearray()
    uses = sorted(metazone_uses, key=lambda item: (item[0], item[1]))
    for zone, start, end, metazone in uses:
        use_bytes += struct.pack(
            "<IqqI", string(zone), start, end, string(metazone)
        )

    info_bytes = bytearray()
    info_names = sorted(zone_info)
    for zone in info_names:
        canonical, country, primary = zone_info[zone]
        info_bytes += struct.pack(
            "<IIII",
            string(zone),
            string(canonical),
            string(country),
            1 if primary else 0,
        )

    locale_bytes = bytearray()
    metazone_bytes = bytearray()
    zone_name_bytes = bytearray()
    region_bytes = bytearray()
    for locale, data in locales:
        metazone_start = len(metazone_bytes) // 28
        metazone_names = sorted(data["metazones"])
        for metazone in metazone_names:
            entry = data["metazones"][metazone]
            metazone_bytes += struct.pack(
                "<7I",
                string(metazone),
                *[string(entry.get(field)) for field in NAME_FIELDS],
            )
        zone_start = len(zone_name_bytes) // 32
        zone_names = sorted(data["zones"])
        for zone in zone_names:
            entry = data["zones"][zone]
            if not entry:
                continue
            zone_name_bytes += struct.pack(
                "<8I",
                string(zone),
                string(entry.get("city")),
                *[string(entry.get(field)) for field in NAME_FIELDS],
            )
        zone_count = len(zone_name_bytes) // 32 - zone_start
        region_start = len(region_bytes) // 8
        territories = sorted(data["territories"])
        for code in territories:
            region_bytes += struct.pack(
                "<II", string(code), string(data["territories"][code])
            )
        formats = dict(FORMAT_DEFAULTS)
        formats.update(data["formats"])
        hour = formats["hourFormat"].split(";")
        positive = hour[0] if len(hour) > 0 else "+HH:mm"
        negative = hour[1] if len(hour) > 1 else "-HH:mm"
        locale_bytes += struct.pack(
            "<IBBIIIIIIIHIHIH",
            string(locale),
            len(locale.encode("utf-8")),
            0,
            string(formats["gmtFormat"]),
            string(formats["gmtZeroFormat"]),
            string(positive),
            string(negative),
            string(formats["regionFormat"]),
            string(formats["fallbackFormat"]),
            metazone_start,
            len(metazone_names),
            zone_start,
            zone_count,
            region_start,
            len(territories),
        )

    header = bytearray(b"CJZN")
    header += struct.pack(
        "<B3xHHIIIIIII",
        1,
        len(locales),
        0,
        len(uses),
        len(info_names),
        len(metazone_bytes) // 28,
        len(zone_name_bytes) // 32,
        len(region_bytes) // 8,
        len(strings),
        0,
    )
    return bytes(
        header
        + locale_bytes
        + use_bytes
        + info_bytes
        + metazone_bytes
        + zone_name_bytes
        + region_bytes
        + strings
    )


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    archive_path = Path(sys.argv[1])
    tzdata_dir = Path(sys.argv[2])
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    cache: dict = {}
    with zipfile.ZipFile(archive_path) as archive:
        metazone_uses = parse_metazone_uses(archive)
        locales = [
            (locale, parse_locale(archive, locale, cache)) for locale in LOCALES
        ]
    zone_info, resolve = parse_zone_countries(tzdata_dir)
    metazone_uses = [
        (resolve(zone), start, end, metazone)
        for zone, start, end, metazone in metazone_uses
    ]
    blob = render(locales, metazone_uses, zone_info)
    (out_dir / "names_data.bin").write_bytes(blob)
    print(
        f"generated {len(locales)} locales, {len(metazone_uses)} metazone uses, "
        f"{len(zone_info)} zones, {len(blob)} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
