# Unified UTF-8 mixed-window decoding, 2026-11-26

The mixed UTF-8→native UTF-16 decoder now uses one general BMP/supplementary
kernel for both checked caller buffers and prevalidated owned outputs. It
removes data-dependent output-width branches and writes six bounded UTF-16
units per general group, with later groups replacing padding.

Random 64 KiB caller-buffer conversion falls from 52255.199 to
33662.152 ns/op (1.55x); frequent-transition input falls
from 46806.499 to 30111.585 ns/op
(1.55x). Complete tables retain both allocation and
reuse, both directions, and all 26 corpora. 48/52 reuse rows exceed both
simdutf 9.5.0 and ICU 78.3 in this profile. The full industry-best objective
remains active, including the remaining UTF-16→UTF-8 gaps and other APIs and
hardware.

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64. Zig 0.16.0 ReleaseFast
  native; external GCC 13 `-O3 -std=c++17`, simdutf 9.5.0 `haswell`, ICU 78.3.
- The same [26 fixed-seed corpora](utf16-sparse-runs-2026-11-26.md#irregular-corpus)
  cover established phrase/tail rows plus irregular width, transition,
  sparse-non-ASCII, and surrogate-heavy families up to 64 KiB.
- Five rounds and five trials per row; at least 2,000 calls and an 8 MiB
  target per trial. The 64 KiB rows therefore process about 125 MiB per trial.
  Tables report the minimum across the rounds; every sample remains in JSON.
- Each corpus runs sequentially on CPU 2 in icuz/external/8faa08a/95bb5bc order,
  reversed in alternate rounds. This task's compilation and tests finish
  before sampling. The unchanged benchmark isolates its four measurement
  functions; API loops, counts, and contents are identical for all revisions.
- Owned output validates, sizes, allocates exactly, converts, and frees.
  Reuse performs strict conversion into warmed caller buffers. Only reuse
  is compared with external caller-buffer APIs.
- Current and predecessor binaries check output against independent std
  conversion. The external harness checks status, length, and content; the
  driver checks every required row, input length, and output size.
- Preserved 8faa08a and external hashes match the preceding committed
  [sparse-run profile](utf16-sparse-runs-2026-11-26.json). The 95bb5bc control
  is the same rebuilt reference from that profile, with the same harness.
- [Raw profile](utf8-unified-windows-2026-11-26.json) contains every sample,
  version, byte/unit count, and input/binary/current-source hash. `baseline`
  is 8faa08a; `reference` is 95bb5bc. simdutf source commit:
  `9064366fa571fac03bcd28db35af597e97fba842`.

## Implementation and output bounds

The six-lane ASCII/two-byte kernel remains. Other groups decode three or four
scalars through the existing shuffle/mask tables, reconstruct all code points,
select BMP units or supplementary surrogate pairs, and pack the output with
the existing unit shuffle. The former BMP-versus-supplementary branch and
conditional fifth/sixth output stores are removed. Table sizes and public
API contracts remain unchanged.

The group loop only enters when at least sixteen input bytes remain. A valid
UTF-8 suffix has no more than three bytes per UTF-16 unit: three-byte BMP
scalars use one unit, and four-byte scalars use two. Its output therefore has
at least six remaining units. A fixed six-unit store stays inside even the
exact owned allocation. The returned length still uses the entry's actual
unit count; later groups and scalar tail conversion replace padded units.
Checked warmed append buffers have at least the original UTF-8 byte count in
spare UTF-16 capacity. Existing prefixes stay outside the spare slice, and
public length publication still occurs only after conversion succeeds.

The guarded-buffer oracle now directly runs both checked and prevalidated
window kernels into the exact std-sized output slice immediately before a
guard page. It verifies each consumed prefix against std, covering ASCII,
Latin, Chinese, supplementary, and mixed input at every valid length through
257 bytes. Existing width-tuple, complete-scalar, malformed-neighbor, exact
allocation, prefix, and allocation-failure tests also pass. Non-LLVM bounded
load fallback paths remain intact.

## Hardware-counter evidence

The [checked-only harness](../../bench/utf16/profile/bench.zig) repeats the
same strict API in a warmed output and verifies contents. Before changing the
decoder, identical one-direction harnesses for 8faa08a and 95bb5bc produced
matching window addresses and nearly identical instruction/cycle counts.
This narrowed the earlier complete-program regression to layout-sensitive
behavior rather than additional source-level work.

The final current and 8faa08a harnesses use identical source, 20,000 calls,
three alternating-order rounds on CPU 2, and explicit user-mode cpu_core
PMU events. [Counter JSON](utf8-unified-checked-counters-2026-11-26.json)
records all counts, raw perf CSV, source/input hashes, and both executable
hashes. Values below are mean counts per API call; setup and final verification
are also included in the whole-process counters.

| Corpus | Event | 8faa08a | Current | Change |
|---|---|---:|---:|---:|
| mixed-random-65536 | cycles | 214134.13 | 135137.55 | -36.9% |
| mixed-random-65536 | instructions | 508883.04 | 526004.62 | +3.4% |
| mixed-random-65536 | branches | 71219.66 | 53466.95 | -24.9% |
| mixed-random-65536 | branch-misses | 3336.99 | 172.53 | -94.8% |
| mixed-transitions-65536 | cycles | 190209.46 | 120762.94 | -36.5% |
| mixed-transitions-65536 | instructions | 469241.86 | 469622.89 | +0.1% |
| mixed-transitions-65536 | branches | 62703.82 | 45763.12 | -27.0% |
| mixed-transitions-65536 | branch-misses | 2829.31 | 133.44 | -95.3% |

## Owned output comparison

Speedup is predecessor/current; values below one mean current takes longer.

| Corpus | Direction | Current ns | 8faa08a ns | 95bb5bc ns | vs 8faa08a |
|---|---|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.708 | 26.684 | 26.675 | 1.00x |
| ascii-32 | utf16-to-utf8 | 20.085 | 20.086 | 20.078 | 1.00x |
| ascii-128 | utf8-to-utf16 | 27.733 | 27.212 | 27.442 | 0.98x |
| ascii-128 | utf16-to-utf8 | 24.735 | 24.742 | 24.726 | 1.00x |
| ascii-4096 | utf8-to-utf16 | 241.324 | 243.379 | 239.712 | 1.01x |
| ascii-4096 | utf16-to-utf8 | 288.849 | 288.911 | 295.808 | 1.00x |
| latin-32 | utf8-to-utf16 | 52.485 | 52.527 | 52.421 | 1.00x |
| latin-32 | utf16-to-utf8 | 32.240 | 32.221 | 32.455 | 1.00x |
| latin-128 | utf8-to-utf16 | 94.499 | 94.767 | 94.532 | 1.00x |
| latin-128 | utf16-to-utf8 | 50.609 | 51.337 | 50.580 | 1.01x |
| latin-4096 | utf8-to-utf16 | 1757.901 | 1759.419 | 1756.684 | 1.00x |
| latin-4096 | utf16-to-utf8 | 885.579 | 885.680 | 885.416 | 1.00x |
| chinese-32 | utf8-to-utf16 | 26.130 | 26.183 | 26.137 | 1.00x |
| chinese-32 | utf16-to-utf8 | 23.110 | 23.113 | 23.116 | 1.00x |
| chinese-128 | utf8-to-utf16 | 35.257 | 34.992 | 35.010 | 0.99x |
| chinese-128 | utf16-to-utf8 | 23.054 | 23.075 | 23.057 | 1.00x |
| chinese-4096 | utf8-to-utf16 | 549.687 | 550.931 | 550.003 | 1.00x |
| chinese-4096 | utf16-to-utf8 | 380.724 | 380.862 | 380.773 | 1.00x |
| mixed-32 | utf8-to-utf16 | 71.132 | 72.936 | 72.042 | 1.03x |
| mixed-32 | utf16-to-utf8 | 54.245 | 53.628 | 54.865 | 0.99x |
| mixed-128 | utf8-to-utf16 | 124.771 | 127.147 | 124.519 | 1.02x |
| mixed-128 | utf16-to-utf8 | 91.457 | 90.918 | 93.079 | 0.99x |
| mixed-4096 | utf8-to-utf16 | 2092.971 | 2079.425 | 2077.446 | 0.99x |
| mixed-4096 | utf16-to-utf8 | 1462.752 | 1461.346 | 1474.985 | 1.00x |
| emoji-32 | utf8-to-utf16 | 29.645 | 29.652 | 29.619 | 1.00x |
| emoji-32 | utf16-to-utf8 | 22.177 | 22.115 | 22.119 | 1.00x |
| emoji-128 | utf8-to-utf16 | 47.221 | 47.631 | 47.194 | 1.01x |
| emoji-128 | utf16-to-utf8 | 34.641 | 35.894 | 34.900 | 1.04x |
| emoji-4096 | utf8-to-utf16 | 820.767 | 826.727 | 822.155 | 1.01x |
| emoji-4096 | utf16-to-utf8 | 702.181 | 702.449 | 702.075 | 1.00x |
| tiny-ascii-31 | utf8-to-utf16 | 29.067 | 29.306 | 29.053 | 1.01x |
| tiny-ascii-31 | utf16-to-utf8 | 21.842 | 21.842 | 21.830 | 1.00x |
| tiny-emoji-31 | utf8-to-utf16 | 20.652 | 20.638 | 20.662 | 1.00x |
| tiny-emoji-31 | utf16-to-utf8 | 17.622 | 17.609 | 17.828 | 1.00x |
| mixed-random-128 | utf8-to-utf16 | 84.463 | 88.396 | 83.726 | 1.05x |
| mixed-random-128 | utf16-to-utf8 | 77.364 | 78.495 | 80.574 | 1.01x |
| mixed-random-4096 | utf8-to-utf16 | 2172.801 | 2198.751 | 2189.589 | 1.01x |
| mixed-random-4096 | utf16-to-utf8 | 1853.892 | 1853.340 | 1913.110 | 1.00x |
| mixed-random-65536 | utf8-to-utf16 | 57453.253 | 65493.530 | 73151.715 | 1.14x |
| mixed-random-65536 | utf16-to-utf8 | 80053.056 | 79480.484 | 94432.713 | 0.99x |
| mixed-transitions-4096 | utf8-to-utf16 | 2010.220 | 2045.806 | 2046.848 | 1.02x |
| mixed-transitions-4096 | utf16-to-utf8 | 1743.096 | 1743.316 | 1812.622 | 1.00x |
| mixed-transitions-65536 | utf8-to-utf16 | 50381.414 | 54017.069 | 58030.988 | 1.07x |
| mixed-transitions-65536 | utf16-to-utf8 | 69334.906 | 69241.950 | 74039.756 | 1.00x |
| mixed-sparse-4096 | utf8-to-utf16 | 621.961 | 658.228 | 639.296 | 1.06x |
| mixed-sparse-4096 | utf16-to-utf8 | 724.016 | 723.221 | 1062.625 | 1.00x |
| mixed-sparse-65536 | utf8-to-utf16 | 39843.366 | 39033.679 | 38549.785 | 0.98x |
| mixed-sparse-65536 | utf16-to-utf8 | 29135.670 | 28961.120 | 40524.289 | 0.99x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1804.935 | 1941.407 | 1942.719 | 1.08x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1708.093 | 1707.377 | 1726.950 | 1.00x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 45949.527 | 49344.096 | 49966.574 | 1.07x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 66247.443 | 66250.147 | 62651.312 | 1.00x |

## Warmed caller-buffer comparison

Speedup is predecessor/current; values below one mean current takes longer.

| Corpus | Direction | Current ns | 8faa08a ns | 95bb5bc ns | simdutf ns | ICU ns | vs 8faa08a | vs simdutf |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.510 | 4.510 | 4.544 | 12.374 | 36.928 | 1.00x | 2.74x |
| ascii-32 | utf16-to-utf8 | 3.508 | 3.508 | 3.508 | 10.438 | 36.407 | 1.00x | 2.98x |
| ascii-128 | utf8-to-utf16 | 6.518 | 6.517 | 6.522 | 9.897 | 95.054 | 1.00x | 1.52x |
| ascii-128 | utf16-to-utf8 | 6.774 | 6.773 | 6.769 | 13.806 | 92.642 | 1.00x | 2.04x |
| ascii-4096 | utf8-to-utf16 | 97.217 | 97.218 | 97.219 | 110.754 | 2097.676 | 1.00x | 1.14x |
| ascii-4096 | utf16-to-utf8 | 111.958 | 111.998 | 111.918 | 198.124 | 2049.559 | 1.00x | 1.77x |
| latin-32 | utf8-to-utf16 | 35.804 | 35.782 | 36.265 | 37.772 | 38.375 | 1.00x | 1.05x |
| latin-32 | utf16-to-utf8 | 12.550 | 12.551 | 12.553 | 23.395 | 28.024 | 1.00x | 1.86x |
| latin-128 | utf8-to-utf16 | 69.144 | 69.237 | 68.601 | 87.131 | 91.884 | 1.00x | 1.26x |
| latin-128 | utf16-to-utf8 | 23.595 | 23.545 | 23.579 | 35.177 | 68.992 | 1.00x | 1.49x |
| latin-4096 | utf8-to-utf16 | 1529.818 | 1528.828 | 1522.715 | 1896.393 | 2173.790 | 1.00x | 1.24x |
| latin-4096 | utf16-to-utf8 | 468.664 | 468.010 | 468.145 | 620.392 | 1660.980 | 1.00x | 1.32x |
| chinese-32 | utf8-to-utf16 | 13.555 | 13.576 | 12.890 | 23.126 | 23.779 | 1.00x | 1.71x |
| chinese-32 | utf16-to-utf8 | 9.573 | 9.939 | 10.922 | 18.192 | 18.727 | 1.04x | 1.90x |
| chinese-128 | utf8-to-utf16 | 13.593 | 13.626 | 13.646 | 81.769 | 87.614 | 1.00x | 6.02x |
| chinese-128 | utf16-to-utf8 | 10.812 | 10.707 | 11.025 | 32.482 | 63.430 | 0.99x | 3.00x |
| chinese-4096 | utf8-to-utf16 | 359.655 | 359.393 | 361.717 | 944.945 | 2076.508 | 1.00x | 2.63x |
| chinese-4096 | utf16-to-utf8 | 271.652 | 271.841 | 275.296 | 408.321 | 1388.744 | 1.00x | 1.50x |
| mixed-32 | utf8-to-utf16 | 54.554 | 55.565 | 58.824 | 68.414 | 66.508 | 1.02x | 1.25x |
| mixed-32 | utf16-to-utf8 | 39.644 | 39.435 | 39.414 | 46.557 | 50.597 | 0.99x | 1.17x |
| mixed-128 | utf8-to-utf16 | 100.468 | 100.332 | 104.098 | 121.632 | 123.827 | 1.00x | 1.21x |
| mixed-128 | utf16-to-utf8 | 67.608 | 67.629 | 67.207 | 76.782 | 92.285 | 1.00x | 1.14x |
| mixed-4096 | utf8-to-utf16 | 1883.626 | 1838.091 | 1840.542 | 1919.574 | 2242.220 | 0.98x | 1.02x |
| mixed-4096 | utf16-to-utf8 | 1115.706 | 1117.258 | 1127.689 | 1030.884 | 1644.985 | 1.00x | 0.92x |
| emoji-32 | utf8-to-utf16 | 12.922 | 13.049 | 12.553 | 31.209 | 58.506 | 1.01x | 2.42x |
| emoji-32 | utf16-to-utf8 | 9.643 | 9.607 | 10.526 | 27.999 | 28.514 | 1.00x | 2.90x |
| emoji-128 | utf8-to-utf16 | 26.672 | 26.628 | 26.502 | 99.265 | 152.775 | 1.00x | 3.72x |
| emoji-128 | utf16-to-utf8 | 18.029 | 18.017 | 19.274 | 73.169 | 78.703 | 1.00x | 4.06x |
| emoji-4096 | utf8-to-utf16 | 591.744 | 591.854 | 587.588 | 2345.402 | 3670.253 | 1.00x | 3.96x |
| emoji-4096 | utf16-to-utf8 | 396.725 | 396.646 | 396.917 | 1963.454 | 1950.026 | 1.00x | 4.95x |
| tiny-ascii-31 | utf8-to-utf16 | 5.267 | 5.266 | 5.266 | 11.853 | 24.234 | 1.00x | 2.25x |
| tiny-ascii-31 | utf16-to-utf8 | 3.515 | 3.508 | 3.512 | 11.270 | 22.346 | 1.00x | 3.21x |
| tiny-emoji-31 | utf8-to-utf16 | 5.376 | 5.367 | 5.382 | 21.935 | 37.825 | 1.00x | 4.08x |
| tiny-emoji-31 | utf16-to-utf8 | 5.026 | 5.044 | 5.041 | 19.428 | 21.227 | 1.00x | 3.87x |
| mixed-random-128 | utf8-to-utf16 | 70.417 | 70.938 | 74.187 | 84.689 | 89.132 | 1.01x | 1.20x |
| mixed-random-128 | utf16-to-utf8 | 63.463 | 63.305 | 67.172 | 64.994 | 62.525 | 1.00x | 1.02x |
| mixed-random-4096 | utf8-to-utf16 | 1994.128 | 2022.790 | 2024.603 | 2508.737 | 2434.876 | 1.01x | 1.26x |
| mixed-random-4096 | utf16-to-utf8 | 1532.539 | 1528.219 | 1592.160 | 2057.399 | 1944.264 | 1.00x | 1.34x |
| mixed-random-65536 | utf8-to-utf16 | 33662.152 | 52255.199 | 43662.543 | 62421.427 | 221039.198 | 1.55x | 1.85x |
| mixed-random-65536 | utf16-to-utf8 | 57601.251 | 57797.519 | 64381.999 | 155113.854 | 183565.423 | 1.00x | 2.69x |
| mixed-transitions-4096 | utf8-to-utf16 | 1824.252 | 1891.314 | 1890.316 | 2350.230 | 2550.628 | 1.04x | 1.29x |
| mixed-transitions-4096 | utf16-to-utf8 | 1422.659 | 1421.617 | 1518.519 | 2110.496 | 1836.046 | 1.00x | 1.48x |
| mixed-transitions-65536 | utf8-to-utf16 | 30111.585 | 46806.499 | 35482.266 | 48643.061 | 170356.195 | 1.55x | 1.62x |
| mixed-transitions-65536 | utf16-to-utf8 | 41443.183 | 42024.880 | 46572.954 | 140468.350 | 135021.804 | 1.01x | 3.39x |
| mixed-sparse-4096 | utf8-to-utf16 | 420.382 | 413.967 | 436.133 | 621.525 | 2172.660 | 0.98x | 1.48x |
| mixed-sparse-4096 | utf16-to-utf8 | 478.402 | 480.714 | 826.236 | 371.562 | 2064.319 | 1.00x | 0.78x |
| mixed-sparse-65536 | utf8-to-utf16 | 7158.874 | 7374.032 | 7369.766 | 11112.923 | 43462.694 | 1.03x | 1.55x |
| mixed-sparse-65536 | utf16-to-utf8 | 8845.429 | 8873.367 | 19926.083 | 6379.610 | 39781.562 | 1.00x | 0.72x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1629.635 | 1815.475 | 1814.598 | 2566.665 | 3207.228 | 1.11x | 1.57x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1303.735 | 1304.536 | 1310.197 | 1840.273 | 1794.185 | 1.00x | 1.41x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 26386.888 | 30865.412 | 29839.138 | 41041.495 | 100949.554 | 1.17x | 1.56x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 24327.398 | 24448.637 | 29812.134 | 66471.119 | 70191.812 | 1.00x | 2.73x |

## Remaining work

Rows still slower than the fastest external caller-buffer API:

| Corpus | Direction | Current ns | Fastest external ns | Extra time |
|---|---|---:|---:|---:|
| mixed-4096 | utf16-to-utf8 | 1115.706 | 1030.884 | 8.2% |
| mixed-random-128 | utf16-to-utf8 | 63.463 | 62.525 | 1.5% |
| mixed-sparse-4096 | utf16-to-utf8 | 478.402 | 371.562 | 28.8% |
| mixed-sparse-65536 | utf16-to-utf8 | 8845.429 | 6379.610 | 38.7% |

Rows more than 5% slower than the immediate predecessor are also retained:

No row exceeds this threshold in the final five-round profile.

The wider objective still includes other APIs, non-repetitive phase changes,
and hardware beyond this x86-64 profile. Passing the current tests and selected
comparisons does not establish completion of that objective.

## Reproduce

Use the [external build commands](utf16-conversion-2026-11-26.md#reproduce).

```sh
zig build bench-utf16-build
for revision in 8faa08a 95bb5bc; do
  revision_dir="/tmp/icuz-unified-$revision"
  mkdir -p "$revision_dir"
  git archive "$revision" src/unicode/utf16.zig src/unicode/utf src/unicode/scalar | tar -x -C "$revision_dir"
  zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
    -O ReleaseFast -Mutf16="$revision_dir/src/unicode/utf16.zig" \
    -femit-bin="/tmp/icuz-unified-$revision-rebuilt"
done
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-unified-8faa08a-rebuilt --baseline-reuse \
  --reference /tmp/icuz-unified-95bb5bc-rebuilt \
  --external /tmp/icuz-transcode-external --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-unified-reproduced.json
```

For the x86-64 Linux checked-only counters, write the fixed-seed corpora from
`bench/utf16/corpus.py`, build `bench/utf16/profile/bench.zig` against both
source trees, and run 20,000 calls in alternating order:

```sh
python3 - <<'PY'
from pathlib import Path
import runpy
for name, text in runpy.run_path('bench/utf16/corpus.py')['cases']():
    if name in ('mixed-random-65536', 'mixed-transitions-65536'):
        Path('/tmp', name + '.bin').write_bytes(text)
PY
zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/profile/bench.zig \
  -O ReleaseFast -Mutf16=src/unicode/utf16.zig -femit-bin=/tmp/icuz-checked-current
perf stat -x, -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/branches/u,cpu_core/branch-misses/u \
  -- taskset -c 2 /tmp/icuz-checked-current /tmp/mixed-random-65536.bin 20000
```

## Validation

- Native ReleaseSafe UTF module: 28/28 passed.
- Baseline x86-64 ReleaseSafe UTF module: 26 passed, two AVX2 owner tests skipped.
- Debug guarded buffers: 4/4 passed.
- AArch64 and big-endian PowerPC64 ReleaseSafe compile-only checks passed.
- Full library ReleaseSafe: 4/4 steps succeeded, 538/538 tests passed.
- Unicode verifier: 431 blobs, 34 generated sources, 3 generated bitmaps,
  and 134 generators verified.
- Formatting, patch whitespace, all profile rows/content checks, and final
  source, input, profiler, and executable hash audits passed.

```sh
zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```
