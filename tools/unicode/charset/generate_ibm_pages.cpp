// Generate the ICU IBM code page tables.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_ibm_pages.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_ibm_pages
//   ./generate_ibm_pages src/unicode/charset/ibm_pages.bin

#include <unicode/ucnv.h>
#include <unicode/utypes.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static void putU16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xff));
    out.push_back(static_cast<uint8_t>(value >> 8));
}

struct Page {
    const char* converter;
    const char* name;
};

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }
    const Page pages[] = {
        {"ibm-437", "ibm-437"},
        {"ibm-850", "ibm-850"},
        {"ibm-852", "ibm-852"},
        {"ibm-855", "ibm-855"},
        {"ibm-857", "ibm-857"},
        {"ibm-858", "ibm-858"},
        {"ibm-860", "ibm-860"},
        {"ibm-861", "ibm-861"},
        {"ibm-862", "ibm-862"},
        {"ibm-863", "ibm-863"},
        {"ibm-864", "ibm-864"},
        {"ibm-865", "ibm-865"},
        {"ibm-869", "ibm-869"},
        {"ibm-1026", "ibm-1026"},
        {"ibm-1047", "ibm-1047"},
        {"ibm-1140", "ibm-1140"},
        {"ibm-1141", "ibm-1141"},
        {"ibm-1142", "ibm-1142"},
        {"ibm-1143", "ibm-1143"},
        {"ibm-1144", "ibm-1144"},
        {"ibm-1145", "ibm-1145"},
        {"ibm-1146", "ibm-1146"},
        {"ibm-1147", "ibm-1147"},
        {"ibm-1148", "ibm-1148"},
        {"ibm-1149", "ibm-1149"},
        {"ibm-1160", "ibm-1160"},
        {"ibm-1162", "ibm-1162"},
        {"ibm-1164", "ibm-1164"},
    };

    std::vector<uint8_t> body;
    for (const Page& page : pages) {
        UErrorCode status = U_ZERO_ERROR;
        UConverter* converter = ucnv_open(page.converter, &status);
        if (U_FAILURE(status) || converter == nullptr) {
            std::fprintf(
                stderr,
                "cannot open %s: %s\n",
                page.converter,
                u_errorName(status));
            return 1;
        }
        uint16_t table[256];
        bool ascii_compatible = true;
        for (int byte = 0; byte < 256; byte++) {
            status = U_ZERO_ERROR;
            ucnv_reset(converter);
            char source = static_cast<char>(byte);
            UChar target[4] = {0, 0, 0, 0};
            const int32_t length = ucnv_toUChars(
                converter,
                target,
                4,
                &source,
                1,
                &status);
            uint16_t value = 0xFFFF;
            if (U_SUCCESS(status) && length == 1) {
                value = static_cast<uint16_t>(target[0]);
            }
            table[byte] = value;
            if (byte < 0x80 and value != byte) ascii_compatible = false;
        }
        putU16(body, static_cast<uint16_t>(std::strlen(page.name)));
        body.insert(
            body.end(),
            page.name,
            page.name + std::strlen(page.name));
        body.push_back(ascii_compatible ? 1 : 0);
        body.push_back(0);
        for (int byte = 0; byte < 256; byte++) {
            putU16(body, table[byte]);
        }
        ucnv_close(converter);
    }

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'Q'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::vector<uint8_t> header;
    putU16(header, static_cast<uint16_t>(sizeof(pages) / sizeof(pages[0])));
    putU16(header, 0);
    std::fwrite(header.data(), 1, header.size(), out);
    std::fwrite(body.data(), 1, body.size(), out);
    std::fclose(out);
    return 0;
}
