# icuz

`icuz` is a pure-Zig Unicode Character Database and UAX algorithm library. It
provides the Unicode primitives that text, font, editor, and inference stacks
need without pulling in a font or layout engine.

## Scope

- Unicode 17.0 scalar properties: full `General_Category`, 58 binary
  properties including `ID_Start`/`ID_Continue`/`XID_*`, `Case_Ignorable`,
  `Cased`, `Grapheme_Base`/`Grapheme_Extend`, pattern syntax, identifier and
  emoji properties, Script, Script_Extensions, and variation selectors.
  `Numeric_Value` and `Numeric_Type` (`numericValue`, `numericType`,
  `digitValue`) cover all 2,023 numeric scalars as exact rationals,
  including Han numerals and fractions. `Age` (`ageOf`, `ageVersion`)
  reports the Unicode version that first assigned each scalar.
- General_Category, Script, and binary-property alias resolution for
  `\p{...}`-style consumers.
- UAX #9 bidirectional paragraph resolution. CLDR script metadata provides
  right-to-left script detection (`scriptIsRightToLeft`) and locale-level
  checks (`localeIsRightToLeft`, `Locale.isRightToLeft`) that follow likely
  subtags (for example `pa-PK` resolves to Arabic script).
  `BidiParagraph.reorderAlloc` reproduces ICU `ubidi_writeReordered` for
  logical-to-visual output, including mirroring, bidi-control removal,
  base-combining preservation, output reversal, and explicit embedding
  controls, validated by a 900-case ICU 78 differential fixture.
  `bidiTransformAlloc` implements all 16 ICU `ubiditransform` schemes,
  including inverse visual-to-logical resolution, runs-only conversion,
  Arabic shaping, mirroring, and default base-direction resolution,
  validated by a 5,376-case ICU 78 differential fixture.
- UAX #14 line-break opportunities.
- UAX #15 normalization: NFC, NFD, NFKC, and NFKD, with `normalizeFormInto`,
  `spanQuickCheckYes`, code-point and UTF-16 forms, and a memory-bounded
  streaming `Normalizer` for chunked input. NFKC_Casefold
  (`nfkcCasefoldAlloc`) and NFKC_Simple_Casefold
  (`nfkcSimpleCasefoldAlloc`) apply the derived NFKC_CF and NFKC_SCF
  mappings and the required final NFC pass, with an ASCII fast path and the
  complete Unicode 17 mapping tables. Scalar helpers (`composePair`,
  `decompositionFor`, `compatibilityDecompositionFor`, `combiningClass`)
  expose the underlying normalization tables. Normalizer2 boundary and
  incremental helpers (`isNormalizationInert`,
  `hasNormalizationBoundaryBefore`, `hasNormalizationBoundaryAfter`,
  `appendNormalizedAlloc`, `normalizeSecondAndAppendAlloc`) use a generated
  42,845-record table that matches ICU's per-scalar flags.
- Simple lower/upper/title mappings, full case folding, and full
  lower/upper/title mappings with `Final_Sigma`, Turkic, and Lithuanian
  context rules. The `Edits` recorder (`fullLowerWithEditsAlloc`,
  `fullUpperWithEditsAlloc`, `fullTitleWithEditsAlloc`,
  `caseFoldWithEditsAlloc`) tracks unchanged and
  replaced source spans and maps source/destination indices like ICU's
  `CaseMap` with `Edits`.
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
- ICU-compatible Arabic letter shaping (`shapeArabicAlloc`): the full
  `U_SHAPE_*` option matrix, including isolated/initial/medial/final
  presentation forms, Lam-Alef ligatures and their space placement,
  tashkeel positioning/removal, seen-tail and yeh-hamza two-cell forms,
  Arabic-Indic digit conversion with bidi context, visual-order processing,
  presentation-form preservation, and aggregate tashkeel. Output matches
  ICU's `u_shapeArabic` across a 44,412-case PyICU differential fixture.
  Unlike ICU, a resize pass always returns the compacted length; ICU resets
  the length to the source length when a later space-placement pass runs,
  which can expose U+0000 padding slots.
- Character names and aliases, including algorithmic CJK/Tangut/Egyptian/
  Khitan/Nushu names and UAX #44 loose name lookup.
