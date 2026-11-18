# icuz

`icuz` is a pure-Zig Unicode Character Database and UAX algorithm library. It
provides the Unicode primitives that text, font, editor, and inference stacks
need without pulling in a font or layout engine.

## Scope

- Unicode 17.0 scalar properties: full `General_Category`, 58 binary
  properties including `ID_Start`/`ID_Continue`/`XID_*`, `Case_Ignorable`,
  `Cased`, `Grapheme_Base`/`Grapheme_Extend`, pattern syntax, identifier and
  emoji properties, Script, Script_Extensions, and variation selectors.
- General_Category, Script, and binary-property alias resolution for
  `\p{...}`-style consumers.
- UAX #9 bidirectional paragraph resolution.
- UAX #14 line-break opportunities.
- UAX #15 normalization: NFC, NFD, NFKC, and NFKD, with `normalizeFormInto`,
  `spanQuickCheckYes`, code-point and UTF-16 forms, and a memory-bounded
  streaming `Normalizer` for chunked input.
- Simple lower/upper/title mappings, full case folding, and full
  lower/upper/title mappings with `Final_Sigma`, Turkic, and Lithuanian
  context rules.
- UAX #24 script runs.
- UAX #29 grapheme, word, and sentence boundaries.
- ICU break dictionaries for Thai, Lao, Khmer, Burmese, and CJK word
  segmentation, with ICU's candidate-lookahead algorithm (including Thai
  elision/repetition suffixes) for the Southeast Asian scripts and cost-based
  Viterbi plus the Katakana-run heuristic for CJK. Selected through
  `wordSegmentsWithDictionaries`; the default `wordSegments` remains the
  UAX #29 rule-based iterator. A 313-case fixture generated with ICU's
  `Intl.Segmenter` covers all five dictionaries.
- UAX #50 vertical orientation.
- Unicode 17 Arabic joining properties and the joining state machine.
- Character names and aliases, including algorithmic CJK/Tangut/Egyptian/
  Khitan/Nushu names and UAX #44 loose name lookup.
- UnicodeSet range/property construction, set algebra, and a practical
  `\p{...}`/`[a-z]` pattern parser.
- CLDR 48 root collation (UCA 17.0.0) with NFD preprocessing, contiguous and
  discontiguous contractions, implicit weights, non-ignorable/shifted variable
  weighting, sort keys, and comparison.
- CLDR 48 locale collation tailorings for 147 locale/type entries, including
  standard, search, phonebook, traditional, eor, pinyin, stroke, zhuyin, and
  unihan variants. Applied through `Options.locale` and `Options.collation`
  with automatic language and standard-type fallback. Locale `caseFirst`
  settings (for example Danish and Maltese uppercase-first), backwards
  secondary accent ordering (Canadian French), and parametric script
  reordering (Russian, Greek, Hebrew, Arabic, Indic, Thai, Korean, Chinese
  pinyin/stroke/zhuyin/unihan, German EOR, and others) are compiled from the
  CLDR settings; `Options.case_first` and `Options.backwards_secondary`
  override them per call. Japanese private-kana and Korean searchjl
  tailorings are skipped.
- UTS #46 IDNA 16.0.0: ToASCII/ToUnicode, NFC mapping, punycode, RFC 5893
  bidi checks, ContextJ/ContextO, and official conformance fixtures.
- CLDR 48 cardinal plural rules for 224 locales and ordinal plural rules for
  110 locales, including both CLDR sample conformance fixtures.
- CLDR 48 decimal, percent, currency, scientific, and compact number
  formatting for 30 locales, with locale symbols, grouping, fraction-digit
  options, 25 currencies with locale-specific symbols/names/codes and
  currency-specific fraction digits, accounting parentheses, short/long
  compact notation, and ICU-style number skeletons.
- CLDR 48 Gregorian date/time formatting for 30 locales, including localized
  month/day names, date/time styles, custom patterns, and Unix timestamp
  conversion.
- CLDR 48 list formatting for 30 locales, including and/or and unit list
  styles with narrow/short variants.
- CLDR 48 relative time for 30 locales, including yesterday/today/tomorrow
  text and future/past plural patterns.
- CLDR 48 unit formatting for 30 locales and 60 units across length, mass,
  temperature, speed, area, volume, duration, digital, energy, power,
  pressure, frequency, angle, and concentration, with long and short forms.
- ICU-style message formatting with positional/named arguments, plural,
  selectordinal, and select branches, `#` substitution, number/date arguments,
  and quoting.
- UTF-16 validation, iteration, and UTF-8/UTF-16 conversion helpers.
- Charset conversion for UTF-8/16/32, ASCII, Latin-1, 28 legacy single-byte
  encodings, GBK/GB18030, Big5, EUC-JP, ISO-2022-JP, Shift_JIS, and EUC-KR,
  with strict/replace/ignore error modes and ICU-style label resolution.
