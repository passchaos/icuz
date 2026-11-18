# Transliteration engine: remaining work

Status after the CLDR 48 rule-engine push:

- 86 compiled table transforms plus 10 named engines (`NFC`, `NFD`,
  `NFKC`, `NFKD`, `Any-Lower`, `Any-Upper`, `Any-Title`, `Any-Null`,
  `Hex-Any`, `Any-Hex`).
- 87 conformance fixtures: 29 official CLDR test-data files and 58 PyICU
  differential fixtures.
- Blob format CJTR v11 (28-byte transform records with `filter_set`,
  `final_case`, `next_transform`, and `pre_transform`).
- Two-step pipelines already work: a leading component runs via
  `pre_transform`, then the transform's own rules, then the optional
  `next_transform`. The two Ethiopic geminate pipelines use this path.

Verification commands:

```sh
TRAE_ZIG_GUARD_DISABLED=1 zig test src/root.zig --test-filter "transliterate"
python3 tools/unicode/verify_committed.py
```

## 1. General segment/pipeline engine

The current record chains one leading and one trailing transform.
CLDR's longer pipelines need an ordered program of arbitrary steps:

- multiple `::Name;` references in sequence
- mid-rule `::NFD();` / `::NFC();` normalization steps
- `::Any-Lower;` / `::Any-Upper;` / `::Any-Title;` steps in any position
- transform references with arguments, e.g.
  `::Latin-NumericPinyin(NumericPinyin-Latin);` in `Latin-Bopomofo.xml`

Blocks ~30 pure pipelines whose first component is already compiled
(`es-ja`, `es-am`, `kk-am`, `si-am`, `ro-am`, `my-am`, `xh-chr`, ...)
but whose second component is missing (`es_FONIPA-ja`, `am_FONIPA-am`,
`und_FONIPA-ar`, ...). A CLDR transform-name alias map is also required
because directives use names such as `Amharic-Amharic/Geminate` while the
XML files are `am-Ethi-t-am-ethi-m0-geminate.xml`.

The two Ethiopic geminate pipelines have both components compiled:
`und-Ethi-t-und-latn-m0-aethiopi-geminate` and
`und-Ethi-t-und-latn-m0-ies-jes-1964-geminate`. They are the cheapest
targets once multi-step chaining and aliases exist.

## 2. ICU rule specificity / hidden-rule ordering

ICU rejects a rule hidden by an earlier more general rule and gives
context-specific rules precedence when both match. A naive
"context entries first" sort regresses Armenian, Spanish, and Kirghiz,
so the real specificity model is still needed.

Known failing transforms (PyICU differential fixtures):

| Transform | Failures | Main symptom |
|---|---|---|
| `Greek-Latin` | 19 | final sigma `ς` loses the `U+0331` disambiguator; `Χ` + lowercase yields `CH` instead of `Ch` |
| `Latin-Arabic` | 19 | reverse-direction rules |
| `Latin-Syriac` | 19 | reverse-direction rules |
| `Latin-Hebrew` | 20 | reverse-direction rules |
| `Maldivian-Latin-BGN` | 19 | direction/rule coverage |
| `ug-ug_FONIPA` | 20 | context/rule coverage |
| `Bopo-Latn` | 19 | reverse-direction rules |

`Greek-Latin` needs script property classes, which are implemented, plus
the specificity model above.

## 3. Script_Extensions based filters

Property-based input filters (`:: [:Ethiopic:] ;`) are currently skipped
because the committed `src/unicode/script_extensions/data.bin` disagrees
with ICU for some scalars (ICU places `U+2DC8` in `[:Ethiopic:]`; the
committed tables report Common). Literal filters still apply. Fixing
this requires completing the scx data, then allowing property filters in
`parse_filter`.

## 4. Pinyin tone placement

`Latin-NumericPinyin` compiles 0 entries and `NumericPinyin-Latin` 4;
`Latin-Bopomofo` then fails two tone-mark cases because it expects the
compound `::Latin-NumericPinyin(NumericPinyin-Latin);` step. The tone
"hopping" rules need the segment engine (section 1) plus context
coverage for the tone-position classes.

## 5. Candidate additions already validated

- `de-ASCII` uses the trailing `::Latin-ASCII;` chain and passes its
  official fixture.
- `Simplified-Traditional` and `Traditional-Simplified` use
  `simple` / `reverse_with_left`; the reverse builder applies explicit
  `A <- B` rules as `B -> A`.
- `Hans-Hant` / `Hant-Hans` are aliases over the same tables.
