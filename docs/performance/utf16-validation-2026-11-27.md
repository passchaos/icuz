# UTF-16 validation against simdutf 9.5.0, 2026-11-27

Strict UTF-16 validation now uses a thirty-two-unit pair-mask scan with no
serial carry: a high surrogate at bit `i` and its low partner at bit `i + 1`
mark both lanes valid in one bitmask pass, and only a lone trailing high
surrogate is deferred to the next window. A sixteen-unit stage keeps short
inputs on the vector path. The new validator is 1.07-1.89x faster than the
previous scan on 17 of 18 corpora (one 16-unit tail row is within noise at
0.94x) and beats simdutf 9.5.0 on all 18 (1.02-4.73x).

This is a new comparison area: the previous profiles compared UTF-8
validation, normalization, collation, segmentation, and conversion, but not
UTF-16 validation against simdutf.

The same pair-mask scan now also computes the exact UTF-8 size and scalar
count, replacing the old carry-chain scan. `utf8Size` is 1.12-1.69x faster
on medium and large inputs and `codepointCount` is 1.19-3.07x faster, which
speeds up the owned conversion path's size pass (for example emoji-4096
allocation 699.3 to 585.9 ns, surrogate-heavy 64 KiB 62.5 to 55.4 µs).

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64; Zig 0.16.0 ReleaseFast
  native. simdutf 9.5.0 `haswell` built with GCC 13 `-O3 -std=c++17` from
  source commit `9064366fa571fac03bcd28db35af597e97fba842`.
- Both harnesses read the same UTF-8 files, convert them to UTF-16 with
  their own standard converter, and validate the resulting units. Printed
  unit counts match for every corpus.
- Three alternating rounds of old/new/simdutf order, five trials per row,
  at least 2,000 calls and a 16 MiB target per trial. Values are ns per
  validate call, minimum across rounds and trials.
- Corpora cover pure ASCII, Latin-1, Chinese, mixed scripts, emoji,
  sparse/dense-to-sparse/random/transition/surrogate-heavy inputs through
  64 KiB, and 31-byte and 128-byte tails.
- [Raw samples](utf16-validation-2026-11-27.json) record every round, unit
  counts, harness hashes, and the validator source hash.

## Implementation and bounds

Each thirty-two-unit window loads two sixteen-unit vectors. A surrogate
bitmask is formed from `(unit & 0xf800) == 0xd800`; if it is zero the window
advances immediately. Otherwise a second mask marks low surrogates
(`0xdc00..0xdfff`), `pairs = low & (high >> 1)` marks every high surrogate
followed by its partner, and `covered = ~surrogates | pairs | (pairs << 1)`
proves the whole window. `covered == all` advances 32 units;
`covered == all >> 1` advances 31 and re-checks the lone trailing high
surrogate with the next window; anything else is invalid. A sixteen-unit
stage repeats the same test, and a scalar tail handles fewer than sixteen
remaining units, including a pair that starts in the tail.

The vector stages run only on little-endian targets; other targets use the
scalar tail, which validates pairs and rejects lone or reversed surrogates.
All loads stay inside the supplied slice. `utf8Size` and `codepointCount`
keep their existing counting scan; only `isValid` changed.

## Results

Values are ns per call; ratio columns are old divided by new and simdutf
divided by new, so values above one mean the new validator is faster.

