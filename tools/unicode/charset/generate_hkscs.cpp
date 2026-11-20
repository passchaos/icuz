// Generate the ICU Big5-HKSCS tables.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_hkscs.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_hkscs
//   ./generate_hkscs src/unicode/charset/hkscs.bin

#include <unicode/ucnv.h>
#include <unicode/utypes.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <vector>

static void putU16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xff));
    out.push_back(static_cast<uint8_t>(value >> 8));
}

static void putU32(std::vector<uint8_t>& out, uint32_t value) {
    putU16(out, static_cast<uint16_t>(value & 0xffff));
    putU16(out, static_cast<uint16_t>(value >> 16));
}

struct ReverseEntry {
    uint32_t codepoint;
    uint16_t pointer;
};

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }
    UErrorCode status = U_ZERO_ERROR;
    UConverter* converter = ucnv_open("Big5-HKSCS", &status);
    if (U_FAILURE(status) || converter == nullptr) {
        std::fprintf(stderr, "cannot open Big5-HKSCS: %s\n", u_errorName(status));
        return 1;
    }

    const int lead_count = 0xFE - 0x81 + 1;
    const int trail_count = 63 + (0xFE - 0x80 + 1);
    std::vector<uint32_t> forward(
        static_cast<size_t>(lead_count) * trail_count,
        0);
    std::vector<ReverseEntry> reverse;

    for (int lead = 0x81; lead <= 0xFE; lead++) {
        for (int trail_index = 0; trail_index < trail_count; trail_index++) {
            const int trail = trail_index < 63
                ? 0x40 + trail_index
                : 0x80 + (trail_index - 63);
            char source[2] = {
                static_cast<char>(lead),
                static_cast<char>(trail),
            };
            UChar target[4] = {0, 0, 0, 0};
            status = U_ZERO_ERROR;
            ucnv_reset(converter);
            const int32_t length = ucnv_toUChars(
                converter,
                target,
                4,
                source,
                2,
                &status);
            uint32_t codepoint = 0;
            if (U_SUCCESS(status)) {
                if (length == 1) {
                    codepoint = target[0];
                } else if (length == 2 and
                    target[0] >= 0xD800 and target[0] <= 0xDBFF and
                    target[1] >= 0xDC00 and target[1] <= 0xDFFF)
                {
                    codepoint = 0x10000 +
                        ((static_cast<uint32_t>(target[0] - 0xD800)) << 10) +
                        (target[1] - 0xDC00);
                }
            }
            const size_t pointer =
                static_cast<size_t>(lead - 0x81) * trail_count +
                trail_index;
            forward[pointer] = codepoint;
            if (codepoint != 0) {
                reverse.push_back({
                    codepoint,
                    static_cast<uint16_t>(pointer),
                });
            }
        }
    }
    ucnv_close(converter);
    std::sort(
        reverse.begin(),
        reverse.end(),
        [](const ReverseEntry& a, const ReverseEntry& b) {
            return a.codepoint < b.codepoint;
        });

    std::vector<uint8_t> out;
    const char magic[4] = {'C', 'J', 'G', 'S'};
    out.insert(out.end(), magic, magic + 4);
    out.push_back(1);
    out.push_back(0);
    out.push_back(0);
    out.push_back(0);
    putU32(out, static_cast<uint32_t>(lead_count));
    putU32(out, static_cast<uint32_t>(trail_count));
    for (uint32_t value : forward) {
        putU32(out, value);
    }
    putU32(out, static_cast<uint32_t>(reverse.size()));
    for (const ReverseEntry& entry : reverse) {
        putU32(out, entry.codepoint);
        putU16(out, entry.pointer);
    }

    FILE* file = std::fopen(argv[1], "wb");
    if (file == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    std::fwrite(out.data(), 1, out.size(), file);
    std::fclose(file);
    return 0;
}