- UnicodeSet range/property construction, multi-code-point string elements
  (`{abc}`, `addString`, `containsString`), case closure (`closeOver` with
  simple/full case-insensitive and add-case-mappings modes),
  ICU-style `span`/`spanBack` scanning with longest string-element matches,
  union/intersection/difference/complement (also exposed as
  `addAll`/`retainAll`/`removeAll`) and `removeAllStrings`,
  `containsAll`/`containsNone`/`containsSome`, an ICU-style
  `UnicodeSetIterator` (code points in sorted order, then strings; range
  iteration and `skipToStrings`), pattern
  round-tripping, and a practical `\p{...}`/`[a-z]` pattern parser with
  binary, general-category, script, script-extension, `Age`,
  `Numeric_Type`, `Block`, `Line_Break`, `Word_Break`, `Sentence_Break`,
  and `Grapheme_Cluster_Break` properties, validated by a 1,962-case
  PyICU range differential fixture. Block and break-property lookups are
  also exposed directly (`blockForCodepoint`, `blockFromName`,
  `lineBreakClass`, `wordBreakClass`, `sentenceBreakClass`,
  `graphemeBreakClass`) with loose ICU-style name and alias matching.
- CLDR 48 root collation (UCA 17.0.0) with NFD preprocessing, contiguous and
  discontiguous contractions, implicit weights, non-ignorable/shifted variable
  weighting, numeric collation (`a2` before `a10`, leading zeros ignored,
  digits from any numbering system compared by value), a separate case
  level with caseFirst interaction, identical strength with per-code-point
  decomposition tie-breaking, sort keys, comparison, level-by-level sort-key
  merging (`mergeSortKeysAlloc`), level bounds (`sortKeyBoundAlloc`), and
  collation-element iteration (`collationElementsAlloc`, like ICU's
  `ucol_openElements`), validated by a 79-case ICU C API differential fixture.
- CLDR 48 locale collation tailorings for 147 locale/type entries, including
  standard, search, phonebook, traditional, eor, pinyin, stroke, zhuyin, and
  unihan variants. Applied through `Options.locale` and `Options.collation`
  with automatic language and standard-type fallback, and CLDR
  `defaultCollation` resolution (`zh` and `zh-Hans` use pinyin; `zh-Hant`,
  `zh-TW`, `zh-HK`, and `zh-MO` use stroke). Locale `caseFirst`
  settings (for example Danish and Maltese uppercase-first), backwards
  secondary accent ordering (Canadian French), and parametric script
  reordering (Russian, Greek, Hebrew, Arabic, Indic, Thai, Korean, Chinese
  pinyin/stroke/zhuyin/unihan, German EOR, and others) are compiled from the
  CLDR settings; `Options.case_first` and `Options.backwards_secondary`
  override them per call. Japanese private-kana and Korean searchjl
  tailorings are skipped.
- ICU-style `Collator` attributes (`getAttribute`/`setAttribute`):
  strength, alternate handling, case first, case level, French collation,
  numeric collation, and the `UColAttributeValue` constants, including
  tailoring-derived defaults.
- Locale-aware string search (`search.indexOf`, `search.lastIndexOf`,
  `search.Search`): finds the first or last
  substring whose collation key equals the pattern at a chosen strength, so
  primary-strength search ignores case and accents while tailored letters keep
  their locale weights; contraction prefixes and combining sequences are
  handled, and results match ICU usearch on the covered cases.
- UTS #46 IDNA 16.0.0: ToASCII/ToUnicode, NFC mapping, punycode, RFC 5893
  bidi checks, ContextJ/ContextO, and official conformance fixtures.
- UTS #39 confusable detection from the Unicode 17.0.0 security data:
  skeletons (NFD, prototype mapping, NFD, default-ignorable removal) and
  `areConfusable` with optional case folding, validated by a 6,603-case
  ICU 78 skeleton fixture; `isAllowedIdentifier` and `identifierAllowed`
  expose the Identifier_Status=Allowed set (1,649 ranges), and
  `restrictionLevel`/`isMixedScript` implement the six restriction levels
  over UTS #39 augmented script sets, and `hasMixedNumbers` detects mixed
  decimal number systems.
