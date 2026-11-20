// Generate the ICU SelectFormat and PluralFormat conformance fixture.
//
// Build with ICU 78 headers and libicui18n, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       -I $ICU/icu4c/source/i18n generate_plural_select_conformance.cpp \
//       -L $ICU_LIB -licuuc -licui18n -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_plural_select_conformance
//   ./generate_plural_select_conformance \
//       src/unicode/format/plural_select_conformance.bin

#include <unicode/locid.h>
#include <unicode/plurfmt.h>
#include <unicode/selfmt.h>
#include <unicode/unistr.h>
#include <unicode/utypes.h>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace icu;

static void putU8(std::vector<uint8_t>& out, uint8_t value) {
    out.push_back(value);
}

static void putU16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xff));
    out.push_back(static_cast<uint8_t>(value >> 8));
}

static void putU32(std::vector<uint8_t>& out, uint32_t value) {
    putU16(out, static_cast<uint16_t>(value & 0xffff));
    putU16(out, static_cast<uint16_t>(value >> 16));
}

static void putF64(std::vector<uint8_t>& out, double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    putU32(out, static_cast<uint32_t>(bits & 0xffffffffu));
    putU32(out, static_cast<uint32_t>(bits >> 32));
}

static void putString16(
    std::vector<uint8_t>& out,
    const UnicodeString& text
) {
    putU16(out, static_cast<uint16_t>(text.length()));
    for (int32_t i = 0; i < text.length(); i++) {
        putU16(out, static_cast<uint16_t>(text[i]));
    }
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }

    const char* select_patterns[] = {
        "female {She} male {He} other {They}",
        "a {X} b {Y} other {Z}",
        "0 {zero} 1 {one} other {many}",
    };
    const char* select_keys[] = {
        "female", "male", "unknown", "a", "b", "c", "0", "1", "2", "",
    };

    const char* plural_locales[] = {"en", "ru", "fr"};
    const char* plural_patterns[] = {
        "one {# item} other {# items}",
        "offset:1 one {# person} other {# people}",
        "=0 {nobody} one {# person} other {# people}",
        "one {# jour} other {# jours}",
        "one {# файл} few {# файла} many {# файлов} other {# файла}",
    };
    const double plural_values[] = {
        0, 1, 2, 1.5, -1, 3, 5, 21,
    };

    std::vector<uint8_t> records;
    uint32_t record_count = 0;

    for (uint8_t pattern_index = 0;
         pattern_index < sizeof(select_patterns) / sizeof(select_patterns[0]);
         pattern_index++) {
        UErrorCode status = U_ZERO_ERROR;
        SelectFormat format(
            UnicodeString::fromUTF8(select_patterns[pattern_index]),
            status);
        if (U_FAILURE(status)) {
            std::fprintf(
                stderr,
                "cannot build SelectFormat %s: %s\n",
                select_patterns[pattern_index],
                u_errorName(status));
            return 1;
        }
        for (const char* key : select_keys) {
            UnicodeString output;
            FieldPosition position(FieldPosition::DONT_CARE);
            status = U_ZERO_ERROR;
            format.format(
                UnicodeString::fromUTF8(key),
                output,
                position,
                status);
            putU8(records, 0);
            putU8(records, pattern_index);
            putString16(records, UnicodeString::fromUTF8(key));
            putString16(records, output);
            record_count++;
        }
    }

    const struct {
        uint8_t locale_index;
        uint8_t pattern_index;
    } plural_cases[] = {
        {0, 0},
        {0, 1},
        {0, 2},
        {0, 3},
        {1, 4},
        {2, 3},
    };
    for (const auto& item : plural_cases) {
        UErrorCode status = U_ZERO_ERROR;
        PluralFormat format(
            Locale(plural_locales[item.locale_index]),
            UnicodeString::fromUTF8(plural_patterns[item.pattern_index]),
            status);
        if (U_FAILURE(status)) {
            std::fprintf(
                stderr,
                "cannot build PluralFormat %s/%s: %s\n",
                plural_locales[item.locale_index],
                plural_patterns[item.pattern_index],
                u_errorName(status));
            return 1;
        }
        for (double value : plural_values) {
            UnicodeString output;
            FieldPosition position(FieldPosition::DONT_CARE);
            status = U_ZERO_ERROR;
            format.format(value, output, position, status);
            putU8(records, 1);
            putU8(records, item.locale_index);
            putU8(records, item.pattern_index);
            putF64(records, value);
            putString16(records, output);
            record_count++;
        }
    }

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'W'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);
    uint8_t count_bytes[4] = {
        static_cast<uint8_t>(record_count & 0xff),
        static_cast<uint8_t>((record_count >> 8) & 0xff),
        static_cast<uint8_t>((record_count >> 16) & 0xff),
        static_cast<uint8_t>((record_count >> 24) & 0xff),
    };
    std::fwrite(count_bytes, 1, 4, out);
    std::fwrite(records.data(), 1, records.size(), out);
    std::fclose(out);
    return 0;
}
