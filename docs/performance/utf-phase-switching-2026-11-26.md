# UTF conversion across dense and sparse phases, 2026-11-26

Native UTF-16→UTF-8 conversion now reclassifies dense and sparse runs, and
UTF-8→native UTF-16 conversion can enter the mixed-window decoder after a
long ASCII prefix. The latter only checks density once after each ASCII
run; short non-ASCII bursts continue through the existing ASCII path.

Sparse→dense UTF-8 caller-buffer conversion falls from 209671.036 to 33063.868
ns/op (6.34x) against `6cc9f7f`.

Dense→sparse UTF-16 caller-buffer conversion falls from 20121.187 to 7117.129
ns/op (2.83x) against `6cc9f7f`.

Sparse UTF-16 caller-buffer conversion falls from 8852.391 to 7054.841
ns/op (1.25x) against `6cc9f7f`.

The minimum reuse latency is lower than both simdutf 9.5.0 and ICU 78.3
in 55/60 rows in this profile. This is one x86-64 CPU profile;
near-parity rows require repeated profiling, and the industry-best goal
remains active for the listed gaps, other APIs, and other hardware.

## Method and provenance

- Intel Core i9-13900K, Linux x86-64, logical CPU 2. Zig 0.16.0
  ReleaseFast native. Unchanged GCC 13 `-O3 -std=c++17` external harness,
  simdutf 9.5.0 `haswell` and ICU 78.3. simdutf source commit:
  `9064366fa571fac03bcd28db35af597e97fba842`.
