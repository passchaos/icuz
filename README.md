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
- Runtime ICU break rules (`break_rules.compileAlloc`): `$set` variables,
  UnicodeSets, `.`, grouping with `|` alternation, `?`/`*`/`+`
  quantifiers, `/` lookahead, `{status}` tags, reverse-rule skipping,
  longest-match boundaries, and ICU's single-code-point fallback,
  validated by a 25-case PyICU `RuleBasedBreakIterator` fixture.
- UAX #50 vertical orientation.
- Unicode 17 Arabic joining properties and the joining state machine.
- Character names and aliases, including algorithmic CJK/Tangut/Egyptian/
  Khitan/Nushu names and UAX #44 loose name lookup.
- UnicodeSet range/property construction, union/intersection/difference/
  complement, `containsAll`/`containsNone`/`containsSome`, pattern
  round-tripping, and a practical `\p{...}`/`[a-z]` pattern parser,
  validated by a 610-case PyICU range differential fixture.
- CLDR 48 root collation (UCA 17.0.0) with NFD preprocessing, contiguous and
  discontiguous contractions, implicit weights, non-ignorable/shifted variable
  weighting, numeric collation (`a2` before `a10`, leading zeros ignored,
  digits from any numbering system compared by value), a separate case
  level with caseFirst interaction, identical strength with per-code-point
  decomposition tie-breaking, sort keys, and comparison, validated by a
  79-case ICU C API differential fixture.
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
  formatting for 111 locales, with locale symbols, grouping, fraction-digit
  options, all 307 CLDR currencies with locale-specific symbols/names/codes
  and currency-specific fraction digits, accounting parentheses, short/long
  compact notation, and ICU number skeletons (fraction and significant
  precision including `precision-increment/` decimal increments, sign
  modes, integer width with truncation, grouping modes, scale,
  percent/permille units, currency unit widths, compact significant-digit
  precision, scientific exponent widths, engineering notation, compact
  currency with ICU's short-pattern and sign placement, and measure-unit
  skeletons including compact units and ICU's compact plural-operand
  rounding). Number range formatting (`formatRangeAlloc`)
  follows ICU's range infixes, identity fallbacks, approximately markers,
  and affix-collapse heuristics for 87 locales. Currency output is
  validated against a 1,080-case PyICU fixture, skeleton output against a
  2,520-case ICU C API fixture, and ranges against a 460-case ICU C API
  fixture.
- CLDR 48 Gregorian date/time formatting for 87 locales, including localized
  month/day names, date/time styles, custom patterns, ICU date/time
  skeletons (`yMMMd`, `Hm`, combined date+time skeletons) resolved from
  CLDR availableFormats with canonical field ordering, width adjustment,
  and date/time split fallbacks, and Unix timestamp conversion. Skeleton
  output is validated against an 80-case PyICU fixture.
- Non-Gregorian calendar conversion and formatting for Buddhist, Japanese,
  ROC, Islamic civil/tbla/umalqura, Hebrew, Chinese, Persian, Indian,
  Coptic, Ethiopic, Ethiopic Amete Alem, and ISO-8601 calendars, following
  ICU's arithmetic and month tables with CLDR 48 month names (including
  Hebrew leap-year months and Chinese leap-month patterns), era names, and
  date patterns (including Japanese gannen). The Chinese lunisolar table
  covers 1850-2150 with cycle era, leap month, and month-length data.
  Validated by a 24,645-case conversion fixture and a 12,888-case PyICU
  formatting fixture.
- CLDR 48 locale display names for 87 locales: language, script, region,
  and variant names, locale display composition, and likely-subtags
  maximization, validated by 329 display-name and 48 likely-subtag PyICU
  conformance cases.
- Numbering system selection for number and date formatting across 78 CLDR
  numeric systems (latn, arab, arabext, thai, deva, beng, hanidec,
  fullwide, and others) through `@numbers=`/`-u-nu-` locale keywords or an
  explicit option, with per-system digits and ICU-compatible symbol
  fallback. Validated by a 618-case PyICU fixture.
- CLDR 48 duration formatting for 87 locales with long, short, narrow, and
  numeric styles: locale-specific numeric patterns (h:mm:ss, m:ss, and
  overrides) plus unit and unit-list composition for hours, minutes, and
  seconds with plural selection. Validated by a 312-case PyICU fixture.
