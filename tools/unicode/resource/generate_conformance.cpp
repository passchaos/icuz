// Generate the ICU resource bundle conformance fixture.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_conformance.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_conformance
//   ./generate_conformance src/unicode/resource/fixtures \
//       src/unicode/resource/res_conformance.bin
//
// The fixture records values read through ures_openDirect() so that ICU does
// not apply locale fallback; each record maps one bundle/path pair to the
// exact value exposed by the ICU resource API.

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

static void putString16(std::vector<uint8_t>& out, const UChar* text, int32_t length) {
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
        if (U_FAILURE(status)) {
            return nullptr;
        }
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

static void emitUInt(
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
    const uint32_t value = ures_getUInt(leaf, &status);
    if (U_SUCCESS(status)) {
        putU8(out, bundle_index);
        putU8(out, 2);
        putBytes(out, path);
        putU32(out, value);
    }
    closeOpened(opened);
}

static void emitBinary(
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
    const uint8_t* data = ures_getBinary(leaf, &length, &status);
    if (U_SUCCESS(status)) {
        putU8(out, bundle_index);
        putU8(out, 3);
        putBytes(out, path);
        putU32(out, static_cast<uint32_t>(length));
        out.insert(out.end(), data, data + length);
    }
    closeOpened(opened);
}

static void emitIntVector(
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
    const int32_t* values = ures_getIntVector(leaf, &length, &status);
    if (U_SUCCESS(status)) {
        putU8(out, bundle_index);
        putU8(out, 4);
        putBytes(out, path);
        putU16(out, static_cast<uint16_t>(length));
        for (int32_t i = 0; i < length; i++) {
            putI32(out, values[i]);
        }
    }
    closeOpened(opened);
}

static void emitStringArray(
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
    const int32_t size = ures_getSize(leaf);
    putU8(out, bundle_index);
    putU8(out, 5);
    putBytes(out, path);
    putU16(out, static_cast<uint16_t>(size));
    for (int32_t i = 0; i < size; i++) {
        UErrorCode status = U_ZERO_ERROR;
        int32_t length = 0;
        const UChar* text = ures_getStringByIndex(leaf, i, &length, &status);
        if (U_FAILURE(status)) {
            putU16(out, 0);
        } else {
            putString16(out, text, length);
        }
    }
    closeOpened(opened);
}

static void emitTableKeys(
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
    const int32_t size = ures_getSize(leaf);
    putU8(out, bundle_index);
    putU8(out, 6);
    putBytes(out, path);
    putU16(out, static_cast<uint16_t>(size));
    for (int32_t i = 0; i < size; i++) {
        UErrorCode status = U_ZERO_ERROR;
        UResourceBundle* child = ures_getByIndex(leaf, i, nullptr, &status);
        if (U_FAILURE(status)) {
            putU16(out, 0);
            continue;
        }
        const char* key = ures_getKey(child);
        putBytes(out, key == nullptr ? "" : key);
        ures_close(child);
    }
    closeOpened(opened);
}

struct BundleSpec {
    uint8_t index;
    const char* locale;
    bool root_values;
    bool en_values;
    bool en_us_values;
};

static uint16_t getU16(const std::vector<uint8_t>& data, size_t offset) {
    return static_cast<uint16_t>(data[offset]) |
        static_cast<uint16_t>(data[offset + 1] << 8);
}

static uint32_t getU32(const std::vector<uint8_t>& data, size_t offset) {
    return static_cast<uint32_t>(getU16(data, offset)) |
        (static_cast<uint32_t>(getU16(data, offset + 2)) << 16);
}

static uint32_t countRecords(const std::vector<uint8_t>& data) {
    size_t offset = 0;
    uint32_t count = 0;
    while (offset < data.size()) {
        offset += 2;  // bundle index and kind
        const uint8_t kind = data[offset - 1];
        const uint16_t path_length = getU16(data, offset);
        offset += 2 + path_length;
        switch (kind) {
            case 0: {
                const uint16_t length = getU16(data, offset);
                offset += 2 + static_cast<size_t>(length) * 2;
                break;
            }
            case 1:
            case 2:
                offset += 4;
                break;
            case 3: {
                const uint32_t length = getU32(data, offset);
                offset += 4 + length;
                break;
            }
            case 4: {
                const uint16_t length = getU16(data, offset);
                offset += 2 + static_cast<size_t>(length) * 4;
                break;
            }
            case 5: {
                const uint16_t length = getU16(data, offset);
                offset += 2;
                for (uint16_t i = 0; i < length; i++) {
                    const uint16_t item_length = getU16(data, offset);
                    offset += 2 + static_cast<size_t>(item_length) * 2;
                }
                break;
            }
            case 6: {
                const uint16_t length = getU16(data, offset);
                offset += 2;
                for (uint16_t i = 0; i < length; i++) {
                    const uint16_t key_length = getU16(data, offset);
                    offset += 2 + key_length;
                }
                break;
            }
            default:
                return count;
        }
        count++;
    }
    return count;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: %s fixture_dir out_file\n", argv[0]);
        return 2;
    }
    const char* directory = argv[1];

    const BundleSpec specs[] = {
        {0, "", true, false, false},
        {1, "en", false, true, false},
        {2, "en_US", false, false, true},
        {3, "pooled_root", true, false, false},
        {4, "pooled_en", false, true, false},
        {5, "pooled_en_US", false, false, true},
    };

    std::vector<uint8_t> records;
    for (const BundleSpec& spec : specs) {
        UErrorCode status = U_ZERO_ERROR;
        UResourceBundle* bundle = ures_openDirect(directory, spec.locale, &status);
        if (U_FAILURE(status) || bundle == nullptr) {
            std::fprintf(
                stderr,
                "cannot open bundle %s: %s\n",
                spec.locale,
                u_errorName(status));
            return 1;
        }

        emitTableKeys(records, spec.index, bundle, "nested");

        if (spec.root_values) {
            emitString(records, spec.index, bundle, "greeting");
            emitInt(records, spec.index, bundle, "count");
            emitInt(records, spec.index, bundle, "negative");
            emitUInt(records, spec.index, bundle, "big");
            emitString(records, spec.index, bundle, "nested/sub");
            emitString(records, spec.index, bundle, "nested/deeper/inner");
            emitStringArray(records, spec.index, bundle, "strings");
            emitIntVector(records, spec.index, bundle, "ints");
            emitBinary(records, spec.index, bundle, "data");
            emitString(records, spec.index, bundle, "aliasClient");
            emitString(records, spec.index, bundle, "unicode");
            emitString(records, spec.index, bundle, "shared");
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
    const char magic[4] = {'C', 'J', 'G', 'M'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);
    const uint32_t count = countRecords(records);
    uint8_t count_bytes[4] = {
        static_cast<uint8_t>(count & 0xff),
        static_cast<uint8_t>((count >> 8) & 0xff),
        static_cast<uint8_t>((count >> 16) & 0xff),
        static_cast<uint8_t>((count >> 24) & 0xff),
    };
    std::fwrite(count_bytes, 1, 4, out);
    std::fwrite(records.data(), 1, records.size(), out);
    std::fclose(out);
    return 0;
}