- All original 26 fixed-seed [corpora](utf16-sparse-runs-2026-11-26.md#irregular-corpus)
  remain unchanged. Four additions combine a random or sparse prefix generated
  with a 256-byte minimum and the opposite family for the remaining input.
  Dense→sparse and sparse→dense cases have 4 KiB and 64 KiB minimum UTF-8 sizes;
  the final complete scalar may extend the minimum. Input hashes and exact
  byte/unit sizes remain in the raw profile.
- Five rounds, five trials per API row, at least 2,000 calls and an 8 MiB
  target per trial. Tables report the minimum across rounds. All samples remain
  in [JSON](utf-phase-switching-2026-11-26.json).
- Each corpus runs sequentially in current/external/6cc9f7f/8faa08a order,
  reversed in alternate rounds. This task's compilation and tests finish
  before sampling; hardware counters also finish before the latency profile.
- Owned APIs validate, size, allocate exactly, convert, and free. Reuse APIs
  perform strict conversion into warmed caller buffers. External controls
  use strict caller-buffer APIs, so only reuse is compared with them.
- The unchanged four-function measurement harness checks every result against
  independent std conversion. The external harness checks status, length, and
  content. The driver validates all required rows and byte/unit counts.
- `baseline` is the preserved `6cc9f7f` binary; `reference` is preserved
  `8faa08a`. Both hashes and the external hash match the committed
  [unified-window profile](utf8-unified-windows-2026-11-26.json). Current
  source, input, and executable hashes are recorded in this profile.

## Dispatch and bounds

A dedicated sparse UTF-16 loop encodes short non-ASCII bursts scalarly and
inlines the ASCII prefix copier, including its first partial window. A short
ASCII run returns to general classification. The dense BMP loop can also
return after sixteen proven ASCII units: eight were already encoded, and
the following eight are checked before returning. Checked conversion enables
this detection. Prevalidated conversion enables it when remaining output
overhead is below one quarter of remaining UTF-16 units, allowing exact
globally sparse owned outputs to adapt while ordinary dense owned loops
avoid that check. Output capacity affects only dispatch.

UTF-8 conversion counts non-ASCII bytes in the next bounded 64-byte window
after an ASCII run. More than half must be non-ASCII before the existing
mixed-candidate test can enter the window kernel. The candidate still excludes
homogeneous three-byte and four-byte runs, keeping their specialized blocks.
The count sum uses a wide integer, including the all-64-non-ASCII boundary.

All input loads and output stores retain their bounds. Partial ASCII stores
stay inside the spare output, which has at least one byte per remaining UTF-16
unit, and subsequent conversion replaces padding. Exact owned output sizes,
native endianness, invalid-input/OOM behavior, and prefix publication remain
covered by independent std oracles and guard pages. Non-LLVM ASCII loads
continue to use bounded arrays.

## Hardware counters

Both revisions use identical single-direction profiling harnesses, warmed
strict caller buffers, 30,000 calls, three alternating-order rounds on CPU 2,
and explicit user-mode `cpu_core` PMU events. Values are mean counts per API
call; whole-process setup and final content verification are included.
[Counter JSON](utf-phase-counters-2026-11-26.json) preserves raw perf CSV,
both source snapshot hashes, inputs, harness hashes, and executable hashes.

| Direction | Corpus | Event | 6cc9f7f | Current | Change |
|---|---|---|---:|---:|---:|
| utf16-to-utf8 | mixed-sparse-65536 | cycles | 35871.97 | 28266.23 | -21.2% |
| utf16-to-utf8 | mixed-sparse-65536 | instructions | 145504.25 | 114989.31 | -21.0% |
| utf16-to-utf8 | mixed-sparse-65536 | branches | 17605.77 | 18846.30 | +7.0% |
| utf16-to-utf8 | mixed-sparse-65536 | branch-misses | 0.84 | 0.99 | +19.0% |
| utf16-to-utf8 | mixed-dense-to-sparse-65536 | cycles | 80852.20 | 28574.90 | -64.7% |
| utf16-to-utf8 | mixed-dense-to-sparse-65536 | instructions | 279186.95 | 117390.14 | -58.0% |
| utf16-to-utf8 | mixed-dense-to-sparse-65536 | branches | 53553.15 | 19181.30 | -64.2% |
| utf16-to-utf8 | mixed-dense-to-sparse-65536 | branch-misses | 887.94 | 0.76 | -99.9% |
| utf16-to-utf8 | mixed-sparse-to-dense-65536 | cycles | 273575.30 | 225832.13 | -17.5% |
| utf16-to-utf8 | mixed-sparse-to-dense-65536 | instructions | 646801.21 | 552698.40 | -14.5% |
| utf16-to-utf8 | mixed-sparse-to-dense-65536 | branches | 79413.52 | 73634.84 | -7.3% |
| utf16-to-utf8 | mixed-sparse-to-dense-65536 | branch-misses | 4900.44 | 4066.95 | -17.0% |
| utf8-to-utf16 | mixed-sparse-65536 | cycles | 29593.00 | 29905.89 | +1.1% |
| utf8-to-utf16 | mixed-sparse-65536 | instructions | 165871.96 | 171286.98 | +3.3% |
| utf8-to-utf16 | mixed-sparse-65536 | branches | 31384.87 | 32076.31 | +2.2% |
| utf8-to-utf16 | mixed-sparse-65536 | branch-misses | 2.27 | 1.72 | -24.1% |
| utf8-to-utf16 | mixed-sparse-to-dense-65536 | cycles | 849708.19 | 132136.33 | -84.4% |
| utf8-to-utf16 | mixed-sparse-to-dense-65536 | instructions | 1468607.26 | 528039.09 | -64.0% |
| utf8-to-utf16 | mixed-sparse-to-dense-65536 | branches | 312961.51 | 53331.49 | -83.0% |
| utf8-to-utf16 | mixed-sparse-to-dense-65536 | branch-misses | 20405.80 | 47.88 | -99.8% |

The isolated LLVM UTF-16 consumer previously reproduced a Zig 0.16.0
`Assigned value does not match type of forward declaration` failure in
unstripped ReleaseFast/ReleaseSafe builds, including predecessors `95bb5bc`
and `854fca0`. Non-LLVM Debug and LLVM `-fstrip` compile, and the ordinary
two-direction benchmark compiles. The error appears in LLVM bitcode/debug
information handling; public API/source changes tried during diagnosis were
reverted. This profile therefore uses matched `-fstrip` builds for both
single-direction counter harnesses. The library and main benchmark keep
their normal build configuration.

## Owned output comparison

Speedup is predecessor/current. Values below one mean current takes longer.

| Corpus | Direction | Current ns | 6cc9f7f ns | 8faa08a ns | vs 6cc9f7f |
|---|---|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.947 | 26.729 | 26.701 | 0.99x |
| ascii-32 | utf16-to-utf8 | 20.092 | 20.090 | 20.087 | 1.00x |
| ascii-128 | utf8-to-utf16 | 27.374 | 27.747 | 27.654 | 1.01x |
| ascii-128 | utf16-to-utf8 | 24.773 | 24.800 | 24.796 | 1.00x |
| ascii-4096 | utf8-to-utf16 | 240.792 | 240.573 | 244.038 | 1.00x |
| ascii-4096 | utf16-to-utf8 | 289.157 | 289.636 | 288.832 | 1.00x |
| latin-32 | utf8-to-utf16 | 52.777 | 52.593 | 52.623 | 1.00x |
| latin-32 | utf16-to-utf8 | 32.219 | 32.237 | 32.243 | 1.00x |
| latin-128 | utf8-to-utf16 | 94.751 | 94.504 | 94.822 | 1.00x |
| latin-128 | utf16-to-utf8 | 51.994 | 50.601 | 51.301 | 0.97x |
| latin-4096 | utf8-to-utf16 | 1757.497 | 1758.557 | 1760.081 | 1.00x |
| latin-4096 | utf16-to-utf8 | 887.716 | 885.909 | 885.932 | 1.00x |
| chinese-32 | utf8-to-utf16 | 26.156 | 26.137 | 26.169 | 1.00x |
| chinese-32 | utf16-to-utf8 | 23.104 | 23.110 | 23.097 | 1.00x |
| chinese-128 | utf8-to-utf16 | 35.055 | 35.283 | 34.988 | 1.01x |
| chinese-128 | utf16-to-utf8 | 23.125 | 23.082 | 23.117 | 1.00x |
| chinese-4096 | utf8-to-utf16 | 548.892 | 550.613 | 551.731 | 1.00x |
| chinese-4096 | utf16-to-utf8 | 388.210 | 380.061 | 380.200 | 0.98x |
| mixed-32 | utf8-to-utf16 | 72.401 | 72.340 | 74.747 | 1.00x |
| mixed-32 | utf16-to-utf8 | 53.700 | 54.244 | 53.330 | 1.01x |
| mixed-128 | utf8-to-utf16 | 125.971 | 124.679 | 127.811 | 0.99x |
| mixed-128 | utf16-to-utf8 | 91.961 | 91.469 | 90.973 | 0.99x |
| mixed-4096 | utf8-to-utf16 | 2089.280 | 2092.064 | 2079.613 | 1.00x |
| mixed-4096 | utf16-to-utf8 | 1465.069 | 1463.185 | 1464.085 | 1.00x |
| emoji-32 | utf8-to-utf16 | 30.136 | 29.633 | 29.630 | 0.98x |
| emoji-32 | utf16-to-utf8 | 22.130 | 22.184 | 22.118 | 1.00x |
| emoji-128 | utf8-to-utf16 | 47.794 | 47.224 | 47.636 | 0.99x |
| emoji-128 | utf16-to-utf8 | 36.659 | 34.618 | 35.827 | 0.94x |
| emoji-4096 | utf8-to-utf16 | 834.751 | 820.471 | 826.986 | 0.98x |
| emoji-4096 | utf16-to-utf8 | 702.437 | 703.060 | 701.297 | 1.00x |
| tiny-ascii-31 | utf8-to-utf16 | 29.259 | 29.085 | 29.269 | 0.99x |
| tiny-ascii-31 | utf16-to-utf8 | 21.836 | 21.832 | 21.821 | 1.00x |
| tiny-emoji-31 | utf8-to-utf16 | 20.825 | 20.661 | 20.646 | 0.99x |
| tiny-emoji-31 | utf16-to-utf8 | 17.614 | 17.626 | 17.617 | 1.00x |
| mixed-random-128 | utf8-to-utf16 | 86.747 | 84.616 | 88.541 | 0.98x |
| mixed-random-128 | utf16-to-utf8 | 79.224 | 77.415 | 78.531 | 0.98x |
| mixed-random-4096 | utf8-to-utf16 | 2186.976 | 2174.397 | 2197.506 | 0.99x |
| mixed-random-4096 | utf16-to-utf8 | 1854.881 | 1855.238 | 1853.391 | 1.00x |
| mixed-random-65536 | utf8-to-utf16 | 56602.462 | 58046.870 | 66151.377 | 1.03x |
| mixed-random-65536 | utf16-to-utf8 | 80914.436 | 80203.273 | 80777.048 | 0.99x |
| mixed-transitions-4096 | utf8-to-utf16 | 2036.395 | 2010.647 | 2044.275 | 0.99x |
| mixed-transitions-4096 | utf16-to-utf8 | 1751.508 | 1742.144 | 1743.211 | 0.99x |
| mixed-transitions-65536 | utf8-to-utf16 | 50647.013 | 50557.239 | 54163.212 | 1.00x |
| mixed-transitions-65536 | utf16-to-utf8 | 71545.840 | 69242.793 | 69462.719 | 0.97x |
| mixed-sparse-4096 | utf8-to-utf16 | 617.819 | 623.935 | 655.996 | 1.01x |
| mixed-sparse-4096 | utf16-to-utf8 | 612.209 | 724.057 | 724.883 | 1.18x |
| mixed-sparse-65536 | utf8-to-utf16 | 39300.359 | 38818.277 | 40393.637 | 0.99x |
| mixed-sparse-65536 | utf16-to-utf8 | 27005.268 | 28928.508 | 29204.240 | 1.07x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1816.968 | 1804.919 | 1941.516 | 0.99x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1709.634 | 1708.148 | 1708.309 | 1.00x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 46793.846 | 46565.573 | 49430.618 | 1.00x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 67745.571 | 66065.516 | 66430.003 | 0.98x |
| mixed-dense-to-sparse-4096 | utf8-to-utf16 | 794.410 | 787.859 | 785.540 | 0.99x |
| mixed-dense-to-sparse-4096 | utf16-to-utf8 | 707.861 | 1134.453 | 1112.773 | 1.60x |
| mixed-sparse-to-dense-4096 | utf8-to-utf16 | 2108.734 | 3523.833 | 4031.590 | 1.67x |
| mixed-sparse-to-dense-4096 | utf16-to-utf8 | 1784.380 | 2131.202 | 2132.593 | 1.19x |
| mixed-dense-to-sparse-65536 | utf8-to-utf16 | 40582.681 | 40009.637 | 40163.632 | 0.99x |
| mixed-dense-to-sparse-65536 | utf16-to-utf8 | 27884.866 | 41607.465 | 41575.366 | 1.49x |
| mixed-sparse-to-dense-65536 | utf8-to-utf16 | 57410.325 | 227361.326 | 231918.578 | 3.96x |
| mixed-sparse-to-dense-65536 | utf16-to-utf8 | 80962.091 | 97494.435 | 97711.728 | 1.20x |

## Strict caller-buffer comparison

| Corpus | Direction | Current ns | 6cc9f7f ns | 8faa08a ns | simdutf ns | ICU ns | vs 6cc9f7f | vs fastest external |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.760 | 4.510 | 4.510 | 12.423 | 36.980 | 0.95x | 2.61x |
| ascii-32 | utf16-to-utf8 | 3.508 | 3.508 | 3.508 | 10.423 | 35.619 | 1.00x | 2.97x |
| ascii-128 | utf8-to-utf16 | 6.752 | 6.516 | 6.518 | 9.897 | 94.531 | 0.97x | 1.47x |
| ascii-128 | utf16-to-utf8 | 6.774 | 6.775 | 6.810 | 13.781 | 92.660 | 1.00x | 2.03x |
| ascii-4096 | utf8-to-utf16 | 97.210 | 97.213 | 97.229 | 110.750 | 2098.075 | 1.00x | 1.14x |
| ascii-4096 | utf16-to-utf8 | 111.887 | 111.977 | 112.059 | 198.005 | 2085.103 | 1.00x | 1.77x |
| latin-32 | utf8-to-utf16 | 36.131 | 35.806 | 35.802 | 37.300 | 38.161 | 0.99x | 1.03x |
| latin-32 | utf16-to-utf8 | 12.550 | 12.552 | 12.552 | 23.502 | 28.346 | 1.00x | 1.87x |
| latin-128 | utf8-to-utf16 | 69.130 | 69.148 | 69.191 | 87.671 | 91.855 | 1.00x | 1.27x |
| latin-128 | utf16-to-utf8 | 23.553 | 23.589 | 23.561 | 35.238 | 70.550 | 1.00x | 1.50x |
| latin-4096 | utf8-to-utf16 | 1532.864 | 1529.125 | 1529.785 | 1894.631 | 2170.619 | 1.00x | 1.24x |
| latin-4096 | utf16-to-utf8 | 471.414 | 467.411 | 468.197 | 610.789 | 1644.218 | 0.99x | 1.30x |
| chinese-32 | utf8-to-utf16 | 11.715 | 13.630 | 13.584 | 23.191 | 23.835 | 1.16x | 1.98x |
| chinese-32 | utf16-to-utf8 | 9.821 | 9.879 | 10.032 | 18.251 | 18.722 | 1.01x | 1.86x |
| chinese-128 | utf8-to-utf16 | 13.586 | 13.608 | 13.613 | 79.809 | 87.592 | 1.00x | 5.87x |
| chinese-128 | utf16-to-utf8 | 10.803 | 10.810 | 10.715 | 32.459 | 63.340 | 1.00x | 3.00x |
| chinese-4096 | utf8-to-utf16 | 354.453 | 359.803 | 359.636 | 947.665 | 2076.919 | 1.02x | 2.67x |
| chinese-4096 | utf16-to-utf8 | 276.359 | 271.582 | 271.787 | 414.041 | 1388.918 | 0.98x | 1.50x |
| mixed-32 | utf8-to-utf16 | 58.004 | 54.054 | 55.435 | 68.207 | 67.291 | 0.93x | 1.16x |
| mixed-32 | utf16-to-utf8 | 39.522 | 39.595 | 39.417 | 46.683 | 49.913 | 1.00x | 1.18x |
| mixed-128 | utf8-to-utf16 | 103.882 | 100.618 | 100.678 | 121.361 | 123.538 | 0.97x | 1.17x |
| mixed-128 | utf16-to-utf8 | 67.459 | 67.094 | 67.466 | 76.385 | 90.989 | 0.99x | 1.13x |
| mixed-4096 | utf8-to-utf16 | 1869.063 | 1883.867 | 1838.864 | 1920.708 | 2258.307 | 1.01x | 1.03x |
| mixed-4096 | utf16-to-utf8 | 1158.691 | 1128.536 | 1128.831 | 1030.767 | 1631.994 | 0.97x | 0.89x |
| emoji-32 | utf8-to-utf16 | 12.507 | 12.844 | 13.001 | 31.227 | 57.249 | 1.03x | 2.50x |
| emoji-32 | utf16-to-utf8 | 9.304 | 9.773 | 10.027 | 28.105 | 28.522 | 1.05x | 3.02x |
| emoji-128 | utf8-to-utf16 | 26.636 | 26.624 | 26.647 | 99.234 | 152.489 | 1.00x | 3.73x |
| emoji-128 | utf16-to-utf8 | 18.237 | 18.060 | 18.051 | 73.522 | 77.925 | 0.99x | 4.03x |
| emoji-4096 | utf8-to-utf16 | 587.056 | 591.534 | 591.979 | 2345.868 | 3669.066 | 1.01x | 4.00x |
| emoji-4096 | utf16-to-utf8 | 396.642 | 396.577 | 396.799 | 1963.665 | 1950.168 | 1.00x | 4.92x |
| tiny-ascii-31 | utf8-to-utf16 | 5.267 | 5.266 | 5.269 | 11.852 | 24.252 | 1.00x | 2.25x |
| tiny-ascii-31 | utf16-to-utf8 | 3.508 | 3.513 | 3.510 | 11.158 | 22.350 | 1.00x | 3.18x |
| tiny-emoji-31 | utf8-to-utf16 | 5.387 | 5.384 | 5.374 | 21.855 | 37.907 | 1.00x | 4.06x |
| tiny-emoji-31 | utf16-to-utf8 | 5.039 | 5.032 | 5.056 | 19.345 | 21.214 | 1.00x | 3.84x |
| mixed-random-128 | utf8-to-utf16 | 71.961 | 70.368 | 71.045 | 84.666 | 90.050 | 0.98x | 1.18x |
| mixed-random-128 | utf16-to-utf8 | 63.514 | 63.439 | 63.497 | 65.935 | 62.065 | 1.00x | 0.98x |
| mixed-random-4096 | utf8-to-utf16 | 1988.253 | 1984.900 | 2021.143 | 2510.599 | 2446.764 | 1.00x | 1.23x |
| mixed-random-4096 | utf16-to-utf8 | 1532.157 | 1527.762 | 1522.004 | 2036.688 | 1938.044 | 1.00x | 1.26x |
| mixed-random-65536 | utf8-to-utf16 | 33076.951 | 33553.579 | 52686.253 | 62295.916 | 220698.617 | 1.01x | 1.88x |
| mixed-random-65536 | utf16-to-utf8 | 56857.885 | 57567.944 | 58032.944 | 154843.915 | 183662.401 | 1.01x | 2.72x |
| mixed-transitions-4096 | utf8-to-utf16 | 1835.954 | 1827.044 | 1893.474 | 2353.642 | 2549.744 | 1.00x | 1.28x |
| mixed-transitions-4096 | utf16-to-utf8 | 1442.167 | 1422.599 | 1422.543 | 2139.414 | 1836.871 | 0.99x | 1.27x |
| mixed-transitions-65536 | utf8-to-utf16 | 30030.232 | 30152.895 | 46106.432 | 48986.412 | 170528.826 | 1.00x | 1.63x |
| mixed-transitions-65536 | utf16-to-utf8 | 40177.682 | 41269.666 | 41471.555 | 140756.283 | 136363.650 | 1.03x | 3.39x |
| mixed-sparse-4096 | utf8-to-utf16 | 433.510 | 418.451 | 416.922 | 621.099 | 2175.090 | 0.97x | 1.43x |
| mixed-sparse-4096 | utf16-to-utf8 | 368.871 | 480.916 | 479.901 | 371.231 | 2061.583 | 1.30x | 1.01x |
| mixed-sparse-65536 | utf8-to-utf16 | 7545.806 | 7354.410 | 7224.486 | 11110.707 | 43448.440 | 0.97x | 1.47x |
| mixed-sparse-65536 | utf16-to-utf8 | 7054.841 | 8852.391 | 8853.198 | 6429.161 | 39719.162 | 1.25x | 0.91x |
| mixed-surrogate-heavy-4096 | utf8-to-utf16 | 1624.804 | 1627.887 | 1814.661 | 2567.122 | 3187.885 | 1.00x | 1.58x |
| mixed-surrogate-heavy-4096 | utf16-to-utf8 | 1305.336 | 1304.741 | 1304.505 | 1847.035 | 1795.810 | 1.00x | 1.38x |
| mixed-surrogate-heavy-65536 | utf8-to-utf16 | 30040.409 | 26409.423 | 30792.131 | 41075.038 | 100874.128 | 0.88x | 1.37x |
| mixed-surrogate-heavy-65536 | utf16-to-utf8 | 24618.901 | 24500.726 | 24475.725 | 66161.535 | 70166.879 | 1.00x | 2.69x |
| mixed-dense-to-sparse-4096 | utf8-to-utf16 | 720.115 | 714.969 | 716.644 | 782.293 | 2150.008 | 0.99x | 1.09x |
| mixed-dense-to-sparse-4096 | utf16-to-utf8 | 465.875 | 981.265 | 984.321 | 440.347 | 2070.018 | 2.11x | 0.95x |
| mixed-sparse-to-dense-4096 | utf8-to-utf16 | 1895.659 | 3577.501 | 3593.175 | 2399.759 | 2426.529 | 1.89x | 1.27x |
| mixed-sparse-to-dense-4096 | utf16-to-utf8 | 1459.036 | 1804.245 | 1797.052 | 1960.682 | 1927.104 | 1.24x | 1.32x |
| mixed-dense-to-sparse-65536 | utf8-to-utf16 | 11250.770 | 11195.095 | 11226.445 | 11304.565 | 43582.531 | 1.00x | 1.00x |
| mixed-dense-to-sparse-65536 | utf16-to-utf8 | 7117.129 | 20121.187 | 20166.099 | 6497.228 | 39707.631 | 2.83x | 0.91x |
| mixed-sparse-to-dense-65536 | utf8-to-utf16 | 33063.868 | 209671.036 | 209314.859 | 61932.819 | 220195.060 | 6.34x | 1.87x |
| mixed-sparse-to-dense-65536 | utf16-to-utf8 | 56445.408 | 67371.459 | 67516.841 | 154221.256 | 183072.302 | 1.19x | 2.73x |

## Remaining measured gaps

These rows have a higher minimum reuse latency than the fastest external
control. Small differences within this profile do not establish a durable
ranking; all corpus and contract rows remain above for review.

| Corpus | Direction | Current ns | Fastest external ns | Current/external |
|---|---|---:|---:|---:|
| mixed-4096 | utf16-to-utf8 | 1158.691 | 1030.767 | 1.124x |
| mixed-random-128 | utf16-to-utf8 | 63.514 | 62.065 | 1.023x |
| mixed-sparse-65536 | utf16-to-utf8 | 7054.841 | 6429.161 | 1.097x |
| mixed-dense-to-sparse-4096 | utf16-to-utf8 | 465.875 | 440.347 | 1.058x |
| mixed-dense-to-sparse-65536 | utf16-to-utf8 | 7117.129 | 6497.228 | 1.095x |

## Reproduce

```sh
zig build bench-utf16-build
python3 bench/utf16/compare.py \
  --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-utf16-6cc9f7f --baseline-reuse \
  --reference /tmp/icuz-utf16-8faa08a \
  --external /tmp/icuz-transcode-external \
  --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-phase-switching.json
zig build-exe -O ReleaseFast -fstrip -lc --dep utf16 \
  -Mroot=bench/utf16/profile/to_utf8.zig \
  -O ReleaseFast -Mutf16=src/unicode/utf16.zig \
  -femit-bin=/tmp/icuz-utf16-checked
perf stat -x, \
  -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/branches/u,cpu_core/branch-misses/u \
  -- taskset -c 2 /tmp/icuz-utf16-checked /tmp/mixed-sparse-65536.bin 30000
```

Preserved benchmark binaries are verified controls; to reconstruct them,
build the identical `bench/utf16/bench.zig` at each named revision with the
same Zig version and flags. Generate the input files with
`bench/utf16/corpus.py`; the previous
[profile instructions](utf8-unified-windows-2026-11-26.md#reproduce)
show the file-writing procedure. For UTF-8 hardware counters use
`bench/utf16/profile/bench.zig` with the same stripped flags. Rebuild the
single-direction harness against each source snapshot and alternate order;
the complete source and executable hashes remain in counter JSON.

## Validation

- Native ReleaseSafe UTF module: 30/30 passed.
- Baseline x86-64 ReleaseSafe UTF module: 28 passed, two AVX2 owner tests skipped.
- Debug guarded buffers: 4/4 passed. Every partial ASCII stop through 257
  units, dense/sparse transitions, and long ASCII prefixes followed by Latin,
  Chinese, supplementary, and mixed text are covered.
- Phase oracles check exact owned allocations, exact/spare caller capacities,
  native endianness, malformed surrogate/UTF-8 neighbors, preserved prefixes,
  and invalid-input precedence when a failing allocator is supplied.
- AArch64 and big-endian PowerPC64 ReleaseSafe compile-only checks passed.
- Full library ReleaseSafe: 4/4 steps succeeded, 540/540 tests passed.
- Unicode verifier: 431 blobs, 34 generated sources, three generated bitmaps,
  and 134 generators verified.
- Formatting, patch whitespace, every profile row/content check, and final
  input, source, harness, executable, and preserved-control hash audits passed.