- CLDR 48 transliteration for Latin-ASCII (NFD, mark removal, NFC, 844 mapping
  rules), Fullwidth-Halfwidth, Halfwidth-Fullwidth, Georgian-Latin,
  Georgian-Latin-BGN (1981), Hebrew-Latin-BGN, Russian-Latin-BGN,
  Greek-Latin-BGN, Katakana-Latin-BGN (including halfwidth-katakana
  pre-normalization), Latin-Georgian, Lao-Latin, Kazakh-FONIPA,
  Uyghur-FONIPA, Amharic-Latin-BGN, Kazakh-Latin-BGN, Turkmen-Latin-BGN,
  Ukrainian-Latin-BGN, Belarusian-Latin-BGN, Mongolian-Latin-BGN,
  Bulgarian-Latin-BGN, Macedonian-Latin-BGN, Serbian-Latin-BGN,
  InterIndic-ur, sgw-Ethi-t-und-ethi, am-Ethi-t-am-ethi-m0-geminate,
  und-Ethi-t-und-latn-m0-aethiopi/beta_metsehaf/ies-jes-1964/lambdin,
  byn-Ethi-t-byn-latn-m0-tekie-alibekit/xaleget, si-si_Latn,
  my-my_FONIPA, Cyrillic-Latin, Arabic-Latin, InterIndic-Arabic,
  InterIndic-Devanagari/Bengali/Gurmukhi/Gujarati/Oriya/Telugu/Kannada/
  Malayalam/Latin/Tamil, chr-chr_FONIPA, zu-zu_FONIPA,
  Hiragana-Katakana, Persian-Latin-BGN, nv-nv_FONIPA, si-si_FONIPA,
  es-es_FONIPA, xh-xh_FONIPA, vec-vec_FONIPA, ro-ro_FONIPA,
  Arabic-Latin-BGN, Armenian-Latin-BGN, Thaana-Latin, Syriac-Latin,
  CanadianAboriginal-Latin, tr-Lower, az-Lower, el-Lower, el-Upper,
  lt-Lower, lt-Upper, Korean-Latin-BGN, Kirghiz-Latin-BGN, Latin-Armenian,
  Azerbaijani-Latin-BGN, Latin-Cyrillic, Latin-Thaana,
  Latin-CanadianAboriginal, and
  NFC/NFD/NFKC/NFKD transforms. Seventy-four
  transforms are compiled; twenty-four ship official CLDR conformance
  fixtures, and forty-five (Cyrillic-Latin, Arabic-Latin, InterIndic-Arabic,
  the ten InterIndic script transforms, Cherokee FONIPA, Zulu FONIPA,
  Navajo FONIPA, Sinhala FONIPA, Spanish FONIPA, Xhosa FONIPA,
  Venetian FONIPA, Romanian FONIPA, Arabic-Latin-BGN, Armenian-Latin-BGN,
  Thaana-Latin, Syriac-Latin, CanadianAboriginal-Latin, the six
  case transforms, Korean-Latin-BGN, Kirghiz-Latin-BGN, Latin-Armenian,
  Azerbaijani-Latin-BGN, Latin-Cyrillic, Latin-Thaana,
  Latin-CanadianAboriginal, Georgian-Latin, Latin-Georgian,
  Halfwidth-Fullwidth, a Kazakh FONIPA validation fixture, Hiragana-Katakana,
  and Persian-Latin-BGN) ship ICU
  differential fixtures generated with PyICU, including reverse-direction
  transforms. Transforms can be selected by CLDR name through
  `transliterateByNameAlloc`. The table compiler expands character classes,
  Unicode properties, set operations, multi-codepoint set elements,
  multi-element prefix/suffix contexts with word-boundary handling, optional
  and repeated context elements, whole-source and embedded capture groups
  (`$1`), source quantifier expansion (`X*`, `X+`) and native repeated-class
  sources, empty-source insertion rules, text-boundary class anchors, output
  cursor reprocessing (`|`), output post-normalization, multi-definition
  variable lines (including multi-line classes), quoted and ignored
  whitespace, output-aware rule contexts, context variables that expand to
  element sequences, `*`/`+` quantifiers on variable references, mid-target
  output cursors, ICU input filters (`:: [set] ;`),
  trailing `::Any-Lower;`/`::Any-Upper;` case steps, `ccc=` and two-letter
  general-category and script property classes, ICU rule-order priority,
  XML
  comment stripping, and `::Null;` multi-pass pipelines.
- Embedded, version-pinned generated data plus conformance fixtures.

## Non-goals for 0.1

`icuz` is not a drop-in ICU replacement. It does not yet provide a general
ICU-rule transliteration engine, regular expressions, or display/layout
tailoring. Collation supports root ordering plus CLDR standard and common
non-standard tailorings, including locale `caseFirst`, backwards secondary
ordering, and parametric script reordering. Consumers that need those
features should build them on top of `icuz` or use a dedicated library.

Cangjie-specific shaping, editor word selection, Latin display composition,
and OpenType script-tag policy deliberately live in the consuming libraries,
not in `icuz`.

## Build

```sh
zig build test
zig build unicode-verify
zig build bench
```

`unicode-verify` checks committed blob headers, layouts, hashes, generated
sources, generator pins, and provenance without requiring an external UCD
checkout.

`bench` builds a `ReleaseFast` microbenchmark executable and reports the best
of several trials for scalar properties, segmentation, normalization, and case
mapping. Run it on an idle machine when comparing changes; the harness prints
ns/op for scalar lookups and ns/byte plus MB/s for text pipelines.

## Performance notes

Scalar properties use deduplicated two-stage page tables: a `u16` page index
plus one packed payload word per scalar. `General_Category` and the binary
properties share one `u16` word, while `Canonical_Combining_Class` and the four
normalization quick-check forms use compact byte tables. ASCII is materialized
at compile time, so prose lookups avoid both the page indirection and the
generated-data cache footprint.

Normalization and case mapping also have direct ASCII paths. Pure-ASCII text is
already normalized in every form and can be checked with a word-at-a-time scan;
ASCII case conversion is a single byte loop instead of a generated record
search.

## Data provenance

Generated tables and conformance fixtures contain derived Unicode data. See
`THIRD_PARTY_NOTICES.md` and `licenses/Unicode-3.0.txt`.
