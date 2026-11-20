// ICU comparison microbenchmarks for the workloads in bench.zig.
//
// Build:
//   clang++ -O2 -std=c++17 -I $ICU_INC bench/icu_bench.cpp \
//       -L $ICU_LIB -licuuc -licui18n -licudata \
//       -Wl,-rpath,$ICU_LIB -o /tmp/icu_bench
//   /tmp/icu_bench

#include <unicode/ubrk.h>
#include <unicode/ucnv.h>
#include <unicode/ucol.h>
#include <unicode/unorm2.h>
#include <unicode/unum.h>
#include <unicode/ustring.h>
#include <unicode/utypes.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <time.h>

static uint64_t now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull +
        static_cast<uint64_t>(ts.tv_nsec);
}

static void report_ops(const char* name, int ops, uint64_t ns) {
    const double per_op = static_cast<double>(ns) / ops;
    std::printf("%-32s %8.3f ns/op %9.1f Mops/s\n", name, per_op, 1000.0 / per_op);
}

static void report_bytes(const char* name, size_t bytes, uint64_t ns) {
    const double per_byte = static_cast<double>(ns) / bytes;
    std::printf("%-32s %8.3f ns/B  %9.1f MB/s\n", name, per_byte,
        static_cast<double>(bytes) * 1000.0 / ns);
}

static std::vector<UChar> to_u16(const std::string& text) {
    UErrorCode status = U_ZERO_ERROR;
    int32_t length = 0;
    u_strFromUTF8(nullptr, 0, &length, text.data(),
        static_cast<int32_t>(text.size()), &status);
    status = U_ZERO_ERROR;
    std::vector<UChar> out(static_cast<size_t>(length) + 1);
    u_strFromUTF8(out.data(), static_cast<int32_t>(out.size()), &length,
        text.data(), static_cast<int32_t>(text.size()), &status);
    out.resize(static_cast<size_t>(length));
    return out;
}

template <typename F>
static void bench_bytes(const char* name, size_t bytes, int rounds, F body) {
    uint64_t best = ~0ull;
    for (int trial = 0; trial < 5; trial++) {
        const uint64_t start = now_ns();
        for (int i = 0; i < rounds; i++) body();
        const uint64_t elapsed = now_ns() - start;
        if (elapsed < best) best = elapsed;
    }
    report_bytes(name, bytes * static_cast<size_t>(rounds), best);
}

template <typename F>
static void bench_ops(const char* name, int rounds, F body) {
    uint64_t best = ~0ull;
    for (int trial = 0; trial < 5; trial++) {
        const uint64_t start = now_ns();
        for (int i = 0; i < rounds; i++) body();
        const uint64_t elapsed = now_ns() - start;
        if (elapsed < best) best = elapsed;
    }
    report_ops(name, rounds, best);
}

