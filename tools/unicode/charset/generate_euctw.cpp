// Generate the ICU EUC-TW tables.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_euctw.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_euctw
//   ./generate_euctw src/unicode/charset/euctw.bin

#include <unicode/ucnv.h>
#include <unicode/utypes.h>
#include <algorithm>
#include <cstdio>
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
    uint32_t key;
};

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }
    UErrorCode status = U_ZERO_ERROR;
    UConverter* converter = ucnv_open("EUC-TW", &status);
    if (U_FAILURE(status) || converter == nullptr) {
        std::fprintf(stderr, "cannot open EUC-TW: %s\n", u_errorName(status));
        return 1;
    }

    const int plane_count = 16;
    const int plane_size = 94 * 94;
    std::vector<uint32_t> forward(plane_count * plane_size, 0);
    std::vector<ReverseEntry> reverse;

    for (int plane = 0; plane < plane_count; plane++) {
        for (int row = 0; row < 94; row++) {
            for (int cell = 0; cell < 94; cell++) {
                char source[4];
                int source_length;
                if (plane == 0) {
                    source[0] = static_cast<char>(0xA1 + row);
                    source[1] = static_cast<char>(0xA1 + cell);
                    source_length = 2;
                } else {
                    source[0] = static_cast<char>(0x8E);
                    source[1] = static_cast<char>(0xA1 + plane);
                    source[2] = static_cast<char>(0xA1 + row);
                    source[3] = static_cast<char>(0xA1 + cell);
                    source_length = 4;
                }
                UChar target[4] = {0, 0, 0, 0};
                status = U_ZERO_ERROR;
                ucnv_reset(converter);
                const int32_t length = ucnv_toUChars(
                    converter,
                    target,
                    4,
                    source,
                    source_length,
                    &status);
                uint32_t codepoint = 0;
                if (U_SUCCESS(status)) {
                    if (length == 1 and target[0] != 0xFFFD) {
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
                const int pointer = plane * plane_size + row * 94 + cell;
                forward[pointer] = codepoint;
                if (codepoint != 0) {
                    const uint32_t key =
                        (static_cast<uint32_t>(plane) << 14) |
                        (static_cast<uint32_t>(row) << 7) |
                        static_cast<uint32_t>(cell);
                    reverse.push_back({codepoint, key});
                }
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
    const char magic[4] = {'C', 'J', 'G', 'U'};
    out.insert(out.end(), magic, magic + 4);
    out.push_back(1);
    out.push_back(0);
    out.push_back(0);
    out.push_back(0);
    putU32(out, plane_count);
    putU32(out, plane_size);
    for (uint32_t value : forward) {
        putU32(out, value);
    }
    putU32(out, static_cast<uint32_t>(reverse.size()));
    for (const ReverseEntry& entry : reverse) {
        putU32(out, entry.codepoint);
        putU32(out, entry.key);
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
