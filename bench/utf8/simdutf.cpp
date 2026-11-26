// Build with the simdutf amalgamation or a separately installed library.
#include "simdutf.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>

static volatile size_t length_salt = 0;

int main(int argc, char **argv) {
    const auto implementation = simdutf::get_active_implementation()->name();
    std::fprintf(stderr, "simdutf %s (%.*s)\n", SIMDUTF_VERSION,
                 int(implementation.size()), implementation.data());
    for (int arg = 1; arg < argc; ++arg) {
        std::ifstream file(argv[arg], std::ios::binary);
        if (!file) return 1;
        const std::string text((std::istreambuf_iterator<char>(file)), {});
        if (text.empty() || text.size() > 1024 * 1024) return 1;
        const auto first = static_cast<unsigned char>(text[0]);
        const bool immediate_reject = (first >= 0x80 && first < 0xc2) || first >= 0xf5;
        const size_t rounds = std::max(size_t(immediate_reject ? 2000000 : 2000),
                                      16 * 1024 * 1024 / text.size());
        uint64_t best = std::numeric_limits<uint64_t>::max();
        size_t count = 0;
        for (int trial = 0; trial < 5; ++trial) {
            const auto start = std::chrono::steady_clock::now();
            for (size_t round = 0; round < rounds; ++round) {
                const auto salt = length_salt;
                count += simdutf::validate_utf8(text.data() + salt, text.size() - salt);
            }
            const uint64_t elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start).count();
            best = std::min(best, elapsed);
        }
        const double ns = double(best) / double(rounds);
        std::printf("%s\t%zu\t%.6f\t%.6f\t%zu\n", argv[arg], text.size(),
                    ns, ns / double(text.size()), count);
    }
}
