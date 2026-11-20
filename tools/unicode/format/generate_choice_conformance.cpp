// Generate the ICU ChoiceFormat conformance fixture.
//
// Build with ICU 78 headers and libicui18n, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       -I $ICU/icu4c/source/i18n generate_choice_conformance.cpp \
//       -L $ICU_LIB -licuuc -licui18n -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_choice_conformance
//   ./generate_choice_conformance src/unicode/format/choice_conformance.bin

#include <unicode/choicfmt.h>
#include <unicode/unistr.h>
#include <unicode/utypes.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

using namespace icu;

struct FormatCase {
    double value;
    std::string text;
};

struct ParseCase {
    std::string text;
    bool matched;
    double value;
    uint32_t index;
};

static void writeU16(FILE* f, uint16_t value) {
    uint8_t bytes[2] = {
        static_cast<uint8_t>(value & 0xff),
        static_cast<uint8_t>(value >> 8),
    };
    std::fwrite(bytes, 1, 2, f);
}

static void writeU32(FILE* f, uint32_t value) {
    uint8_t bytes[4] = {
        static_cast<uint8_t>(value & 0xff),
        static_cast<uint8_t>((value >> 8) & 0xff),
        static_cast<uint8_t>((value >> 16) & 0xff),
        static_cast<uint8_t>((value >> 24) & 0xff),
    };
    std::fwrite(bytes, 1, 4, f);
}

static void writeU64(FILE* f, uint64_t value) {
    writeU32(f, static_cast<uint32_t>(value & 0xffffffffu));
    writeU32(f, static_cast<uint32_t>(value >> 32));
}

static void writeF64(FILE* f, double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    writeU64(f, bits);
}

static std::string toUtf8(const UnicodeString& text) {
    std::string result;
    text.toUTF8String(result);
    return result;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }

    const std::vector<std::string> patterns = {
        "0#no files|1#one file|1<many files",
        "0\u2264zero|1<one|2\u2264two|3<three",
        "-\u221e#negative|0#zero|\u221e#infinity",
        "0.5#half|1#one|2.5#two and a half|3<many",
        "0#a{1}|1#b",
        "0#a#b|1#c",
        "0#'abc'|1#c",
        "0#a''b|1#c",
        "0#x|1#y",
        "0#a|1#b|2#c",
        "0#a|b|1#c",
        "a#b",
    };

    const std::vector<double> values = {
        -std::numeric_limits<double>::infinity(),
        -1e300,
        -2,
        -1,
        -0.5,
        0,
        0.5,
        1,
        1.5,
        2,
        2.5,
        3,
        1e300,
        std::numeric_limits<double>::infinity(),
        std::numeric_limits<double>::quiet_NaN(),
    };

    const std::vector<std::string> parse_texts = {
        "no files", "one file", "many files", "many files!", "xyz", "",
        "zero", "one", "two", "three", "half", "two and a half",
        "a#b", "x", "y", "z", "negative", "infinity", "a{1}", "b", "c",
    };

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'H'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);
    writeU32(out, static_cast<uint32_t>(patterns.size()));

    for (const auto& pattern : patterns) {
        UErrorCode status = U_ZERO_ERROR;
        UnicodeString pattern_text = UnicodeString::fromUTF8(pattern);
        ChoiceFormat format(pattern_text, status);
        const bool valid = U_SUCCESS(status);

        std::vector<FormatCase> format_cases;
        std::vector<ParseCase> parse_cases;
        if (valid) {
            for (double value : values) {
                UnicodeString result;
                FieldPosition position(FieldPosition::DONT_CARE);
                format.format(value, result, position);
                format_cases.push_back({value, toUtf8(result)});
            }
            // ICU's MessagePattern-based ChoiceFormat parse does not handle
            // quoted message literals; leave those patterns to unit tests.
            if (pattern.find('\'') == std::string::npos) {
                for (const auto& text : parse_texts) {
                    UnicodeString source = UnicodeString::fromUTF8(text);
                    Formattable result;
                    ParsePosition position(0);
                    format.parse(source, result, position);
                    const bool matched = position.getErrorIndex() < 0;
                    parse_cases.push_back({
                        text,
                        matched,
                        matched ? result.getDouble()
                                : std::numeric_limits<double>::quiet_NaN(),
                        static_cast<uint32_t>(position.getIndex()),
                    });
                }
            }
        }

        std::fputc(valid ? 1 : 0, out);
        writeU16(out, static_cast<uint16_t>(pattern.size()));
        std::fwrite(pattern.data(), 1, pattern.size(), out);
        if (!valid) {
            continue;
        }

        writeU16(out, static_cast<uint16_t>(format_cases.size()));
        for (const auto& item : format_cases) {
            writeF64(out, item.value);
            writeU16(out, static_cast<uint16_t>(item.text.size()));
            std::fwrite(item.text.data(), 1, item.text.size(), out);
        }
        writeU16(out, static_cast<uint16_t>(parse_cases.size()));
        for (const auto& item : parse_cases) {
            writeU16(out, static_cast<uint16_t>(item.text.size()));
            std::fwrite(item.text.data(), 1, item.text.size(), out);
            std::fputc(item.matched ? 1 : 0, out);
            writeF64(out, item.value);
            writeU32(out, item.index);
        }
    }
    std::fclose(out);
    return 0;
}
