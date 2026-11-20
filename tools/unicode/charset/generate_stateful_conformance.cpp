// Generate the ICU stateful charset conformance fixture.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_stateful_conformance.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_stateful_conformance
//   ./generate_stateful_conformance src/unicode/charset/stateful_conformance.bin

#include <unicode/ucnv.h>
#include <unicode/unistr.h>
#include <unicode/utypes.h>
#include <cstdio>
#include <cstring>
#include <string>
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

static void putBytes(std::vector<uint8_t>& out, const std::string& text) {
    putU16(out, static_cast<uint16_t>(text.size()));
    out.insert(out.end(), text.begin(), text.end());
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

    const char* converter_names[] = {"UTF-7", "HZ", "SCSU", "BOCU-1", "ISO-2022-KR", "Big5-HKSCS"};
    const char* utf7_inputs[] = {
        "Hello, World!",
        "Hi Mom -\u263a-!",
        "+",
        "\u20ac",
        "\U0001F600",
        "a\u20acb",
        "~!@#$%^&*()_+`{}|[]\\:\";'<>?,./",
        "caf\u00e9 na\u00efve",
        "\u65e5\u672c\u8a9e",
        "\u041f\u0440\u0438\u0432\u0435\u0442",
        "",
        "\U0001F600\U0001F601\U0001F602",
    };
    const char* scsu_inputs[] = {
        "Hello, World!",
        "\u041f\u0440\u0438\u0432\u0435\u0442 \u043c\u0438\u0440",
        "\u65e5\u672c\u8a9e\u30c6\u30b9\u30c8",
        "\u4e2d\u6587\u6d4b\u8bd5",
        "\U0001F600\U0001F601\U0001F602",
        "\u20ac\u00a3\u00a5",
        "\x00\t\n\r",
        "\u2192\u2190\u2191\u2193",
        "\U0001D573\U0001D58A\U0001D591\U0001D591\U0001D594",
        "a\u0301b",
        "caf\u00e9 na\u00efve",
        "",
        "\u4e2d\u534e\u4eba\u6c11\u5171\u548c\u56fd\u6c49\u5b57\u6d4b\u8bd5\u65e5\u672c\u8a9e",
        "\u041f\u0440\u0438\u0432\u0435\u0442, \u4e16\u754c! \U0001F600",
    };
    const char* bocu1_inputs[] = {
        "Hello, World!",
        "\u041f\u0440\u0438\u0432\u0435\u0442",
        "\u65e5\u672c\u8a9e\u30c6\u30b9\u30c8",
        "\u4e2d\u6587\u6d4b\u8bd5",
        "\U0001F600\U0001F601\U0001F602",
        "\u20ac\u00a3\u00a5",
        "\x00\t\n\r",
        "\u2192\u2190\u2191\u2193",
        "\U0001D573\U0001D58A\U0001D591\U0001D591\U0001D594",
        "a\u0301b",
        "caf\u00e9 na\u00efve",
        "",
        "\u4e2d\u534e\u4eba\u6c11\u5171\u548c\u56fd\u6c49\u5b57\u6d4b\u8bd5\u65e5\u672c\u8a9e",
        "\u041f\u0440\u0438\u0432\u0435\u0442, \u4e16\u754c! \U0001F600",
    };
    const char* iso2022kr_inputs[] = {
        "Hello",
        "\ud55c\uad6d\uc5b4",
        "Hello \ud55c\uad6d",
        "A",
        "",
        "\uc11c\uc6b8\ud2b9\ubcc4\uc2dc",
        "\ub300\ud55c\ubbfc\uad6d",
        "\ud55c\uae00 \ud14c\uc2a4\ud2b8",
        "ABC \ud55c\uae00 123",
        "\uac00\ub098\ub2e4\ub77c\ub9c8\ubc14\uc0ac",
        "\uc548\ub155\ud558\uc138\uc694",
    };
    const char* hkscs_inputs[] = {
        "\u9999\u6e2f",
        "\u20ac",
        "\U00027267",
        "Hello \u9999\u6e2f",
        "\u53f0\u7063",
        "\u9999\u6e2f\u7279\u5225\u884c\u653f\u5340",
        "ABC 123",
        "",
        "\u4e2d\u6587\u6e2c\u8a66",
        "\u4e00\u4e8c\u4e09\u56db\u4e94",
    };
    const char* hz_inputs[] = {
        "Hello",
        "\u4e2d\u56fd",
        "a~b",
        "\u4e2d\u6587~test",
        "\u4e2d\u56fdabc",
        "~",
        "\u4f60\u597d\u4e16\u754c",
        "\u4e2d\u6587\u6d4b\u8bd5",
        "\u6c49\u5b57",
        "\u7b80\u4f53\u4e2d\u6587",
        "abc 123",
        "",
    };

    std::vector<uint8_t> records;
    uint32_t record_count = 0;
    for (uint8_t converter_index = 0; converter_index < 6; converter_index++) {
        UErrorCode status = U_ZERO_ERROR;
        UConverter* converter = ucnv_open(
            converter_names[converter_index],
            &status);
        if (U_FAILURE(status) || converter == nullptr) {
            std::fprintf(stderr, "cannot open converter %s\n", converter_names[converter_index]);
            return 1;
        }
        const char* const* inputs = converter_index == 0
            ? utf7_inputs
            : (converter_index == 1
                ? hz_inputs
                : (converter_index == 2
                    ? scsu_inputs
                    : (converter_index == 3
                        ? bocu1_inputs
                        : (converter_index == 4
                            ? iso2022kr_inputs
                            : hkscs_inputs))));
        const size_t input_count = converter_index == 0
            ? sizeof(utf7_inputs) / sizeof(utf7_inputs[0])
            : (converter_index == 1
                ? sizeof(hz_inputs) / sizeof(hz_inputs[0])
                : (converter_index == 2
                    ? sizeof(scsu_inputs) / sizeof(scsu_inputs[0])
                    : (converter_index == 3
                        ? sizeof(bocu1_inputs) / sizeof(bocu1_inputs[0])
                        : (converter_index == 4
                            ? sizeof(iso2022kr_inputs) / sizeof(iso2022kr_inputs[0])
                            : sizeof(hkscs_inputs) / sizeof(hkscs_inputs[0])))));
        for (size_t input_index = 0; input_index < input_count; input_index++) {
            const UnicodeString text = UnicodeString::fromUTF8(inputs[input_index]);

            status = U_ZERO_ERROR;
            const int32_t encoded_length = ucnv_fromUChars(
                converter,
                nullptr,
                0,
                text.getBuffer(),
                text.length(),
                &status);
            if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) {
                std::fprintf(stderr, "encode preflight failed: %s\n", u_errorName(status));
                return 1;
            }
            status = U_ZERO_ERROR;
            std::vector<char> encoded(static_cast<size_t>(encoded_length) + 1);
            ucnv_reset(converter);
            const int32_t encoded_written = ucnv_fromUChars(
                converter,
                encoded.data(),
                static_cast<int32_t>(encoded.size()),
                text.getBuffer(),
                text.length(),
                &status);
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "encode failed: %s\n", u_errorName(status));
                return 1;
            }
            const std::string encoded_text(encoded.data(), encoded_written);

            putU8(records, converter_index);
            putU8(records, 0);
            putString16(records, text);
            putBytes(records, encoded_text);
            record_count++;

            status = U_ZERO_ERROR;
            const int32_t decoded_length = ucnv_toUChars(
                converter,
                nullptr,
                0,
                encoded_text.data(),
                static_cast<int32_t>(encoded_text.size()),
                &status);
            if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) {
                std::fprintf(stderr, "decode preflight failed: %s\n", u_errorName(status));
                return 1;
            }
            status = U_ZERO_ERROR;
            std::vector<UChar> decoded(static_cast<size_t>(decoded_length) + 1);
            ucnv_reset(converter);
            const int32_t decoded_written = ucnv_toUChars(
                converter,
                decoded.data(),
                static_cast<int32_t>(decoded.size()),
                encoded_text.data(),
                static_cast<int32_t>(encoded_text.size()),
                &status);
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "decode failed: %s\n", u_errorName(status));
                return 1;
            }
            const UnicodeString decoded_text(decoded.data(), decoded_written);

            putU8(records, converter_index);
            putU8(records, 1);
            putBytes(records, encoded_text);
            putString16(records, decoded_text);
            record_count++;
        }
        ucnv_close(converter);
    }

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'P'};
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