- ICU `uspoof`-compatible checker (`SpoofChecker`): configurable check
  bitmask, restriction-level thresholds, allowed-character sets,
  invisible-character, hidden-overlay, mixed-number, and char-limit checks,
  plus `areConfusable` bitmask classification (single/mixed/whole script),
  bidi-confusable skeletons and `areBidiConfusable` classification, and
  validated by a 943-case ICU 78 differential fixture.
- CLDR 48 cardinal plural rules for 224 locales and ordinal plural rules for
  110 locales, including both CLDR sample conformance fixtures, plus plural
  range selection (`pluralRangeCategory`) for 91 locales from
  `pluralRanges.xml`.
- CLDR 48 decimal, percent, currency, scientific, and compact number
  formatting for 111 locales, with locale symbols, grouping, fraction-digit
  options, all 307 CLDR currencies with locale-specific symbols/names/codes
  and currency-specific fraction digits (`currencyFractionDigits`) plus cash
  digits/rounding (`currencyCashFractionDigits`, `currencyCashRounding`),
  localized currency symbols/names (`currencySymbol`, `currencyName`),
  region/locale currency codes (`currencyCodeForRegion`,
  `currencyCodeForLocale`), CLDR currency spacing (the non-breaking space
  inserted between a symbol and an adjacent digit), cash rounding via
  `NumberOptions.cash`,
  accounting
  parentheses, short/long
  compact notation that keeps at least two significant digits of the scaled
  mantissa (1200 becomes `1.2K`) and selects plurals from the visible fraction
  digits and compact exponent, and ICU number skeletons (fraction and
  significant
  precision including `precision-increment/` decimal increments, all eight
  ICU `rounding-mode-*` modes (half-even, half-up, half-down, up, down,
  ceiling, floor, unnecessary), sign modes, integer width with truncation,
  grouping modes, scale,
  percent/permille units, currency unit widths, compact significant-digit
  precision, scientific exponent widths, engineering notation, compact
  currency with ICU's short-pattern and sign placement, and measure-unit
  skeletons including compact units and ICU's compact plural-operand
  rounding). Number range formatting (`formatRangeAlloc`)
  follows ICU's range infixes, identity fallbacks, approximately markers,
  affix-collapse heuristics for 108 locales, and unit ranges that share one
  unit pattern selected by the CLDR plural range category (for example
  Russian `1–2 дня`, `2–5 дней`), and currency-name ranges such as
  `1.00–2.00 US dollars`. Currency output is
  validated against a 3,060-case PyICU fixture, skeleton output against a
  2,520-case ICU C API fixture, and ranges against a 1,356-case ICU C API
  fixture. Localized number parsing (`parseFloat`, `parseFloatPrefix`,
  `parseInt`) accepts locale symbols, native digits, percent/permille
  scaling, currency affixes, accounting parentheses, and NaN/infinity,
  validated by a 600-case ICU parsing fixture across 30 locales.
  `formatNumberFieldsAlloc` reports sign, integer groups, grouping separators,
  decimal separator, fraction, currency, and percent spans for editor-style
  highlighting; `formatNumberSkeletonFieldsAlloc` does the same for skeletons
  and shifts the spans into unit patterns.
- CLDR 48 Gregorian date/time formatting for 108 locales, including localized
  month/day names, date/time styles, custom patterns, ICU date/time
  skeletons (`yMMMd`, `Hm`, combined date+time skeletons) resolved from
  CLDR availableFormats with canonical field ordering, width adjustment,
  and date/time split fallbacks, flexible day periods (`B`) and
  am/pm/noon/midnight (`b`) from CLDR dayPeriods rules and names,
  region-aware week-of-year/month fields (`w`, `W`, `Y`), `J`/`C` hour
  fields (fixed 0-23 and locale-preferred hour cycle), deprecated
  standalone-month `l`, milliseconds-in-day (`A`), day-of-week-in-month
  (`F`), modified Julian day (`g`), and Unix timestamp conversion. Skeleton
  output is validated against a 270-case PyICU fixture. Date/time parsing
  (`parsePattern`, `parseSkeleton`) consumes the same pattern syntax,
  including localized month, weekday, era, day-period, and quarter names,
  flexible day-period names (`B`), native digits, numeric zone offsets, and
  caller-supplied defaults for absent fields, validated by a 1,200-case ICU
  parsing fixture across 30 locales and eight patterns. Calendar arithmetic (`addDays`, `addMonths`,
  `addYears`, `fieldDifference`) matches ICU's clamping and whole-field
  semantics, and `formatPatternFieldsAlloc` reports the byte range of every
  expanded pattern field for editor-style highlighting. ICU
  `udat_getSymbols`-compatible accessors (`dateSymbolAt`,
  `dateSymbolCount`, `dateFirstDayOfWeek`, `dateMinimalDaysInFirstWeek`)
  expose era, month, weekday, quarter, and AM/PM names in wide,
  abbreviated, narrow, short, and stand-alone forms, validated by a
  2,251-record ICU 78 differential fixture.