| Corpus | Units | Old ns | New ns | simdutf ns | old/new | simdutf/new |
|---|---:|---:|---:|---:|---:|---:|
| ascii-4096 | 4144 | 139.08 | 73.60 | 171.08 | 1.89x | 2.32x |
| latin-4096 | 3160 | 111.74 | 62.76 | 128.30 | 1.78x | 2.04x |
| chinese-4096 | 1368 | 48.37 | 27.82 | 58.02 | 1.74x | 2.09x |
| mixed-4096 | 2574 | 135.95 | 94.02 | 117.70 | 1.45x | 1.25x |
| emoji-4096 | 4104 | 193.07 | 108.45 | 132.95 | 1.78x | 1.23x |
| mixed-random-4096 | 2522 | 200.45 | 123.67 | 137.08 | 1.62x | 1.11x |
| mixed-transitions-4096 | 2634 | 182.03 | 113.89 | 120.79 | 1.60x | 1.06x |
| mixed-surrogate-heavy-4096 | 2686 | 164.90 | 113.65 | 124.24 | 1.45x | 1.09x |
| mixed-sparse-4096 | 2132 | 147.71 | 101.64 | 155.70 | 1.45x | 1.53x |
| mixed-dense-to-sparse-4096 | 2252 | 152.99 | 93.35 | 154.33 | 1.64x | 1.65x |
| mixed-sparse-65536 | 62090 | 2372.71 | 2032.22 | 2464.32 | 1.17x | 1.21x |
| mixed-dense-to-sparse-65536 | 61988 | 2347.25 | 2016.82 | 2474.45 | 1.16x | 1.23x |
| mixed-random-65536 | 38090 | 3102.06 | 2160.13 | 2275.19 | 1.44x | 1.05x |
| mixed-surrogate-heavy-65536 | 32809 | 2677.59 | 2279.03 | 2314.99 | 1.17x | 1.02x |
| tiny-ascii-31 | 31 | 8.01 | 6.10 | 20.97 | 1.31x | 3.44x |
| tiny-emoji-31 | 16 | 1.75 | 1.86 | 8.79 | 0.94x | 4.73x |
| mixed-32 | 106 | 4.83 | 4.42 | 7.21 | 1.09x | 1.63x |
| mixed-128 | 131 | 9.55 | 8.90 | 11.28 | 1.07x | 1.27x |

The previous validator was 1.15-1.6x slower than simdutf on every
surrogate-containing corpus (emoji 0.62x, transitions 0.66x, random 0.68x,
surrogate-heavy 0.75-0.86x). The pair-mask scan removes the per-window carry
chain and doubles the window width, and the remaining rows are now ahead.
A sixty-four-unit stage with 64-bit pair masks was measured and rejected:
it was 0.69-0.94x on most corpora, because the 64-bit mask handling and
register pressure outweighed the halved loop overhead. The thirty-two-unit
stage plus the sixteen-unit short stage is the local optimum.
`tiny-emoji-31` is the only row where the new scan is marginally slower than
the old one (1.75 vs 1.86 ns, one sixteen-unit iteration each); the absolute
difference is under 0.2 ns and treated as noise. The thinnest simdutf
margins (surrogate-heavy 1.02x, random 1.05x, transitions 1.06x) sit inside
the project's ten-percent parity band; the larger margins are outside it.

## Size and count scans

`utf8Size` (validating size) and `codepointCount` use the same thirty-two
unit pair masks plus a sixteen-unit stage. The count per window is
`width + popcount(non_ascii) + popcount(three) - 2 * popcount(leads)`;
a trailing lead surrogate is deferred to the next window exactly like the
validator. Values are ns per call, minimum across three rounds.

