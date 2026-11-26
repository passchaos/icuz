// Strict caller-buffer conversion against current simdutf and ICU.
#include "simdutf.h"
#include <unicode/ustring.h>
#include <unicode/uversion.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

static volatile size_t input_salt = 0;
static size_t sink = 0;

template <class F> static void bench(const char *path, const char *direction,
    const char *library, size_t bytes, size_t expected, F convert) {
    const size_t rounds = std::max(size_t(2000), 8 * 1024 * 1024 / bytes);
    uint64_t best = std::numeric_limits<uint64_t>::max();
    for (int trial = 0; trial < 5; ++trial) {
        const auto start = std::chrono::steady_clock::now();
        for (size_t round = 0; round < rounds; ++round) {
            const auto count = convert(input_salt);
            sink += count;
        }
        const uint64_t elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - start).count();
        best = std::min(best, elapsed);
    }
    if (convert(0) != expected) std::abort();
    std::printf("%s\t%s\t%s\t%zu\t%.6f\t%zu\n", path, direction, library,
                bytes, double(best) / double(rounds), expected);
}

int main(int argc, char **argv) {
    const auto implementation = simdutf::get_active_implementation()->name();
    std::fprintf(stderr, "simdutf %s (%.*s), ICU %s\n", SIMDUTF_VERSION,
        int(implementation.size()), implementation.data(), U_ICU_VERSION);
    for (int arg = 1; arg < argc; ++arg) {
        std::ifstream file(argv[arg], std::ios::binary);
        if (!file) return 1;
        const std::string text((std::istreambuf_iterator<char>(file)), {});
        if (text.empty() || text.size() > 1024 * 1024) return 1;
        std::vector<char16_t> units(text.size());
        const auto count = simdutf::convert_utf8_to_utf16(text.data(), text.size(), units.data());
        if (!count) return 1;
        units.resize(count);
        std::vector<char16_t> wide(text.size());
        std::vector<char> narrow(units.size() * 3);
        bench(argv[arg], "utf8-to-utf16", "simdutf", text.size(), units.size(), [&](size_t salt) {
            return simdutf::convert_utf8_to_utf16(text.data()+salt, text.size()-salt, wide.data());
        });
        if (!std::equal(units.begin(), units.end(), wide.begin())) return 1;
        bench(argv[arg], "utf16-to-utf8", "simdutf", text.size(), text.size(), [&](size_t salt) {
            return simdutf::convert_utf16_to_utf8(units.data()+salt, units.size()-salt, narrow.data());
        });
        if (!std::equal(text.begin(), text.end(), narrow.begin())) return 1;
        bench(argv[arg], "utf8-to-utf16", "icu", text.size(), units.size(), [&](size_t salt) {
            UErrorCode status = U_ZERO_ERROR; int32_t length = 0;
            u_strFromUTF8(reinterpret_cast<UChar*>(wide.data()), int32_t(wide.size()), &length,
                text.data()+salt, int32_t(text.size()-salt), &status);
            if (U_FAILURE(status)) std::abort();
            return size_t(length);
        });
        if (!std::equal(units.begin(), units.end(), wide.begin())) return 1;
        bench(argv[arg], "utf16-to-utf8", "icu", text.size(), text.size(), [&](size_t salt) {
            UErrorCode status = U_ZERO_ERROR; int32_t length = 0;
            u_strToUTF8(narrow.data(), int32_t(narrow.size()), &length,
                reinterpret_cast<const UChar*>(units.data()+salt), int32_t(units.size()-salt), &status);
            if (U_FAILURE(status)) std::abort();
            return size_t(length);
        });
        if (!std::equal(text.begin(), text.end(), narrow.begin())) return 1;
    }
}
