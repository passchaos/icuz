// Generate the ICU UCharsTrie conformance fixture.
//
// Build with ICU 78 headers and libicuuc, for example:
//   clang++ -std=c++17 -I $ICU/icu4c/source/common \
//       generate_conformance.cpp -L $ICU_LIB -licuuc -licudata \
//       -Wl,-rpath,$ICU_LIB -o generate_conformance
//   ./generate_conformance src/unicode/trie_conformance.bin
//
// The fixture stores ICU-built tries and lookup traces produced by
// UCharsTrie::first/next/nextString/firstForCodePoint/nextForCodePoint.

#include <unicode/appendable.h>
#include <unicode/ucharstriebuilder.h>
#include <unicode/unistr.h>
#include <unicode/ustringtrie.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace icu;

struct Op {
    uint8_t kind;  // 0 first, 1 next, 2 firstForCodePoint, 3 nextForCodePoint,
                   // 4 nextString, 5 state snapshot
    uint16_t unit;
    uint32_t codepoint;
    std::u16string text;
    std::u16string next_units;
    uint64_t state64;
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

static void writeU64(FILE* f, uint64_t value) {
    writeU32(f, static_cast<uint32_t>(value & 0xffffffffu));
    writeU32(f, static_cast<uint32_t>(value >> 32));
}

static Op snapshot(const UCharsTrie& trie) {
    Op op{};
    op.kind = 5;
    int32_t unique_value = 0;
    op.result = trie.hasUniqueValue(unique_value) ? 1 : 0;
    op.value = unique_value;
    UnicodeString buffer;
    UnicodeStringAppendable app(buffer);
    int32_t count = trie.getNextUChars(app);
    op.next_units.assign(buffer.getBuffer(), static_cast<size_t>(count));
    if (trie.current() != USTRINGTRIE_NO_MATCH) {
        op.state64 = trie.getState64();
    }
    return op;
}

static std::vector<Op> trace(const UCharsTrie& trie,
                             const std::vector<std::u16string>& probes) {
    std::vector<Op> ops;
    UCharsTrie root(trie);
    root.reset();
    ops.push_back(snapshot(root));
    for (const auto& probe : probes) {
        UCharsTrie copy(trie);
        copy.reset();
        for (size_t i = 0; i < probe.size(); i++) {
            UStringTrieResult result = i == 0 ? copy.first(probe[i])
                                             : copy.next(probe[i]);
            Op op{};
            op.kind = i == 0 ? 0 : 1;
            op.unit = probe[i];
            op.result = static_cast<uint8_t>(result);
            op.value = USTRINGTRIE_HAS_VALUE(result) ? copy.getValue() : 0;
            ops.push_back(op);
        }
        if (!probe.empty()) {
            ops.push_back(snapshot(copy));
        }

        UCharsTrie copy2(trie);
        copy2.reset();
        UStringTrieResult result =
            copy2.next(ConstChar16Ptr(probe.data()), static_cast<int32_t>(probe.size()));
        Op op{};
        op.kind = 4;
        op.text = probe;
        op.result = static_cast<uint8_t>(result);
        op.value = USTRINGTRIE_HAS_VALUE(result) ? copy2.getValue() : 0;
        ops.push_back(op);
        ops.push_back(snapshot(copy2));

        UCharsTrie copy3(trie);
        copy3.reset();
        for (size_t i = 0; i < probe.size(); i++) {
            UChar32 codepoint = probe[i];
            UStringTrieResult r = i == 0 ? copy3.firstForCodePoint(codepoint)
                                         : copy3.nextForCodePoint(codepoint);
            Op cp_op{};
            cp_op.kind = i == 0 ? 2 : 3;
            cp_op.codepoint = static_cast<uint32_t>(codepoint);
            cp_op.result = static_cast<uint8_t>(r);
            cp_op.value = USTRINGTRIE_HAS_VALUE(r) ? copy3.getValue() : 0;
            ops.push_back(cp_op);
        }
        ops.push_back(snapshot(copy3));
    }
    return ops;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s out_file\n", argv[0]);
        return 2;
    }

    std::vector<std::vector<std::u16string>> word_sets = {
        {u"apple", u"app", u"banana", u"band", u"bandana"},
        {u"a", u"ab", u"abc", u"b", u"ba", u"c", u"ca", u"cab", u"d",
         u"da", u"e", u"f", u"g", u"h", u"i", u"j", u"k", u"l"},
        {u"caf\u00e9", u"cafe\u0301", u"\u65e5\u672c\u8a9e", u"\U0001F600",
         u"\U0001F600x", u"na\u00efve", u"naive"},
        {u"the", u"quick", u"brown", u"fox", u"jumps", u"over", u"lazy",
         u"dog", u"the quick", u"the quick brown", u"quick brown fox"},
    };

    std::vector<std::u16string> probes;
    for (const auto& set : word_sets) {
        for (const auto& word : set) {
            probes.push_back(word);
            for (size_t i = 1; i < word.size(); i++) {
                probes.push_back(word.substr(0, i));
            }
        }
    }
    probes.push_back(u"");
    probes.push_back(u"z");
    probes.push_back(u"zzz");
    probes.push_back(u"\U0001F601");

    FILE* out = std::fopen(argv[1], "wb");
    if (out == nullptr) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    const char magic[4] = {'C', 'J', 'U', '2'};
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
            UCharsTrieBuilder builder(status);
            int32_t value = 1;
            for (const auto& word : set) {
                builder.add(UnicodeString(word.data(), static_cast<int32_t>(word.size())),
                            value++, status);
            }
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "builder add failed: %d\n", status);
                return 1;
            }
            UnicodeString built;
            builder.buildUnicodeString(
                option == 0 ? USTRINGTRIE_BUILD_SMALL : USTRINGTRIE_BUILD_FAST,
                built,
                status);
            if (U_FAILURE(status)) {
                std::fprintf(stderr, "build failed: %d\n", status);
                return 1;
            }
            const char16_t* units = built.getBuffer();
            int32_t unit_count = built.length();
            UCharsTrie trie{ConstChar16Ptr(units)};
            std::vector<Op> ops = trace(trie, probes);

            std::fputc(option, out);
            writeU16(out, static_cast<uint16_t>(unit_count));
            for (int32_t i = 0; i < unit_count; i++) {
                writeU16(out, static_cast<uint16_t>(units[i]));
            }
            writeU16(out, static_cast<uint16_t>(ops.size()));
            for (const auto& op : ops) {
                std::fputc(op.kind, out);
                if (op.kind == 0 || op.kind == 1) {
                    writeU16(out, op.unit);
                } else if (op.kind == 2 || op.kind == 3) {
                    writeU32(out, op.codepoint);
                } else if (op.kind == 4) {
                    writeU16(out, static_cast<uint16_t>(op.text.size()));
                    for (char16_t unit : op.text) {
                        writeU16(out, static_cast<uint16_t>(unit));
                    }
                } else {
                    writeU16(out, static_cast<uint16_t>(op.next_units.size()));
                    for (char16_t unit : op.next_units) {
                        writeU16(out, static_cast<uint16_t>(unit));
                    }
                    writeU64(out, op.state64);
                }
                std::fputc(op.result, out);
                writeU32(out, static_cast<uint32_t>(op.value));
            }
        }
    }
    std::fclose(out);
    return 0;
}