| Corpus | Old size ns | New size ns | Size ratio | Old count ns | New count ns | Count ratio |
|---|---:|---:|---:|---:|---:|---:|
| ascii-4096.bin | 424.72 | 296.60 | 1.43x | 459.71 | 149.67 | 3.07x |
| chinese-4096.bin | 217.66 | 129.01 | 1.69x | 165.31 | 58.41 | 2.83x |
| emoji-4096.bin | 528.16 | 315.28 | 1.68x | 384.87 | 194.85 | 1.98x |
| latin-4096.bin | 711.33 | 428.13 | 1.66x | 372.54 | 123.39 | 3.02x |
| mixed-128.bin | 30.50 | 24.36 | 1.25x | 18.41 | 15.08 | 1.22x |
| mixed-32.bin | 15.61 | 12.52 | 1.25x | 9.70 | 8.17 | 1.19x |
| mixed-4096.bin | 592.71 | 365.36 | 1.62x | 329.71 | 167.27 | 1.97x |
| mixed-dense-to-sparse-4096.bin | 478.54 | 333.91 | 1.43x | 423.74 | 173.77 | 2.44x |
| mixed-dense-to-sparse-65536.bin | 5719.32 | 5099.12 | 1.12x | 6157.72 | 2836.33 | 2.17x |
| mixed-random-4096.bin | 572.07 | 376.64 | 1.52x | 395.32 | 243.87 | 1.62x |
| mixed-random-65536.bin | 8524.02 | 6026.37 | 1.41x | 5610.68 | 3919.28 | 1.43x |
| mixed-sparse-4096.bin | 467.88 | 333.95 | 1.40x | 423.55 | 172.75 | 2.45x |
| mixed-sparse-65536.bin | 7504.92 | 5158.50 | 1.45x | 6702.66 | 2865.22 | 2.34x |
| mixed-surrogate-heavy-4096.bin | 479.64 | 323.97 | 1.48x | 330.58 | 205.49 | 1.61x |
| mixed-surrogate-heavy-65536.bin | 7159.72 | 5658.33 | 1.27x | 4823.63 | 3762.13 | 1.28x |
| mixed-transitions-4096.bin | 497.84 | 331.58 | 1.50x | 354.19 | 217.87 | 1.63x |
| tiny-ascii-31.bin | 16.81 | 17.53 | 0.96x | 11.88 | 13.02 | 0.91x |
| tiny-emoji-31.bin | 4.85 | 5.20 | 0.93x | 3.95 | 3.75 | 1.05x |

The owned conversion path calls `utf8Size` before converting, so the
allocation rows improve with it. An interleaved A/B against the previous
scan measured mixed-random 64 KiB UTF-16-to-UTF-8 allocation at 85.4 to
79.9 µs, surrogate-heavy at 62.5 to 55.4 µs, emoji-4096 at 699.3 to
585.9 ns, and ASCII-4096 at 288.9 to 259.0 ns. Reuse rows are unchanged
because the warmed caller-buffer path does not run the size pass.

### UTF-8 to UTF-16 size pass

`utf16SizeValid` sizes UTF-8 text for owned UTF-16 allocation and for the
insufficient-capacity append path. It now samples the first block:
ASCII-leading text uses a movemask fast path that skips both masks on
pure-ASCII blocks, while non-ASCII-leading text keeps the plain two-mask
loop. An interleaved A/B measured ASCII-4096 allocation at 243.3 to
189.6 ns (1.28x), mixed-sparse-4096 at 663.4 to 638.0 ns, and
mixed-sparse 64 KiB at 39.3 to 38.7 µs. Chinese, emoji, and Latin rows are
unchanged because they take the plain loop, so the fast path does not
trade one workload for another.

## Reproduce

```sh
zig build-exe -O ReleaseFast -fstrip --dep utf16 \
  -Mroot=/tmp/validate16_bench.zig -Mutf16=src/unicode/utf16.zig \
  -lc -femit-bin=/tmp/validate16-icuz
g++ -O3 -std=c++17 -I/tmp/icuz-simdutf-9.5.0/include \
  -I/tmp/icuz-simdutf-9.5.0/src /tmp/validate16_bench.cpp \
  /tmp/icuz-simdutf-9.5.0/src/simdutf.cpp -o /tmp/validate16-simdutf
taskset -c 2 /tmp/validate16-icuz corpus/*.bin
taskset -c 2 /tmp/validate16-simdutf corpus/*.bin
```

The harness sources are recorded in the raw profile hashes; both print
`path<TAB>units<TAB>ns<TAB>sink`. Run the three binaries in alternating
order for three rounds and take the per-row minimum.

## Validation

- Native ReleaseSafe UTF module: 65/65 passed, including differential
  tests that compare `isValid`, `utf8Size`, and `codepointCount` with
  scalar oracles over exhaustive surrogate-focused sequences, 20,000
  randomized sequences through 160 units, and pairs or lone surrogates at
  every position of every length through 130 units.
- Full library Debug test step: 540 passed, two environment-gated skips
  (542 total).
- AArch64 and big-endian PowerPC64 ReleaseSafe compile-only checks passed;
  the scalar tail covers non-little-endian targets.
- Formatting checked before sampling.
