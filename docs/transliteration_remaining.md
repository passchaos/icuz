# Transliteration engine: remaining work

Status after the CLDR 48 rule-engine push:

- 307 compiled table transforms plus 15 named engines (`NFC`, `NFD`,
  `NFKC`, `NFKD`, `Any-Lower`, `Any-Upper`, `Any-Title`, `Any-Null`,
  `Null`, `Hex-Any`, `Any-Hex`, `Name-Any`, `Any-Name`).
- 312 conformance fixtures: 30 official CLDR test-data files and 282 PyICU
  differential fixtures.
- Blob format CJTR v19 (36-byte transform records with `filter_set`,
  `final_case`, `next_transform`, `pre_transform`, and per-pass operation
  offsets).
- Two-step pipelines work: a leading component runs via `pre_transform`,
  then the transform's own rules, then the optional `next_transform`.
  The two Ethiopic geminate pipelines and the six FONIPA-to-Amharic
  pipelines (`kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, `zu-am`) use
  this path.
- Ordered step programs (blob format CJTR v12, extended in v19) execute
  arbitrary `::NFD;` / `::Transform;` / `::Lower;` / `::NFC;` sequences.
  All 138 pure CLDR pipelines whose components are compiled are
  auto-discovered, including the Indic script-to-script and script-to-Latin
  chains, the `X-Arabic` / `X-ur` families, and the `Latin-*` pipelines.
  Rule-based transforms with interleaved steps compile the same way:
  rule sections become RUN_TABLE steps, transform references become
  component or named-engine steps, and `::[set] step;` filters scope the
  following compound steps until a rule segment resets them (CJTR v19).
  This covers `it-am`, `it-ja`, `ja_Latn-ko`, `ja_Latn-ru`,
  `Han-Spacedhan`, `Latin-Katakana`, `Latin-Bopomofo`, and `de-ASCII`.
- Repeated-sequence collapse rules (`($var) $var+ > $1`) compile to a
  collapse entry that emits the first unit and consumes the rest.
- The reverse direction is compiled compositionally: `A ← B` and
  `A ↔ B` become `B -> A`, pass order is reversed, `::(null);`,
  `::null;`, and `::null();` all split passes, and reverse normalization
  uses the parenthesized form of `NFD (NFC)` directives.
- Reverse global filters (`:: (set) ;`) are compiled; filtered transforms
  run their passes and normalization per input run, matching ICU's
  compound-filter behavior.
- Normalization and case directives between rule sections compile to
  per-pass operations (CJTR v18): the engine normalizes or case-maps the
  intermediate text before the following pass, matching ICU's compound
  steps. Leading and trailing directives become the pre-/post-normalization
  and final case instead.
- Transforms with an input filter run the whole compound (normalization,
  case, and rules) inside each filtered input run; text outside the filter
  passes through unchanged, matching ICU's filter scoping.
- Property classes accept long general-category names
  (`[:Uppercase_Letter:]`, `[:Mark:]`), binary approximations
  (`Cased`, `Case_Ignorable`, `Soft_Dotted`, `Ideographic`,
  `Logical_Order_Exception`), ISO 15924 script aliases (`Cyrl`,
  `Sinh`, `Cher`, ...), Unicode blocks (`Block=Arabic`, `Block=Thaana`),
  and nested negated classes/properties
  (`[[:^ccc=0:] & [:^ccc=230:]]`, `[^[:L:][:M:][:N:]]`).
- Source quantifiers are greedy, matching ICU's regex behavior
  (`X?`, `X*`, `X+` try the longest repetition first).
- Class variables are expanded textually before `{...}` string splitting,
  so strings nested inside a variable's class survive; hidden alternatives
  (a prefix already matched by an earlier context-free rule) are dropped
  like ICU's masked-rule handling.
- `und_FONIPA-ar` and `und_FONIPA-fa` compile and pass their PyICU
  fixtures (280 cases each).

Verification commands:

```sh
TRAE_ZIG_GUARD_DISABLED=1 zig test src/root.zig --test-filter "transliterate"
python3 tools/unicode/verify_committed.py
```

## 1. General segment/pipeline engine

The v19 step program covers arbitrary `::` sequences and interleaves rule
sections with steps. Remaining gaps:

- Reverse compilation of rule files with steps is implemented: the step
  order is reversed, rule sections map through the reverse pass numbering,
  and transform references keep their forward step (CLDR's bidirectional
  files use the parenthesized form only through ICU's inverse API).
  `Bopo-Latn` now runs the tone step and converts zhuyin tones to numeric
  pinyin (`ㄅㄠˇ` → `bao3`).
- `Katakana-Latin-BGN` uses the native katakana builder, which applies its
  own halfwidth conversion instead of the `::[set] Halfwidth-Fullwidth;`
  step.
- Pipelines whose components are not compiled (for example
  `es_FONIPA-ja`, whose `und_FONIPA-ja` component is not part of CLDR 48).

## 2. ICU rule specificity / hidden-rule ordering

ICU rejects a rule hidden by an earlier more general rule and gives
context-specific rules precedence when both match. A naive
"context entries first" sort regresses Armenian, Spanish, and Kirghiz,
so the real specificity model is still needed.

Known failing transforms (PyICU differential fixtures): none. Every
compiled transform passes its fixture; the remaining gaps are transforms
that are not compiled yet (see section 1).

`Greek-Latin`, `Latin-Greek`, `Hebrew-Latin`, `Latin-Hebrew`,
`ug-ug_FONIPA`, and `Maldivian-Latin/BGN` pass their PyICU fixtures
after output-context stripping, nested-context order fixes, insertion
rules merged into the main rule-order scan, repeated negated source groups
with capture, numeric `ccc=` values, and the context builder for
`ug-ug_FONIPA`. `Bopo-Latn` and `zh_Latn_PINYIN-ru` pass after the Pinyin
tone engines and per-pass normalization were compiled. `nl-Title` is
implemented as a named engine on top of Any-Title plus the Dutch `IJ`
digraph fix.

Embedded case calls (`&Any-Lower($1)` / `&Any-Upper($1)`) are compiled;
`az-Title`, `el-Title`, `lt-Title`, and `tr-Title` pass their fixtures.
`nl-Title` still needs Word_Break property classes (`[:WB=ALetter:]` and
friends) plus a real `Any-Title` step. General embedded transform calls
(`&SomeTransform($1)`) remain unsupported.

## 3. Filtered compound steps

Property-based input filters (`:: [:Ethiopic:] ;`,
`[[:Arabic:][:Block=Arabic:]...]`) compile, including nested negated
classes and properties. Filtered steps (`::[set] transform();`,
`::[set] nfkc;`) are compiled into SET_FILTER operations that scope the
following compound steps; a rule segment resets the filter, matching ICU.

## 4. Pinyin tone placement

Resolved: `Latin-NumericPinyin` and `NumericPinyin-Latin` are named
engines, and `Latin-Bopomofo` runs the compound
`::Latin-NumericPinyin(NumericPinyin-Latin);` step as the forward named
engine. `Bopo-Latn` runs the same step in its reverse compound, matching
ICU's precompiled CLDR data.

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
  `Han-Spacedhan`, `pl/ro/sk_FONIPA-ja`, `ja_Latn-ko`, `ru-zh`, and the
  `X-chr` / `X-ja` / `X-am` pipelines pass their PyICU fixtures.
- `Latin-NumericPinyin` and `NumericPinyin-Latin` are implemented as named
  engines (tone-mark placement and tone-digit movement) and pass their
  fixtures.
- `Latin-Bopomofo` and `Bopo-Latn` compile and pass their fixtures.
  `zh_Latn_PINYIN-ru` passes its PyICU fixture now that mid-rule
  normalization directives normalize the intermediate text before the
  following pass (the Pinyin tone pass NFD-decomposes, removes tone marks,
  then NFC-recomposes before the syllabify and mapping passes).
- All 21 `X-chr` pipelines pass their PyICU fixtures. The remaining
  `my/pl/sat/sk/xh/zu/hy_AREVMDA-chr` pipelines needed the ISO 15924
  `sc=Cher` alias so `und_FONIPA-chr`'s negated
  `[^[:sc=Cher:][tone marks]]` cleanup rule compiles and removes leftover
  tie bars.
- `dsb-dsb_FONIPA` passes after mid-rule normalization directives were
  compiled as per-pass normalization steps and the global filter was moved
  to the first non-empty pass.
- `kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, and `zu-am` pass their
  PyICU pipeline fixtures.

## 6. Hex transform divergence

`Hex-Any` decodes `\uXXXX`, `\UXXXXXXXX`, and `\x{...}`. ICU also emits
lone surrogates for inputs such as `\uD800`; the UTF-8 API here cannot
represent them, so such sequences pass through unchanged.

`Any-Name` encodes named scalars as `\N{NAME}` and synthesizes
`<control-XXXX>`, `<private use area-XXXX>`, and `<unassigned-XXXX>`
names like ICU. Other unnamed categories still fall back to hex escapes.