- CLDR 48 date and time interval formatting for 87 locales, using ICU's
  repeated-field pattern splitting, greatest-difference selection,
  single-date collapse, hour-cycle-aware time skeletons, and locale
  fallback formatting, validated by a 160-case PyICU fixture. Skeleton
  intervals (`formatSkeletonIntervalAlloc`) follow ICU DateIntervalFormat
  semantics: canonical skeleton best-match resolution, interval-pattern
  width adjustment, date-once time-range composition, and fallback
  formatting, validated by a 5,060-case PyICU fixture across 23 skeletons
  and 20 locales.
- IANA tzdata 2026e time zones for 597 IDs, including backward link names,
  with transition-based UTC offset and daylight resolution from 1970 through
  2100, local/UTC conversion, and zone-aware Unix timestamp formatting.
- CLDR 48 localized time zone names for 87 locales: specific and generic
  zone/metazone names, exemplar cities, region and localized GMT formats,
  and the `z`, `v`, `V`, `O`, `Z`, and `X`/`x` pattern fields, including
  standard/daylight selection, primary-zone location fallbacks, and
  metazone period resolution.
- Differential fixtures validate 15,883 time zone offset/daylight cases
  against an independent TZif reader and 1,792 localized name cases against
  PyICU.
- CLDR 48 list formatting for 87 locales, including and/or and unit list
  styles with narrow/short variants.
- CLDR 48 relative time for 87 locales, including yesterday/today/tomorrow
  text and future/past plural patterns.
- CLDR 48 unit formatting for 87 locales and all 231 CLDR units across
  length, mass, temperature, speed, area, volume, duration, digital, energy,
  power, pressure, frequency, angle, light, electricity, torque, and
  concentration, with long and short forms, CLDR unit identifiers, and a
  3,063-case PyICU differential conformance fixture.