int main() {
    const std::string ascii_text =
        "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. "
        "How vexingly quick daft zebras jump! 0123456789 hello_world@example.com https://example.com/path?q=1\n";
    const std::string chinese_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "你好，世界！";
        return s;
    }();
    const std::string swedish_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "Ångström älskar blåbär och öar. ÅÄÖ åäö ";
        return s;
    }();
    const std::string german_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "Böttger Mühsam Überlingen ÄÖÜ äöü Straße ";
        return s;
    }();
    const std::string chinese_collation_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "你好世界中国汉字排序拼音";
        return s;
    }();
    const std::string mixed_text =
        "Hello, 世界! café naïve Straße 😀👩‍💻 e\u0301\u0323 שלום مرحبا क्षि 각 text.\n";
    const std::string thai_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "ภาษาไทย ";
        return s;
    }();
    const std::string cjk_word_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "中华人民共和国 ";
        return s;
    }();

    struct Text {
        const char* name;
        std::string utf8;
        std::vector<UChar> u16;
    };
    std::vector<Text> texts = {
        {"ascii", ascii_text, {}},
        {"mixed", mixed_text, {}},
        {"swedish", swedish_text, {}},
        {"german", german_text, {}},
        {"chinese", chinese_text, {}},
        {"chinese_collation", chinese_collation_text, {}},
        {"thai", thai_text, {}},
        {"cjk_word", cjk_word_text, {}},
    };
    for (auto& text : texts) text.u16 = to_u16(text.utf8);

    std::printf("ICU %s microbenchmarks\n", U_ICU_VERSION);

    std::printf("\n-- collation --\n");
    const struct { const char* label; const char* locale; int text; } coll_cases[] = {
        {"UCA sort key ASCII", "en", 0},
        {"UCA sort key mixed", "en", 1},
        {"UCA sort key Swedish root", "en", 2},
        {"UCA sort key Swedish", "sv", 2},
        {"UCA sort key German phonebook", "de@collation=phonebook", 3},
        {"UCA sort key Chinese pinyin", "zh@collation=pinyin", 5},
    };
    for (const auto& item : coll_cases) {
        UErrorCode status = U_ZERO_ERROR;
        UCollator* coll = ucol_open(item.locale, &status);
        if (U_FAILURE(status)) { std::printf("ucol_open %s failed\n", item.locale); continue; }
        ucol_setStrength(coll, UCOL_PRIMARY);
        const auto& u16 = texts[item.text].u16;
        std::vector<uint8_t> key(u16.size() * 8 + 64);
        bench_bytes(item.label, texts[item.text].utf8.size(), 4000, [&] {
            const int32_t length = ucol_getSortKey(coll, u16.data(),
                static_cast<int32_t>(u16.size()), key.data(),
                static_cast<int32_t>(key.size()));
            (void)length;
        });
        ucol_close(coll);
    }

    std::printf("\n-- normalization and case --\n");
    {
        UErrorCode status = U_ZERO_ERROR;
        const UNormalizer2* nfc = unorm2_getNFCInstance(&status);
        for (int index : {0, 1, 4}) {
            const auto& u16 = texts[index].u16;
            std::vector<UChar> out(u16.size() * 3 + 32);
            std::string label = std::string("NFC ") + texts[index].name;
            bench_bytes(label.c_str(), texts[index].utf8.size(), 4000, [&] {
                status = U_ZERO_ERROR;
                unorm2_normalize(nfc, u16.data(), static_cast<int32_t>(u16.size()),
                    out.data(), static_cast<int32_t>(out.size()), &status);
            });
        }
    }
    {
        const auto& u16 = texts[0].u16;
        std::vector<UChar> out(u16.size() * 2 + 32);
        bench_bytes("lower ASCII", texts[0].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strToLower(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), "en", &status);
            (void)length;
        });
        bench_bytes("case fold ASCII", texts[0].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            u_strFoldCase(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), U_FOLD_CASE_DEFAULT, &status);
        });
    }

    std::printf("\n-- charset conversion --\n");
    const struct { const char* label; const char* converter; int text; } conv_cases[] = {
        {"UTF-8 -> GBK Chinese", "GBK", 4},
        {"UTF-8 -> Shift_JIS Japanese", "Shift_JIS", 4},
        {"UTF-8 -> EUC-KR Korean", "EUC-KR", 4},
    };
    for (const auto& item : conv_cases) {
        UErrorCode status = U_ZERO_ERROR;
        UConverter* conv = ucnv_open(item.converter, &status);
        if (U_FAILURE(status)) continue;
        const auto& u16 = texts[item.text].u16;
        std::vector<char> out(u16.size() * 3 + 32);
        bench_bytes(item.label, texts[item.text].utf8.size(), 4000, [&] {
            status = U_ZERO_ERROR;
            ucnv_reset(conv);
            ucnv_fromUChars(conv, out.data(), static_cast<int32_t>(out.size()),
                u16.data(), static_cast<int32_t>(u16.size()), &status);
        });
        ucnv_close(conv);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UConverter* conv = ucnv_open("GBK", &status);
        const auto& u16 = texts[4].u16;
        std::vector<char> encoded(u16.size() * 2 + 32);
        int32_t encoded_length = ucnv_fromUChars(conv, encoded.data(),
            static_cast<int32_t>(encoded.size()), u16.data(),
            static_cast<int32_t>(u16.size()), &status);
        std::vector<UChar> out(u16.size() + 32);
        bench_bytes("GBK -> UTF-8 Chinese", texts[4].utf8.size(), 4000, [&] {
            status = U_ZERO_ERROR;
            ucnv_reset(conv);
            ucnv_toUChars(conv, out.data(), static_cast<int32_t>(out.size()),
                encoded.data(), encoded_length, &status);
        });
        ucnv_close(conv);
    }

    std::printf("\n-- segmentation --\n");
    const struct { const char* label; UBreakIteratorType type; int text; } break_cases[] = {
        {"grapheme ASCII", UBRK_CHARACTER, 0},
        {"grapheme mixed", UBRK_CHARACTER, 1},
        {"word ASCII", UBRK_WORD, 0},
        {"word mixed", UBRK_WORD, 1},
        {"line break ASCII", UBRK_LINE, 0},
        {"line break mixed", UBRK_LINE, 1},
    };
    for (const auto& item : break_cases) {
        UErrorCode status = U_ZERO_ERROR;
        const auto& u16 = texts[item.text].u16;
        UBreakIterator* iterator = ubrk_open(item.type, "en", u16.data(),
            static_cast<int32_t>(u16.size()), &status);
        if (U_FAILURE(status)) continue;
        bench_bytes(item.label, texts[item.text].utf8.size(), 4000, [&] {
            ubrk_setText(iterator, u16.data(), static_cast<int32_t>(u16.size()), &status);
            while (ubrk_next(iterator) != UBRK_DONE) {}
        });
        ubrk_close(iterator);
    }

    std::printf("\n-- number formatting --\n");
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_DECIMAL, nullptr, 0, "en", nullptr, &status);
        UChar out[128];
        bench_ops("decimal number", 20000, [&] {
            status = U_ZERO_ERROR;
            unum_formatDouble(format, 1234.5, out, 128, nullptr, &status);
        });
        unum_close(format);
    }
    return 0;
}
