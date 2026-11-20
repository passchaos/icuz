// Generate the ICU DecimalFormat conformance fixture.
//
// Build with ICU 78 headers and libicui18n, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       -I $ICU/icu4c/source/i18n generate_decimal_conformance.cpp \
//       -L $ICU_LIB -licuuc -licui18n -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_decimal_conformance
//   ./generate_decimal_conformance src/unicode/format/decimal_conformance.bin

#include <unicode/decimfmt.h>
#include <unicode/locid.h>
#include <unicode/unistr.h>
#include <unicode/utypes.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

using namespace icu;

struct PatternCase {
    const char* pattern;
    bool currency;
};

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

static void putUtf8(std::vector<uint8_t>& out, const std::string& text) {
    putU16(out, static_cast<uint16_t>(text.size()));
    out.insert(out.end(), text.begin(), text.end());
}

static uint32_t utf16IndexToUtf8Offset(
    const UnicodeString& text,
    int32_t index
) {
    if (index <= 0) return 0;
    if (index > text.length()) index = text.length();
    std::string prefix;
    text.tempSubString(0, index).toUTF8String(prefix);
    return static_cast<uint32_t>(prefix.size());
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }

    const PatternCase patterns[] = {
        {"#,##0.00", false},
        {"#,##0.00;(#,##0.00)", false},
        {"0.###", false},
        {"0000", false},
        {"#,##0%", false},
        {"\u00a4#,##0.00", true},
        {"#,##0.00 'kg'", false},
        {"#,##0.0", false},
        {"#,##0", false},
        {"0.00\u2030", false},
    };
    const char* locales[] = {"en", "de", "fr"};
    const double values[] = {
        -1234.5,
        -1.5,
        -0.5,
        0,
        0.0051,
        0.5,
        1,
        1.5,
        42,
        1234.5,
        1234567.891,
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
    };

    std::vector<uint8_t> records;
    uint32_t record_count = 0;
    for (uint8_t locale_index = 0; locale_index < 3; locale_index++) {
        for (uint8_t pattern_index = 0;
             pattern_index < sizeof(patterns) / sizeof(patterns[0]);
             pattern_index++) {
            UErrorCode status = U_ZERO_ERROR;
            DecimalFormatSymbols symbols(Locale(locales[locale_index]), status);
            DecimalFormat format(
                UnicodeString::fromUTF8(patterns[pattern_index].pattern),
                symbols,
                status);
            if (U_FAILURE(status)) {
                std::fprintf(
                    stderr,
                    "cannot build format %s/%s: %s\n",
                    locales[locale_index],
                    patterns[pattern_index].pattern,
                    u_errorName(status));
                return 1;
            }
            if (patterns[pattern_index].currency) {
                format.setCurrency(u"USD", status);
                if (U_FAILURE(status)) {
                    std::fprintf(stderr, "setCurrency failed\n");
                    return 1;
                }
            }

            for (double value : values) {
                UnicodeString formatted;
                FieldPosition position(FieldPosition::DONT_CARE);
                format.format(value, formatted, position);
                putU8(records, locale_index);
                putU8(records, pattern_index);
                putU8(records, 0);
                putF64(records, value);
                putString16(records, formatted);
                record_count++;

                Formattable result;
                ParsePosition parse_position(0);
                format.parse(formatted, result, parse_position);
                const bool matched = parse_position.getErrorIndex() < 0;
                double parsed_value =
                    std::numeric_limits<double>::quiet_NaN();
                if (matched) {
                    parsed_value = result.getType() == Formattable::kLong
                        ? static_cast<double>(result.getLong())
                        : result.getDouble();
                }
                putU8(records, locale_index);
                putU8(records, pattern_index);
                putU8(records, 1);
                putString16(records, formatted);
                putU8(records, matched ? 1 : 0);
                putF64(records, parsed_value);
                putU32(
                    records,
                    utf16IndexToUtf8Offset(
                        formatted,
                        parse_position.getIndex()));
                record_count++;
            }

            const UnicodeString invalid =
                UnicodeString::fromUTF8("abc");
            putU8(records, locale_index);
            putU8(records, pattern_index);
            putU8(records, 1);
            putString16(records, invalid);
            putU8(records, 0);
            putF64(records, std::numeric_limits<double>::quiet_NaN());
            putU32(records, 0);
            record_count++;
        }
    }

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'O'};
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
