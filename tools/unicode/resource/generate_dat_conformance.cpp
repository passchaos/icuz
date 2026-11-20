// Generate the ICU .dat package conformance fixture.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_dat_conformance.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_dat_conformance
//   ./generate_dat_conformance src/unicode/resource/fixtures/icudt_test \
//       src/unicode/resource/dat_conformance.bin

#include <unicode/ures.h>
#include <unicode/unistr.h>
#include <unicode/utypes.h>
#include <cstdio>
#include <cstdlib>
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

static void putI32(std::vector<uint8_t>& out, int32_t value) {
    putU32(out, static_cast<uint32_t>(value));
}

static void putBytes(std::vector<uint8_t>& out, const std::string& text) {
    putU16(out, static_cast<uint16_t>(text.size()));
    out.insert(out.end(), text.begin(), text.end());
}

static void putString16(
    std::vector<uint8_t>& out,
    const UChar* text,
    int32_t length
) {
    putU16(out, static_cast<uint16_t>(length));
    for (int32_t i = 0; i < length; i++) {
        putU16(out, static_cast<uint16_t>(text[i]));
    }
}

static bool isDigits(const std::string& text) {
    if (text.empty()) return false;
    for (char c : text) {
        if (c < '0' || c > '9') return false;
    }
    return true;
}

static UResourceBundle* openPath(
    UResourceBundle* root,
    const char* path,
    std::vector<UResourceBundle*>& opened
) {
    UResourceBundle* current = root;
    const std::string text(path);
    size_t start = 0;
    while (start < text.size()) {
        size_t slash = text.find('/', start);
        const std::string segment = text.substr(
            start,
            slash == std::string::npos ? std::string::npos : slash - start);
        UErrorCode status = U_ZERO_ERROR;
        UResourceBundle* next = isDigits(segment)
            ? ures_getByIndex(current, std::atoi(segment.c_str()), nullptr, &status)
            : ures_getByKey(current, segment.c_str(), nullptr, &status);
        if (U_FAILURE(status)) return nullptr;
        opened.push_back(next);
        current = next;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return current;
}

static void closeOpened(std::vector<UResourceBundle*>& opened) {
    for (auto it = opened.rbegin(); it != opened.rend(); ++it) {
        ures_close(*it);
    }
    opened.clear();
}

static void emitString(
    std::vector<uint8_t>& out,
    uint8_t bundle_index,
    UResourceBundle* root,
    const char* path
) {
    std::vector<UResourceBundle*> opened;
    UResourceBundle* leaf = openPath(root, path, opened);
    if (leaf == nullptr) {
        closeOpened(opened);
        return;
    }
    UErrorCode status = U_ZERO_ERROR;
    int32_t length = 0;
    const UChar* text = ures_getString(leaf, &length, &status);
    if (U_SUCCESS(status)) {
        putU8(out, bundle_index);
        putU8(out, 0);
        putBytes(out, path);
        putString16(out, text, length);
    }
    closeOpened(opened);
}

static void emitInt(
    std::vector<uint8_t>& out,
    uint8_t bundle_index,
    UResourceBundle* root,
    const char* path
) {
    std::vector<UResourceBundle*> opened;
    UResourceBundle* leaf = openPath(root, path, opened);
    if (leaf == nullptr) {
        closeOpened(opened);
        return;
    }
    UErrorCode status = U_ZERO_ERROR;
    const int32_t value = ures_getInt(leaf, &status);
    if (U_SUCCESS(status)) {
        putU8(out, bundle_index);
        putU8(out, 1);
        putBytes(out, path);
        putI32(out, value);
    }
    closeOpened(opened);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: %s package_path out_file\n", argv[0]);
        return 2;
    }
    const char* package_path = argv[1];

    const struct {
        uint8_t index;
        const char* locale;
        bool root_values;
        bool en_values;
        bool en_us_values;
    } specs[] = {
        {0, "", true, false, false},
        {1, "en", false, true, false},
        {2, "en_US", false, false, true},
        {3, "pooled_root", true, false, false},
        {4, "pooled_en", false, true, false},
    };

    std::vector<uint8_t> records;
    for (const auto& spec : specs) {
        UErrorCode status = U_ZERO_ERROR;
        UResourceBundle* bundle = ures_openDirect(
            package_path,
            spec.locale,
            &status);
        if (U_FAILURE(status) || bundle == nullptr) {
            std::fprintf(
                stderr,
                "cannot open package bundle %s: %s\n",
                spec.locale,
                u_errorName(status));
            return 1;
        }
        if (spec.root_values) {
            emitString(records, spec.index, bundle, "greeting");
            emitString(records, spec.index, bundle, "shared");
            emitString(records, spec.index, bundle, "aliasClient");
            emitString(records, spec.index, bundle, "nested/deeper/inner");
            emitString(records, spec.index, bundle, "unicode");
            emitInt(records, spec.index, bundle, "count");
        }
        if (spec.en_values) {
            emitString(records, spec.index, bundle, "greeting");
            emitString(records, spec.index, bundle, "extra");
            emitString(records, spec.index, bundle, "shared");
        }
        if (spec.en_us_values) {
            emitString(records, spec.index, bundle, "greeting");
            emitString(records, spec.index, bundle, "shared");
        }
        ures_close(bundle);
    }

    FILE* out = std::fopen(argv[2], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[2]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'G', 'N'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);
    // Count records by replaying the self-describing byte stream.
    size_t offset = 0;
    uint32_t record_count = 0;
    while (offset < records.size()) {
        const uint8_t kind = records[offset + 1];
        const uint16_t path_length =
            static_cast<uint16_t>(records[offset + 2]) |
            static_cast<uint16_t>(records[offset + 3] << 8);
        offset += 4 + path_length;
        if (kind == 0) {
            const uint16_t length =
                static_cast<uint16_t>(records[offset]) |
                static_cast<uint16_t>(records[offset + 1] << 8);
            offset += 2 + static_cast<size_t>(length) * 2;
        } else {
            offset += 4;
        }
        record_count++;
    }
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
