# Transliteration engine: remaining work

Status after the CLDR 48 rule-engine push:

- 97 compiled table transforms plus 12 named engines (`NFC`, `NFD`,
  `NFKC`, `NFKD`, `Any-Lower`, `Any-Upper`, `Any-Title`, `Any-Null`,
  `Null`, `Hex-Any`, `Any-Hex`, `Name-Any`, `Any-Name`).
- 99 conformance fixtures: 30 official CLDR test-data files and 69 PyICU
  differential fixtures.
- Blob format CJTR v11 (28-byte transform records with `filter_set`,
  `final_case`, `next_transform`, and `pre_transform`).
- Two-step pipelines work: a leading component runs via `pre_transform`,
  then the transform's own rules, then the optional `next_transform`.
  The two Ethiopic geminate pipelines and the six FONIPA-to-Amharic
  pipelines (`kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, `zu-am`) use
  this path.
- The reverse direction is compiled compositionally: `A ← B` and
  `A ↔ B` become `B -> A`, pass order is reversed, `::(null);`,
  `::null;`, and `::null();` all split passes, and reverse normalization
  uses the parenthesized form of `NFD (NFC)` directives.
- Reverse global filters (`:: (set) ;`) are compiled; filtered transforms
  run their passes and normalization per input run, matching ICU's
  compound-filter behavior.
- Property classes accept long general-category names
  (`[:Uppercase_Letter:]`, `[:Mark:]`), binary approximations
  (`Cased`, `Case_Ignorable`, `Soft_Dotted`, `Ideographic`,
  `Logical_Order_Exception`), and ISO 15924 script aliases (`Cyrl`,
  `Sinh`, ...).
- Source quantifiers are greedy, matching ICU's regex behavior
  (`X?`, `X*`, `X+` try the longest repetition first).

Verification commands:

```sh
TRAE_ZIG_GUARD_DISABLED=1 zig test src/root.zig --test-filter "transliterate"
python3 tools/unicode/verify_committed.py
```

## 1. General segment/pipeline engine

The current record chains one leading and one trailing transform.
CLDR's longer pipelines still need an ordered program of arbitrary steps:

- multiple `::Name;` references in sequence (three or more components)
- mid-rule `::NFD();` / `::NFC();` normalization steps in any position
- `::Any-Lower;` / `::Any-Upper;` / `::Any-Title;` steps in any position
- transform references with arguments, e.g.
  `::Latin-NumericPinyin(NumericPinyin-Latin);` in `Latin-Bopomofo.xml`

A full scan of CLDR's pure pipelines confirms the remaining pipelines need
at least one component that is not yet compiled (for example
`und_FONIPA-ar`, `und_FONIPA-chr`, `es_FONIPA-ja`, `und_FONIPA-fa`).
Compiling those components is the prerequisite for the next batch; the
two-step chain already covers every pipeline whose components exist.

## 2. ICU rule specificity / hidden-rule ordering

ICU rejects a rule hidden by an earlier more general rule and gives
context-specific rules precedence when both match. A naive
"context entries first" sort regresses Armenian, Spanish, and Kirghiz,
so the real specificity model is still needed.

Known failing transforms (PyICU differential fixtures):

| Transform | Failures | Main symptom |
|---|---|---|
| `Greek-Latin` | 19 | final sigma `ς` loses the `U+0331` disambiguator; `Χ` + lowercase yields `CH` instead of `Ch` |
| `Latin-Hebrew` | 20 | reverse-direction rules |
| `Maldivian-Latin-BGN` | 19 | direction/rule coverage |
| `ug-ug_FONIPA` | 20 | context/rule coverage |
| `Bopo-Latn` | 19 | reverse-direction rules |

`Greek-Latin` needs script property classes, which are implemented, plus
the specificity model above. `Latin-Hebrew` and `Bopo-Latn` need reverse
directions of transforms whose forward rules are not yet compiled.
`Latin-Arabic`, `Latin-Syriac`, and `Armenian-Latin` now pass their PyICU
fixtures after the reverse-filter and per-run normalization work.

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
- `am_FONIPA-am` compiles as the compositional inverse of
  `am-am_FONIPA` and passes 789 PyICU cases.
- `kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, and `zu-am` pass their
  PyICU pipeline fixtures.

## 6. Hex transform divergence

`Hex-Any` decodes `\uXXXX`, `\UXXXXXXXX`, and `\x{...}`. ICU also emits
lone surrogates for inputs such as `\uD800`; the UTF-8 API here cannot
represent them, so such sequences pass through unchanged.

`Any-Name` encodes named scalars as `\N{NAME}` and synthesizes
`<control-XXXX>`, `<private use area-XXXX>`, and `<unassigned-XXXX>`
names like ICU. Other unnamed categories still fall back to hex escapes.
