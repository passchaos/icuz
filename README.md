# icuz

`icuz` is a pure-Zig Unicode Character Database and UAX algorithm library. It
provides the Unicode primitives that text, font, editor, and inference stacks
need without pulling in a font or layout engine.

## Scope

- Unicode 17.0 scalar properties: full `General_Category`, `White_Space`,
  `Alphabetic`, `Uppercase`, `Lowercase`, `Math`, `Default_Ignorable_Code_Point`,
  Script, Script_Extensions, variation selectors, emoji properties, and the
  standard bidi formatting predicates.
- General_Category and Script alias resolution for `\p{...}`-style consumers.
- UAX #9 bidirectional paragraph resolution.
- UAX #14 line-break opportunities.
- UAX #15 normalization: NFC, NFD, NFKC, and NFKD.
- Simple lower/upper/title mappings plus simple and full case folding.
- UAX #24 script runs.
- UAX #29 grapheme, word, and sentence boundaries.
- UAX #50 vertical orientation.
- Arabic joining properties and the joining state machine.
- Embedded, version-pinned generated data plus conformance fixtures.

## Non-goals for 0.1

`icuz` is not a drop-in ICU replacement. It does not provide collation,
locale-sensitive formatting, charset conversion, transliteration, regular
expressions, or display/layout tailoring. Consumers that need those features
should build them on top of `icuz` or use a dedicated library.

Cangjie-specific shaping, editor word selection, Latin display composition,
and OpenType script-tag policy deliberately live in the consuming libraries,
not in `icuz`.

## Build

```sh
zig build test
zig build unicode-verify
```

`unicode-verify` checks committed blob headers, layouts, hashes, generated
sources, generator pins, and provenance without requiring an external UCD
checkout.

## Data provenance

Generated tables and conformance fixtures contain derived Unicode data. See
`THIRD_PARTY_NOTICES.md` and `licenses/Unicode-3.0.txt`.
