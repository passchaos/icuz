# Transliteration engine: remaining work

Status after the CLDR 48 rule-engine push:

- 291 compiled table transforms plus 13 named engines (`NFC`, `NFD`,
  `NFKC`, `NFKD`, `Any-Lower`, `Any-Upper`, `Any-Title`, `Any-Null`,
  `Null`, `Hex-Any`, `Any-Hex`, `Name-Any`, `Any-Name`).
- 294 conformance fixtures: 30 official CLDR test-data files and 264 PyICU
  differential fixtures.
- Blob format CJTR v11 (28-byte transform records with `filter_set`,
  `final_case`, `next_transform`, and `pre_transform`).
- Two-step pipelines work: a leading component runs via `pre_transform`,
  then the transform's own rules, then the optional `next_transform`.
  The two Ethiopic geminate pipelines and the six FONIPA-to-Amharic
  pipelines (`kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, `zu-am`) use
  this path.
- Ordered step programs (blob format CJTR v12) execute arbitrary
  `::NFD;` / `::Transform;` / `::Lower;` / `::NFC;` sequences. All 145 pure
  CLDR pipelines whose components are compiled are auto-discovered,
  including the Indic script-to-script and script-to-Latin chains, the
  `X-Arabic` / `X-ur` families, and the `Latin-*` pipelines.
- Repeated-sequence collapse rules (`($var) $var+ > $1`) compile to a
  collapse entry that emits the first unit and consumes the rest.
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

The v12 step program covers arbitrary `::` sequences. Remaining gaps:

- Transform references with arguments, e.g.
  `::Latin-NumericPinyin(NumericPinyin-Latin);` in `Latin-Bopomofo.xml`.
- Pipelines whose components are not compiled (for example
  `und_FONIPA-ar`, `und_FONIPA-chr`, `es_FONIPA-ja`, `und_FONIPA-fa`).

## 2. ICU rule specificity / hidden-rule ordering

ICU rejects a rule hidden by an earlier more general rule and gives
context-specific rules precedence when both match. A naive
"context entries first" sort regresses Armenian, Spanish, and Kirghiz,
so the real specificity model is still needed.

Known failing transforms (PyICU differential fixtures):

| Transform | Failures | Main symptom |
|---|---|---|

| `Bopo-Latn` | 19 | reverse-direction rules |

`Greek-Latin`, `Latin-Greek`, `Hebrew-Latin`, `Latin-Hebrew`,
`ug-ug_FONIPA`, and `Maldivian-Latin/BGN` now pass their PyICU fixtures
after output-context stripping, nested-context order fixes, insertion
rules merged into the main rule-order scan, repeated negated source groups
with capture, numeric `ccc=` values, and the context builder for
`ug-ug_FONIPA`. `Bopo-Latn` needs the Pinyin tone engine. `nl-Title` is
implemented as a named engine on top of Any-Title plus the Dutch `IJ`
digraph fix.

Embedded case calls (`&Any-Lower($1)` / `&Any-Upper($1)`) are compiled;
`az-Title`, `el-Title`, `lt-Title`, and `tr-Title` pass their fixtures.
`nl-Title` still needs Word_Break property classes (`[:WB=ALetter:]` and
friends) plus a real `Any-Title` step. General embedded transform calls
(`&SomeTransform($1)`) remain unsupported.

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
- The nine script-to-InterIndic transforms (`Bengali-InterIndic`,
  `Devanagari-InterIndic`, `Gujarati-InterIndic`, `Gurmukhi-InterIndic`,
  `Kannada-InterIndic`, `Malayalam-InterIndic`, `Oriya-InterIndic`,
  `Tamil-InterIndic`, `Telugu-InterIndic`) compile from their own rule
  files and pass PyICU fixtures.
- `sat_Olck-sat_FONIPA`, `uz_Cyrl-uz_Latn`, and `ThaiLogical-Latin`
  compile with the context builder and pass; the `sat-am` pipeline also
  passes.
- `it-am`, `it-ja`, `ja_Latn-ru`, `ru-ja`, `cs_FONIPA-ja`, `es_FONIPA-ja`,
  and `es_FONIPA-es_419_FONIPA` pass their PyICU fixtures.
- `fa-fa_FONIPA` passes after context-group captures
  (`(context){key} > $1`) were compiled.
- `es_FONIPA-am`, `und_FONIPA-chr`, `IPA-XSampa`, `Latin-Katakana`,
  `Han-Spacedhan`, `pl/ro/sk_FONIPA-ja`, and 18 `X-chr` / `X-ja` /
  `es-am` pipelines pass their PyICU fixtures. The `ja_Latn-ko`, `ru-zh`,
  and `zh_Latn_PINYIN-ru` variants still need context or Pinyin coverage;
  the `my/pl/sat/sk/xh/zu-chr` pipelines need more `und_FONIPA-chr`
  coverage.
- `dsb-dsb_FONIPA` passes after mid-rule normalization directives were
  made pass boundaries and the global filter was moved to the first
  non-empty pass.
- `kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, and `zu-am` pass their
  PyICU pipeline fixtures.

## 6. Hex transform divergence

`Hex-Any` decodes `\uXXXX`, `\UXXXXXXXX`, and `\x{...}`. ICU also emits
lone surrogates for inputs such as `\uD800`; the UTF-8 API here cannot
represent them, so such sequences pass through unchanged.

`Any-Name` encodes named scalars as `\N{NAME}` and synthesizes
`<control-XXXX>`, `<private use area-XXXX>`, and `<unassigned-XXXX>`
names like ICU. Other unnamed categories still fall back to hex escapes.
