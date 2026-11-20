// Generate the ICU BytesTrie conformance fixture.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_bytes_conformance.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_bytes_conformance
//   ./generate_bytes_conformance src/unicode/bytes_trie_conformance.bin

#include <unicode/bytestrie.h>
#include <unicode/bytestriebuilder.h>
#include <unicode/ustringtrie.h>
#include <cstdio>
#include <string>
#include <vector>

using namespace icu;

struct Op {
    uint8_t kind;  // 0 first, 1 next, 2 nextString
    uint8_t byte;
    std::string text;
    uint8_t result;
    int32_t value;
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

static std::vector<Op> trace(const BytesTrie& trie,
                             const std::vector<std::string>& probes) {
    std::vector<Op> ops;
    for (const auto& probe : probes) {
        BytesTrie copy(trie);
        copy.reset();
        for (size_t i = 0; i < probe.size(); i++) {
            UStringTrieResult result =
                i == 0 ? copy.first(static_cast<uint8_t>(probe[i]))
                       : copy.next(static_cast<uint8_t>(probe[i]));
            Op op{};
            op.kind = i == 0 ? 0 : 1;
            op.byte = static_cast<uint8_t>(probe[i]);
            op.result = static_cast<uint8_t>(result);
            op.value = USTRINGTRIE_HAS_VALUE(result) ? copy.getValue() : 0;
            ops.push_back(op);
        }

        BytesTrie copy2(trie);
        copy2.reset();
        UStringTrieResult result = copy2.next(
            probe.data(),
            static_cast<int32_t>(probe.size()));
        Op op{};
        op.kind = 2;
        op.text = probe;
        op.result = static_cast<uint8_t>(result);
        op.value = USTRINGTRIE_HAS_VALUE(result) ? copy2.getValue() : 0;
        ops.push_back(op);
    }
    return ops;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }

    std::vector<std::vector<std::string>> word_sets = {
        {"apple", "app", "banana", "band", "bandana"},
        {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
         "n", "o", "p", "q", "r", "s"},
        {},
        {"caf\xc3\xa9", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e",
         "\xf0\x9f\x98\x80", "\xf0\x9f\x98\x80x"},
        {"a", "ab", "abc", "b", "ba"},
    };
    for (int i = 0; i < 80; i++) {
        word_sets[2].push_back(std::string(1, static_cast<char>(0x80 + i)));
    }

    std::vector<std::string> probes;
    for (const auto& set : word_sets) {
        for (const auto& word : set) {
            probes.push_back(word);
            for (size_t i = 1; i < word.size(); i++) {
                probes.push_back(word.substr(0, i));
            }
        }
    }
    probes.push_back("");
    probes.push_back("z");
    probes.push_back("zzz");

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'Y', '2'};
    std::fwrite(magic, 1, 4, out);
    std::fputc(1, out);
    std::fputc(0, out);
    std::fputc(0, out);
    std::fputc(0, out);

    uint32_t case_count = static_cast<uint32_t>(word_sets.size() * 2);
    writeU32(out, case_count);

    for (const auto& set : word_sets) {
        for (int option = 0; option < 2; option++) {
            UErrorCode status = U_ZERO_ERROR;
            BytesTrieBuilder builder(status);
            int32_t value = 1;
            for (const auto& word : set) {
                builder.add(StringPiece(word), value++, status);
            }
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "builder add failed: %d\n", status);
                return 1;
            }
            StringPiece built = builder.buildStringPiece(
                option == 0 ? USTRINGTRIE_BUILD_SMALL : USTRINGTRIE_BUILD_FAST,
                status);
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "build failed: %d\n", status);
                return 1;
            }
            BytesTrie trie(built.data());
            std::vector<Op> ops = trace(trie, probes);

            std::fputc(option, out);
            writeU16(out, static_cast<uint16_t>(built.length()));
            std::fwrite(built.data(), 1, built.length(), out);
            writeU16(out, static_cast<uint16_t>(ops.size()));
            for (const auto& op : ops) {
                std::fputc(op.kind, out);
                if (op.kind == 0 || op.kind == 1) {
                    std::fputc(op.byte, out);
                } else {
                    writeU16(out, static_cast<uint16_t>(op.text.size()));
                    std::fwrite(op.text.data(), 1, op.text.size(), out);
                }
                std::fputc(op.result, out);
                writeU32(out, static_cast<uint32_t>(op.value));
            }
        }
    }
    std::fclose(out);
    return 0;
}