- ICU `ucal`-compatible mutable calendar (`Calendar`): timezone-aware
  millisecond state, field get/set, `add`/`roll`, era/year/month/date and
  clock fields, DST-aware zone and DST offsets, and Gregorian, Buddhist,
  Japanese, ROC, ISO-8601, Islamic-umalqura, Persian, Indian, Coptic, and
  Ethiopic systems, including locale week data (`week_of_year`,
  `week_of_month`, `day_of_week_in_month`, `year_woy`, `dow_local`),
  validated by a 99-case ICU 78 differential fixture. Hebrew and Chinese
  field reads are validated; their mutation is read-only because their
  month-slot numbering differs from the CLDR-facing data.
- ICU `DateTimePatternGenerator` helpers: pattern-to-skeleton conversion
  (`datePatternSkeletonAlloc`), base-skeleton reduction
  (`dateBaseSkeletonAlloc`), and skeleton-driven field replacement
  (`replaceDateFieldTypesAlloc`, with a locale hour-cycle override), including
  quoted literals, canonical field ordering, duplicate-field resolution,
  minute-plus-fraction second insertion, and 12/24-hour day-period rules.
  Validated by a 1,885-case PyICU fixture.
- CLDR 48 default calendar selection (`defaultCalendarForRegion`,
  `defaultCalendarForLocale`): territory preferences from
  `calendarPreferenceData` resolved through likely subtags, skipping calendars
  this library cannot format (for example `fa` selects Persian and `th`
  selects Buddhist, while `ar-SA` selects Gregorian as in ICU). Skeleton
  formatting remains Gregorian; use the calendar-aware date APIs for the
  selected non-Gregorian calendar.
- Non-Gregorian calendar conversion and formatting for 108 locales (Buddhist, Japanese,
  ROC, Islamic civil/tbla/umalqura, Hebrew, Chinese, Persian, Indian,
  Coptic, Ethiopic, Ethiopic Amete Alem, and ISO-8601 calendars, following
  ICU's arithmetic and month tables with CLDR 48 month names (including
  Hebrew leap-year months and Chinese leap-month patterns), era names, and
  date patterns (including Japanese gannen). The Chinese lunisolar table
  covers 1850-2150 with cycle era, leap month, and month-length data.
  Validated by a 24,645-case conversion fixture and a 24,552-case PyICU
  formatting fixture.
