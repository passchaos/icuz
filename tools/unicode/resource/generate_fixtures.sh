#!/usr/bin/env bash
# Regenerate the ICU resource bundle fixtures and conformance trace.
#
# Requirements: ICU's genrb and ICU 78 headers/libraries.
# Override locations with GENRB, ICU_INC, and ICU_LIB.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
fixtures_dir="$repo_root/src/unicode/resource/fixtures"
genrb="${GENRB:-genrb}"
icu_inc="${ICU_INC:-/tmp/icu78/icu4c/source/common}"
icu_lib="${ICU_LIB:-/Users/bytedance/.pixi/envs/nodejs/lib}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/plain" "$work_dir/pool" "$work_dir/pooled"

sources=(
    "$script_dir/sources/root.txt"
    "$script_dir/sources/en.txt"
    "$script_dir/sources/en_US.txt"
)

"$genrb" -d "$work_dir/plain" "${sources[@]}"
"$genrb" -d "$work_dir/pool" --writePoolBundle "$work_dir/pool" "${sources[@]}"
"$genrb" -d "$work_dir/pooled" --usePoolBundle "$work_dir/pool" "${sources[@]}"

mkdir -p "$fixtures_dir"
cp "$work_dir/plain/root.res" "$fixtures_dir/root.res"
cp "$work_dir/plain/en.res" "$fixtures_dir/en.res"
cp "$work_dir/plain/en_US.res" "$fixtures_dir/en_US.res"
cp "$work_dir/pool/pool.res" "$fixtures_dir/pool.res"
cp "$work_dir/pooled/root.res" "$fixtures_dir/pooled_root.res"
cp "$work_dir/pooled/en.res" "$fixtures_dir/pooled_en.res"
cp "$work_dir/pooled/en_US.res" "$fixtures_dir/pooled_en_US.res"

clang++ -std=c++17 -I "$icu_inc" \
    "$script_dir/generate_conformance.cpp" \
    -L "$icu_lib" -licuuc -licudata -Wl,-rpath,"$icu_lib" \
    -o "$work_dir/generate_conformance"
"$work_dir/generate_conformance" \
    "$fixtures_dir" \
    "$repo_root/src/unicode/resource/res_conformance.bin"

echo "regenerated resource fixtures and conformance trace"