- CLDR 48 RBNF rule-based number formatting for 112 locales, covering
  spellout and ordinal rule sets with negative, decimal, fraction, and
  optional rule branches, plural substitutions, Indian grouping, fraction
  rule sets, and an 6,840-case PyICU differential conformance fixture.
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
  Malayalam/Latin/Tamil, Bengali/Devanagari/Gujarati/Gurmukhi/
  Kannada/Malayalam/Oriya/Tamil/Telugu-InterIndic, chr-chr_FONIPA, zu-zu_FONIPA,
  Hiragana-Katakana, Persian-Latin-BGN, nv-nv_FONIPA, si-si_FONIPA,
  es-es_FONIPA, xh-xh_FONIPA, vec-vec_FONIPA, ro-ro_FONIPA,
  Arabic-Latin-BGN, Armenian-Latin-BGN, Thaana-Latin, Syriac-Latin,
  CanadianAboriginal-Latin, tr-Lower, az-Lower, tr-Upper, az-Upper,
  el-Lower, el-Upper, lt-Lower, lt-Upper, Korean-Latin-BGN, Kirghiz-Latin-BGN, Latin-Armenian,
  Azerbaijani-Latin-BGN, am-am_FONIPA, am_FONIPA-am, Latin-Cyrillic,
  Latin-Arabic, Latin-Syriac, Armenian-Latin, Greek-Latin, Latin-Greek,
  Hebrew-Latin, Latin-Thaana,
  Latin-CanadianAboriginal, de-ASCII, Any-Publishing,
  Katakana-Hiragana, Pashto-Latin-BGN, Simplified-Traditional,
  Traditional-Simplified, Hans-Hant, Hant-Hans, the Ethiopic geminate
  pipelines, the `kk-am`, `my-am`, `ro-am`, `si-am`, `xh-am`, and `zu-am`
  FONIPA-to-Amharic pipelines, the `cs-ja`, `es-ja`, `es_419-am`, and
  `es_419-ja` composed pipelines, and
  NFC/NFD/NFKC/NFKD transforms, plus the `Hex-Any` / `Any-Hex` escape
  transforms and the `Name-Any` / `Any-Name` character-name transforms.
  Three hundred forty-eight
  transforms are compiled (including 142 auto-discovered CLDR pipelines);
  thirty ship official CLDR conformance
  fixtures, and two hundred eighty-two (Cyrillic-Latin, Arabic-Latin, InterIndic-Arabic,
  the ten InterIndic script transforms, the nine script-to-InterIndic
  transforms, Cherokee FONIPA, Zulu FONIPA,
  Navajo FONIPA, Sinhala FONIPA, Spanish FONIPA, Xhosa FONIPA,
  Venetian FONIPA, Romanian FONIPA, Arabic-Latin-BGN, Armenian-Latin-BGN,
  Thaana-Latin, Syriac-Latin, CanadianAboriginal-Latin, the six
  case transforms (including tr/az Upper), Korean-Latin-BGN,
  Kirghiz-Latin-BGN, Latin-Armenian, de-ASCII, Any-Publishing,
  Katakana-Hiragana,
  Azerbaijani-Latin-BGN, am-am_FONIPA, am_FONIPA-am, Latin-Cyrillic,
  Latin-Arabic, Latin-Syriac, Armenian-Latin, Greek-Latin, Latin-Greek,
  Hebrew-Latin, Latin-Thaana,
  Latin-CanadianAboriginal, Georgian-Latin, Latin-Georgian,
  Halfwidth-Fullwidth, Fullwidth-Halfwidth, a Kazakh FONIPA validation
  fixture, Hiragana-Katakana,
  the six FONIPA-to-Amharic pipelines,
  and Persian-Latin-BGN) ship ICU
  differential fixtures generated with PyICU, including reverse-direction
  transforms. Transforms can be selected by CLDR name through
  `transliterateByNameAlloc`; ICU's `NFC`, `NFD`, `NFKC`, `NFKD`,
  `Any-Lower`, `Any-Upper`, `Any-Title`, `nl-Title`,
  `Latin-NumericPinyin`, and `NumericPinyin-Latin` names dispatch to the
  normalization, case, and Pinyin tone engines. `transformCount`, `transformNameAt`,
  and `hasTransform` expose the compiled transform list. The table compiler expands character classes,
  Unicode properties, set operations, multi-codepoint set elements,
  multi-element prefix/suffix contexts with word-boundary handling, optional
  and repeated context elements (including optional groups such as
  `($class)?`), whole-source and embedded capture groups
  (`$1`), greedy source quantifier expansion (`X?`, `X*`, `X+`) and native
  repeated-class
  sources, empty-source insertion rules, text-boundary class anchors, output
  cursor reprocessing (`|`), output post-normalization, multi-definition
  variable lines (including multi-line classes), quoted and ignored
  whitespace, output-aware rule contexts, trailing and leading transform
  references (`::Latin-ASCII;`, multi-step pipelines), context variables
  that expand to
  element sequences, `*`/`+` quantifiers on variable references, mid-target
  output cursors, ICU input filters (`:: [set] ;`),
  trailing `::Any-Lower;`/`::Any-Upper;` case steps, `ccc=`, long and short
  general-category names, and script property classes (including ISO 15924
  aliases), ICU rule-order priority, reverse-direction compilation (swapped
  `←`/`↔` rules with reversed pass order and inverse normalization steps),
  reverse global filters (`:: (set) ;`) with per-run normalization,
  repeated-sequence collapse rules (`($var) $var+ -> $1`),
  embedded case calls (`&Any-Lower($1)`, `&Any-Upper($1)`),
  negated source classes and the `.` wildcard, repeated negated source
  groups with capture (`([^ccc=0]*)$1`),
  ordered step programs (`::NFD;`, `::Transform;`, `::Lower;`,
  `::NFC;`) for multi-component pipelines,
  XML
  comment stripping, `::Null;`/`::(null);`/`::null();` multi-pass
  pipelines, and mid-rule normalization directives that split passes.
- Runtime ICU-rule transliteration engine (`compileRulesAlloc` /
  `applyRulesAlloc`): forward `createFromRules` rules with comments,
  string and UnicodeSet `$variables`, `::Null;` and `::[set];` directives,
  `ante { input } post > output;` context, sets, `.` wildcard, grouping,
  `?`/`*`/`+` quantifiers, capture groups with `$1`-`$N` output references
  (last-repetition semantics for quantified groups, context captures
  included), `&Transform($n)` function calls, output string variables,
  `|` cursor repositioning, quoted literals and escapes, and
  reverse-direction compilation via `compileRulesDirectionAlloc` (simple
  swapped rules without captures or context), validated by an 81-case
  PyICU differential fixture.
- Embedded, version-pinned generated data plus conformance fixtures.

## Non-goals for 0.1

`icuz` is not a drop-in ICU replacement. Its transliteration support is a
compiled rule-table engine covering the constructs listed above plus a
runtime ICU-rule interpreter: reverse rules with captures or context and
embedded `::Transform;` pipeline calls in user rule text are not yet
interpreted at runtime. Regular expressions and display/layout
tailoring are also out of scope. Collation supports root ordering plus CLDR
standard and common
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