- CLDR 48 locale display names for 108 locales: language, script, region,
  and variant names, locale display composition, and likely-subtags
  maximization and minimization (including ICU's favor-script minimization),
  validated by 1,022 display-name and 48
  likely-subtag PyICU conformance cases.
- ICU `uregion`-compatible region data (`regionFromCode`,
  `regionFromNumericCode`, `Region`): canonical region codes, ISO 3166
  alpha-3 and UN M.49 numeric aliases, deprecated-code canonicalization to
  preferred replacements, region types (world, continent, subcontinent,
  territory, grouping, deprecated, unknown), containment parents and
  children, transitive containment, and available-region enumeration,
  validated by a 138-case ICU 78 differential fixture.
- Generic `StringEnumeration` and typed `NumberFieldIterator` /
  `DateFieldIterator` for walking formatted field spans, matching ICU's
  enumeration and `UFieldPositionIterator` traversal model.
- ICU `ulocdata`-compatible locale data (`LocaleData`,
  `localeExemplarSetAlloc`, `localeMeasurementSystem`, `localePaperSize`):
  CLDR 48 exemplar sets (standard, auxiliary, index, and punctuation, with
  `USET_IGNORE_SPACE` and mark-string normalization), quotation delimiters,
  locale display patterns and separators, region-based measurement systems,
  and A4/US-Letter paper sizes, validated by a 936-case ICU 78 differential
  fixture.
- ICU `uloc` metadata helpers: character/line orientation and ISO 639-2 /
  ISO 3166 alpha-3 language and country codes (`localeIso3Language`,
  `localeIso3Country`), validated by an 86-case ICU 78 differential fixture.
- BCP 47 locale tag canonicalization (`canonicalizeLocaleAlloc`): case and
  separator normalization, CLDR 48 language, script, territory, and variant
  alias rules with multi-field replacements, wildcard and chained aliases,
  and variant ordering, validated by the official 1,773-case CLDR
  canonicalization fixture. Extension and private-use subtags are preserved,
  and `-u-` extension type aliases from CLDR BCP 47 data are applied (for
  example `ca-islamicc` becomes `ca-islamic-civil`). A zero-allocation
  `Locale` parser (`Locale.parse`) exposes the language, script, region,
  variants, and `-u-` keyword values of a tag.
- CLDR 48 language matching (`localeBestMatchAlloc`, `localeDistanceAlloc`,
  `localeIsMatchAlloc`): likely-subtag maximization, the 378 `languageMatch`
  rules with one-way fallbacks, region variables including macroregion
  expansion (`$americas`), paradigm-locale preference, per-desired demotion,
  the 50 threshold and 4/5 region defaults used by ICU's `LocaleMatcher`,
  and default-locale fallback. `und` is never maximized.
- CLDR 48 person name formatting (`formatPersonNameAlloc`): title, given,
  given2, surname, surname2, generation, and credentials fields with
  informal, prefix, and core variants; length, usage, formality, and order
  selection; per-locale patterns, initials, monograms, all-caps and
  initial-cap modifiers, empty-field punctuation cleanup, and native/foreign
  space replacement, validated by the official 36,960-case CLDR
  personNameTest fixture (22 Khmer and Myanmar initials follow the library's
  Intl.Segmenter-style dictionaries rather than ICU's legacy word iterator).
- CLDR 48 alphabetic index labels (`AlphabeticIndex`): per-locale index
  characters ordered by the locale's primary collation, underflow and
  overflow buckets, script-aware overflow, and label deduplication by
  primary weight, validated against ICU 78 bucket labels and indices for
  en, sv, es, tr, ru, and hi. Chinese pinyin indexes use the collation's
  `BASE+A-Z` contractions, so Han names land in the bucket of their pinyin
  initial and Latin names are redirected to the matching pinyin bucket;
  Traditional Chinese uses the stroke index. Inflow buckets for skipped
  scripts are not included.
- Numbering system selection for number and date formatting across 78 CLDR
  numeric systems (latn, arab, arabext, thai, deva, beng, hanidec,
  fullwide, and others) through `@numbers=`/`-u-nu-` locale keywords or an
  explicit option, with per-system digits and ICU-compatible symbol
  fallback. Validated by a 618-case PyICU fixture.
- CLDR 48 duration formatting for 108 locales with long, short, narrow, and
  numeric styles: locale-specific numeric patterns (h:mm:ss, m:ss, and
  overrides) plus unit and unit-list composition for hours, minutes, and
  seconds with plural selection. `formatDurationUnitsAlloc` accepts a
  `Duration` with years through nanoseconds and composes every non-zero unit
  through the locale's long, short, or narrow unit and unit-list patterns. Validated by an 858-case
  PyICU fixture.
- CLDR 48 date and time interval formatting for 108 locales, using ICU's
  repeated-field pattern splitting, greatest-difference selection,
  single-date collapse, hour-cycle-aware time skeletons, and locale
  fallback formatting, validated by a 296-case PyICU fixture. Skeleton
  intervals (`formatSkeletonIntervalAlloc`) follow ICU DateIntervalFormat
  semantics: canonical skeleton best-match resolution, interval-pattern
  width adjustment, date-once time-range composition, and fallback
  formatting, validated by a 9,361-case PyICU fixture across 23 skeletons
  and 20 locales.
- ICU time scale conversions (`timeScaleFromInt64`, `timeScaleToInt64`,
  `timeScaleValue`): Java/Unix/ICU4C milliseconds, Windows FILETIME, .NET
  ticks, old/new Mac seconds, Excel/DB2 days, and Unix microseconds, with
  ICU's overflow and negative-rounding semantics, validated by a 172-case
  ICU 78 differential fixture.
- IANA tzdata 2026e time zones for 597 IDs, including backward link names,
  with 64-bit transition-based UTC offset and daylight resolution from 1850
  through 2100, local/UTC conversion, zone-aware Unix timestamp formatting,
  next/previous transition lookup (`timeZoneNextTransition`,
  `timeZonePreviousTransition`), and local-time resolution
  (`timeZoneOffsetFromLocal`) that distinguishes DST gaps from overlaps and
  supports earlier/later/rejected disambiguation.
- CLDR 48 localized time zone names for 108 locales: specific and generic
  zone/metazone names, exemplar cities, region and localized GMT formats,
  and the `z`, `v`, `V`, `O`, `Z`, and `X`/`x` pattern fields, including
  standard/daylight selection, primary-zone location fallbacks, and
  metazone period resolution.
- Differential fixtures validate 15,883 time zone offset/daylight cases
  against an independent TZif reader and 3,696 localized name cases against
  PyICU.
- CLDR 48 Windows time zone ID mapping (`windowsIdForTimeZone`,
  `timeZoneIdForWindowsId`): 139 Windows IDs over 445 IANA zones, with
  region-specific lookups and the ICU `001` fallback semantics of
  `ucal_getWindowsTimeZoneID` and `ucal_getTimeZoneIDForWindowsID`.
- CLDR 48 canonical time zone IDs (`canonicalTimeZoneId`), preferred IANA
  IDs (`ianaTimeZoneId`), and regions (`timeZoneRegion`) for 601 long IDs,
  including legacy links such as `US/Pacific` and `Asia/Kolkata` and the
  `001` world region, matching ICU's `getCanonicalID`, `getIanaID`, and
  `getRegion`.
- CLDR 48 weekend start/end data (`weekendForRegion`, `isWeekend`): 18
  regions with explicit rules plus the world Saturday-Sunday default,
  including single-day weekends such as IR and IN.
- CLDR 48 region week data (`weekDataForRegion`, `firstDayOfWeek`,
  `minimalDaysInFirstWeek`): 154 regions plus the world Monday/1 default,
  with week-of-year (`weekOfYearForRegion`) and week-of-month
  (`weekOfMonthForRegion`) calculations using the region's first-day and
  minimal-days rules.
- CLDR 48 list formatting for 109 locales, including and/or and unit list
  styles with narrow/short variants. `listGender` implements the CLDR
  neutral, mixed-neutral, and male-tainting list-gender rules.
- CLDR 48 relative time for 109 locales, including yesterday/today/tomorrow
  text, future/past plural patterns, and long/short/narrow styles
  (`RelativeStyle`). Relative-type text always follows the long field, as in
  ICU's `RelativeDateTimeFormatter`.
- CLDR 48 unit formatting for 109 locales and all 231 CLDR units across
  length, mass, temperature, speed, area, volume, duration, digital, energy,
  power, pressure, frequency, angle, light, electricity, torque, and
  concentration, with long, short, and narrow forms, CLDR unit identifiers,
  and a 6,429-case PyICU differential conformance fixture.
- CLDR 48 RBNF rule-based number formatting for 112 locales, covering
  spellout and ordinal rule sets with negative, decimal, fraction, and
  optional rule branches, plural substitutions, Indian grouping, fraction
  rule sets, and an 6,840-case PyICU differential conformance fixture.
- ICU-style message formatting with positional/named arguments, plural,
  selectordinal, select, and choice branches, `#` substitution,
  number/date arguments, and quoting. `ChoiceFormat` provides ICU range
  patterns with `<`/`#`/`≤` selectors, infinity limits, `setChoices`, and
  longest-match parsing, validated by an ICU 78 differential fixture.
- Unicode MessageFormat 2 core subset: `.input`/`.local` declarations, quoted
  patterns, `.match` matchers with multiple selectors, expressions with
  literal/variable/function operands and options, `:string`, `:number`,
  `:integer`, `:offset`, and `:currency` formatting with exact-value and
  plural/ordinal selection, and `:date`/`:time`/`:datetime` formatting from
  ISO 8601 strings or DateTime values (date fields/length and time precision
  options). Custom functions plug in through a handler registry with
  resolve/format/select callbacks (`formatAllocWithRegistry`). Markup
  parses with its tag, options, and attributes and formats as an empty
  string by default; a registry markup handler can emit tags, with literal
  and variable option values resolved before the callback. Selection on date
  and currency values is rejected as unsupported.
- Bidirectional character iteration (`CharIterator`): UTF-8, UTF-16, and
  UTF-16BE storage, ICU `uiter` post-increment/pre-decrement movement,
  current, first/last, relative moves with boundary snapping,
  `hasNext`/`hasPrevious`, `indexAt`, and `getState`/`setState`.
- ICU `UCharsTrie` and `BytesTrie` readers and builders (`UCharsTrie`,
  `UCharsTrieBuilder`, `BytesTrie`, `BytesTrieBuilder`): ICU-serialized
  linear-match, branch, intermediate-value, and final-value nodes with
  `first`, `next`, `nextString`, code-point traversal,
  `hasUniqueValue`, `getNextUChars`/`getNextBytes`, and
  `getState64`/`resetToState64`. Readers are validated against 18 ICU 78
  tries, lookup traces, and state snapshots; builder output is accepted by
  ICU's readers, including binary branches, high bytes, and supplementary
  code points.
- ICU `UText`-style text abstraction (`UText`): UTF-8, UTF-16, and UTF-32
  storage with native indexes, backward boundary snapping on
  `setNativeIndex`, `next`/`previous`/`moveIndex32`, and range extraction,
  validated by a 30-case ICU 78 differential fixture.
- ICU `.res` resource bundles (`ResourceBundle`, `BundleSet`): format
  versions 1.0-3.x, 16-bit tables/arrays, String-v2 suffix sharing, binary
  and integer-vector resources, aliases, pool-bundle key/string sharing, and
  `/`-separated path lookup. `BundleSet` adds `ures_open`-style locale
  fallback (`en_US` -> `en` -> root), per-path fallback, `noFallback`, and
  cross-bundle aliases. Validated against ICU `ures_openDirect` and
  `ures_open` traces for standalone, pooled, and fallback lookups.
- UTF-16 validation, iteration, and UTF-8/UTF-16 conversion helpers.
- Charset conversion for UTF-8/16/32, ASCII, Latin-1, 28 legacy single-byte
  encodings, GBK/GB18030, Big5, EUC-JP, ISO-2022-JP, Shift_JIS, and EUC-KR,
  with strict/replace/ignore error modes and ICU-style label resolution.
- ICU-compatible charset detection (`detectCharset`, `detectCharsetsAlloc`):
  UTF-8, UTF-16/32 (BE/LE), ISO-8859-1/2/5/6/7/8/8-I/9, windows-1250/1251/
  1252/1253/1254/1255/1256, KOI8-R, Shift_JIS, GB18030, EUC-JP, EUC-KR,
  Big5, ISO-2022-JP/KR/CN, and the legacy IBM420/IBM424 Arabic/Hebrew
  recognizers, with HTML/XML input filtering and ICU's confidence ordering,
  validated by a 37-case PyICU differential fixture. A stateful
  `CharsetDetector` exposes `setText`, declared-encoding, and input-filter
  controls, and `charsetEncodingName`/`charsetMaxCharSize`/
  `charsetMinCharSize` provide `ucnv`-style converter metadata.
- ICU `ucnvsel`-compatible converter selection (`ConverterSelector`): an
  ordered converter list, optional excluded code points, UTF-8 and UTF-16
  input, and per-converter encodability flags or names, validated by a
  20-case ICU 78 differential fixture. Selectors can be persisted with
  `serializeAlloc`/`initFromSerialized` using icuz's versioned `CJSS`
  format (converter names, exclusion set, and mode).
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
- ICU `uregex`-compatible regular expressions (`Regex.compileAlloc`,
  `RegexMatcher`): literals, `.`, character classes with `&&`/`--` set
  operations, POSIX classes, `\p{...}` properties, greedy/reluctant/
  possessive quantifiers, capturing and named groups, numeric and
  `\k<name>` back references, lookahead and bounded lookbehind, atomic
  groups, inline flags (`i`, `m`, `s`, `d`, `w`, `x`), `\A`/`\Z`/`\z`/
  `\G`/`\b`/`\B` anchors, `\R` line breaks, `\X` grapheme clusters,
  `\Q...\E`, named-character escapes, and full Unicode case folding
  (including multi-scalar folds such as `ß` and `ss`). Region matching
  honors transparent and anchoring bounds; find, replace (`$n`/`${name}`),
  and split follow ICU's C API behavior, and `start16`/`end16` expose
  ICU-compatible UTF-16 indices. Validated by a 97-case ICU 78 differential
  fixture.
- Embedded, version-pinned generated data plus conformance fixtures.

## Non-goals for 0.1

`icuz` is not a drop-in ICU replacement. Its transliteration support is a
compiled rule-table engine covering the constructs listed above plus a
runtime ICU-rule interpreter that runs embedded `::Transform;` (including
normalization and Any-Case) directives as pipeline steps. In the reverse
direction, rules with captures or context are rejected, matching ICU's rule
parser, which also refuses to compile them. Display/layout tailoring is also
out of scope. Collation supports root ordering plus CLDR
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
search. Normalization runs per starter segment: one-code-point segments skip
canonical ordering and composition entirely, a composition-second page table
keeps ordinary starters out of the composition binary search, and simple-page
bitmaps let CJK and other non-decomposing scripts skip all three per-scalar
lookups. UTF-8 validation is fused into the quick check through an inlined
scalar decoder that rejects truncation, overlongs, and surrogates without the
generic `std.unicode` helpers, the quick check bulk-skips interior ASCII
runs, CJK scalars whose whole 3-byte lead range is simple are validated and
skipped without decoding, stable spans before and between changes are copied
verbatim, and the segment engine streams UTF-8 straight to the output sink
with ASCII runs bulk-copied. The quick-check scan doubles as UTF-8 validation, so a text that
is already normalized never pays a second validation pass; when the scan
stops early, only the unscanned suffix is validated.

Collation keeps five fast paths: a 128-entry ASCII table, a compile-time table
for Latin-1 and Latin Extended-A/B (decomposed on the stack) that bypasses the
page tables for un-tailored Latin text, a tailored Latin path that matches the
locale's rules through the page index and fills the rest from the root table,
a direct emitter for text whose code points all take implicit weights (Han,
unassigned), and per-tailoring first-code-point page indexes built on first
use and published lock-free. Each page index also carries a direct table for
code points below U+1000, so Latin and other early-script rules resolve
without a search, and a 256-entry atomic cache of the first rule for recently
matched code points; above U+1000, rule records carry their first code point
inline so binary-search probes are a single load. Collation elements start in
a stack buffer, so typical sort keys allocate only the returned key, and the
NFD pass over Latin text handles ASCII without a decomposition lookup.
UAX #29 word and sentence segmentation classify ASCII bytes through
compile-time tables and decode ASCII bytes directly, so prose runs skip the
general property lookup and the UTF-8 decoder.
Charset
reverse indexes carry compile-time page indexes and a split layout (sorted
`u32` code points, then parallel `u16` pointers), so DBCS encoders
binary-search only one 256-code-point page; hot stateless conversion pairs
run comptime-specialized loops that append into reserved capacity with no
per-character dispatch or capacity checks, each DBCS encoder keeps a small
atomic cache of recent reverse lookups, UTF-8 to DBCS pairs use a fused
decode/encode loop, and DBCS to UTF-8 pairs write UTF-8 bytes directly;
both fall back to the generic converter on any error.

Transliteration passes precompute their literal-entry bounds and store a
parallel `u32` first-code-point array, so per-character rule lookup
binary-searches a compact array instead of decoding 34-byte entry records.
Passes without insertion, cursor-repositioning, or captured-context rules
stream into a fresh output buffer instead of shifting the remaining input,
keeping expanding mappings linear. Filtered transforms resolve each pass's
range and streamability once and reuse it for every input run, and run the
whole text in one compound when the unfiltered characters are ASCII
boundaries and every rule source and context stays inside the filter set
(the cached safety decision avoids rescanning the rule table per word).
Latin-ASCII skips rule matching entirely when accent stripping leaves pure
ASCII text, and root collation emits its three levels directly while
scanning, with a precomputed ASCII element table for mixed-script keys.

## Data provenance

Generated tables and conformance fixtures contain derived Unicode data. See
`THIRD_PARTY_NOTICES.md` and `licenses/Unicode-3.0.txt`.
