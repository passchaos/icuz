// ICU comparison microbenchmarks for the workloads in bench.zig.
//
// Build:
//   clang++ -O2 -std=c++17 -I $ICU_INC bench/icu_bench.cpp \
//       -L $ICU_LIB -licuuc -licui18n -licudata \
//       -Wl,-rpath,$ICU_LIB -o /tmp/icu_bench
//   /tmp/icu_bench

#include <unicode/ubidi.h>
#include <unicode/ubrk.h>
#include <unicode/ucal.h>
#include <unicode/ucnv.h>
#include <unicode/ucol.h>
#include <unicode/ubidi.h>
#include <unicode/uidna.h>
#include <unicode/uspoof.h>
#include <unicode/ushape.h>
#include <unicode/udat.h>
#include <unicode/ulistformatter.h>
#include <unicode/unorm2.h>
#include <unicode/unum.h>
#include <unicode/uregex.h>
#include <unicode/ureldatefmt.h>
#include <unicode/ustring.h>
#include <unicode/ustring.h>
#include <unicode/utrans.h>
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
    const std::string e_marks_text = [] {
        std::string s;
        for (int i = 0; i < 16; i++) s += "e\u0301\u0323 ";
        return s;
    }();
    const std::string jamo_text = [] {
        std::string s;
        for (int i = 0; i < 12; i++) s += "\u1100\u1161\u11a8 ";
        return s;
    }();
    const std::string japanese_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "\u3053\u3093\u306b\u3061\u306f\u4e16\u754c\u3002\u65e5\u672c\u8a9e\u306e\u6587\u5b57\u30b3\u30fc\u30c9\u5909\u63db\u3002";
        return s;
    }();
    const std::string korean_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "\uc548\ub155\ud558\uc138\uc694 \uc138\uacc4. \ud55c\uad6d\uc5b4 \uc778\ucf54\ub529 \ubcc0\ud658.";
        return s;
    }();
    const std::string chinese_long_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "\u4f60\u597d\uff0c\u4e16\u754c\uff01\u4e2d\u6587\u7f16\u7801\u8f6c\u6362\u57fa\u51c6\u6d4b\u8bd5\u3002";
        return s;
    }();
    const std::string chinese_collation_long_text = [] {
        std::string s;
        for (int i = 0; i < 32; i++) s += "\u4f60\u597d\u4e16\u754c\u4e2d\u56fd\u6c49\u5b57\u6392\u5e8f\u62fc\u97f3";
        return s;
    }();
    const std::string greek_case_text = [] {
        std::string s;
        for (int i = 0; i < 8; i++) s += "\u039f\u0394\u039f\u03a3 \u03a3\u039f\u03a6\u039f\u03a3 \u0391\u0398\u0397\u039d\u0391 ";
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
        {"e_marks", e_marks_text, {}},
        {"jamo", jamo_text, {}},
        {"japanese", japanese_text, {}},
        {"korean", korean_text, {}},
        {"chinese_long", chinese_long_text, {}},
        {"greek_case", greek_case_text, {}},
        {"chinese_collation_long", chinese_collation_long_text, {}},
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
        {"UCA sort key Chinese stroke", "zh@collation=stroke", 5},
        {"UCA sort key Chinese zhuyin", "zh@collation=zhuyin", 5},
        {"UCA sort key Chinese long", "en", 14},
        {"UCA sort key Chinese long pinyin", "zh@collation=pinyin", 14},
    };
    for (const auto& item : coll_cases) {
        UErrorCode status = U_ZERO_ERROR;
        UCollator* coll = ucol_open(item.locale, &status);
        if (U_FAILURE(status)) { std::printf("ucol_open %s failed\n", item.locale); continue; }
        // Match icuz's default sort-key strength so both sides emit the same
        // number of levels.
        ucol_setStrength(coll, UCOL_TERTIARY);
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

    {
        UErrorCode status = U_ZERO_ERROR;
        UCollator* coll = ucol_open("en", &status);
        if (!U_FAILURE(status)) {
            ucol_setStrength(coll, UCOL_TERTIARY);
            const auto& u16 = texts[1].u16;
            std::vector<UChar> other = u16;
            // Mutate near the end so the comparison cannot stop early.
            other[other.size() - 3] = static_cast<UChar>('u');
            {
                std::vector<UChar> long_other = texts[14].u16;
                long_other[long_other.size() - 3] = static_cast<UChar>('u');
                bench_ops("UCA compare Chinese long", 2000, [&] {
                    const int32_t result = ucol_strcoll(coll,
                        texts[14].u16.data(),
                        static_cast<int32_t>(texts[14].u16.size()),
                        long_other.data(),
                        static_cast<int32_t>(long_other.size()));
                    (void)result;
                });
            }
            {
                std::vector<UChar> early = u16;
                early[0] = static_cast<UChar>('Z');
                bench_ops("UCA compare mixed early", 20000, [&] {
                    const int32_t result = ucol_strcoll(coll, u16.data(),
                        static_cast<int32_t>(u16.size()), early.data(),
                        static_cast<int32_t>(early.size()));
                    (void)result;
                });
            }
            {
                std::vector<UChar> swedish_other = texts[2].u16;
                bench_ops("UCA compare Swedish", 20000, [&] {
                    const int32_t result = ucol_strcoll(coll,
                        texts[2].u16.data(),
                        static_cast<int32_t>(texts[2].u16.size()),
                        swedish_other.data(),
                        static_cast<int32_t>(swedish_other.size()));
                    (void)result;
                });
            }
            bench_ops("UCA compare mixed", 20000, [&] {
                const int32_t result = ucol_strcoll(coll, u16.data(),
                    static_cast<int32_t>(u16.size()), other.data(),
                    static_cast<int32_t>(other.size()));
                (void)result;
            });
            ucol_close(coll);
        }
    }

    std::printf("\n-- normalization and case --\n");
    {
        UErrorCode status = U_ZERO_ERROR;
        const UNormalizer2* nfc = unorm2_getNFCInstance(&status);
        for (int index : {0, 1, 12, 8, 9, 10}) {
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
    {
        const auto& u16 = texts[1].u16;
        std::vector<UChar> out(u16.size() * 2 + 32);
        bench_bytes("lower mixed", texts[1].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strToLower(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), "en", &status);
            (void)length;
        });
        bench_bytes("case fold mixed", texts[1].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            u_strFoldCase(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), U_FOLD_CASE_DEFAULT, &status);
        });
    }
    {
        const auto& u16 = texts[3].u16;
        std::vector<UChar> out(u16.size() * 2 + 32);
        bench_bytes("lower German", texts[3].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strToLower(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), "de", &status);
            (void)length;
        });
        bench_bytes("upper German", texts[3].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strToUpper(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), "de", &status);
            (void)length;
        });
    }
    {
        const auto& u16 = texts[13].u16;
        std::vector<UChar> out(u16.size() * 2 + 32);
        bench_bytes("lower Greek sigma", texts[13].utf8.size(), 8000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strToLower(out.data(), static_cast<int32_t>(out.size()), u16.data(),
                static_cast<int32_t>(u16.size()), "el", &status);
            (void)length;
        });
    }

    std::printf("\n-- bidi --\n");
    {
        UBiDi* bidi = ubidi_open();
        for (int index : {0, 1}) {
            const auto& u16 = texts[index].u16;
            std::string label = std::string("bidi ") + texts[index].name;
            bench_ops(label.c_str(), 50000, [&] {
                UErrorCode status = U_ZERO_ERROR;
                ubidi_setPara(bidi, u16.data(),
                    static_cast<int32_t>(u16.size()), UBIDI_DEFAULT_LTR,
                    nullptr, &status);
                ubidi_getLevels(bidi, &status);
            });
        }
        ubidi_close(bidi);
    }

    std::printf("\n-- charset conversion --\n");
    const struct { const char* label; const char* converter; int text; } conv_cases[] = {
        {"UTF-8 -> GBK Chinese", "GBK", 12},
        {"UTF-8 -> Shift_JIS Japanese", "Shift_JIS", 10},
        {"UTF-8 -> EUC-KR Korean", "EUC-KR", 11},
    };
    for (const auto& item : conv_cases) {
        UErrorCode status = U_ZERO_ERROR;
        const auto& utf8 = texts[item.text].utf8;
        std::vector<char> out(utf8.size() * 3 + 32);
        bench_bytes(item.label, utf8.size(), 4000, [&] {
            status = U_ZERO_ERROR;
            ucnv_convert(item.converter, "UTF-8", out.data(),
                static_cast<int32_t>(out.size()), utf8.data(),
                static_cast<int32_t>(utf8.size()), &status);
        });
    }
    {
        const auto& utf8 = texts[0].utf8;
        std::vector<UChar> out(utf8.size() + 32);
        bench_bytes("UTF-8 -> UTF-16LE ASCII", utf8.size(), 4000, [&] {
            UErrorCode status = U_ZERO_ERROR;
            int32_t length = 0;
            u_strFromUTF8(out.data(), static_cast<int32_t>(out.size()),
                &length, utf8.data(), static_cast<int32_t>(utf8.size()),
                &status);
            (void)length;
        });
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UConverter* conv = ucnv_open("GBK", &status);
        const auto& u16 = texts[12].u16;
        std::vector<char> encoded(u16.size() * 2 + 32);
        int32_t encoded_length = ucnv_fromUChars(conv, encoded.data(),
            static_cast<int32_t>(encoded.size()), u16.data(),
            static_cast<int32_t>(u16.size()), &status);
        std::vector<UChar> out(u16.size() + 32);
        bench_bytes("GBK -> UTF-16 Chinese", texts[12].utf8.size(), 4000, [&] {
            status = U_ZERO_ERROR;
            ucnv_reset(conv);
            ucnv_toUChars(conv, out.data(), static_cast<int32_t>(out.size()),
                encoded.data(), encoded_length, &status);
        });
        ucnv_close(conv);

        // icuz's bench converts back to UTF-8, so compare the same target.
        std::vector<char> utf8_out(u16.size() * 3 + 32);
        bench_bytes("GBK -> UTF-8 Chinese", texts[12].utf8.size(), 4000, [&] {
            status = U_ZERO_ERROR;
            ucnv_convert("UTF-8", "GBK", utf8_out.data(),
                static_cast<int32_t>(utf8_out.size()), encoded.data(),
                encoded_length, &status);
        });
    }

    std::printf("\n-- transliteration --\n");
    {
        auto repeat8 = [](const std::string& unit) {
            std::string s;
            for (int i = 0; i < 8; i++) s += unit;
            return s;
        };
        struct TransCase {
            const char* label;
            const char* id;
            std::string text;
        };
        std::vector<TransCase> trans_cases = {
            {"Latin-ASCII Swedish", "Latin-ASCII",
                repeat8("Ångström älskar blåbär och öar. ÅÄÖ åäö ")},
            {"Fullwidth-Halfwidth", "Fullwidth-Halfwidth",
                repeat8("ＡＢＣ１２３！？　ｶﾞｷﾞｸﾞ ")},
            {"Russian-Latin-BGN", "Russian-Latin/BGN",
                repeat8("Москва Санкт-Петербург Россия ")},
            {"Greek-Latin-BGN", "Greek-Latin/BGN",
                repeat8("Ελλάδα Αθήνα ελληνική γλώσσα ")},
            {"Katakana-Latin-BGN", "Katakana-Latin/BGN",
                repeat8("ラーメン とうきょう カタカナ ﾃｽﾄ ")},
            {"Amharic-Latin-BGN", "Amharic-Latin/BGN",
                repeat8("አማርኛ ግዕዝ ፊደል ቋንቋ ")},
            {"Ukrainian-Latin-BGN", "Ukrainian-Latin/BGN",
                repeat8("Київ Україна українська мова ")},
        };
        for (auto& item : trans_cases) {
            const auto u16 = to_u16(item.text);
            std::u16string id16;
            for (const char* p = item.id; *p; ++p) {
                id16.push_back(static_cast<char16_t>(*p));
            }
            UErrorCode status = U_ZERO_ERROR;
            UTransliterator* tr = utrans_openU(
                reinterpret_cast<const UChar*>(id16.c_str()),
                static_cast<int32_t>(id16.size()), UTRANS_FORWARD, nullptr, 0,
                nullptr, &status);
            if (U_FAILURE(status)) {
                std::printf("%s skipped\n", item.id);
                continue;
            }
            std::vector<UChar> buffer(u16.size() * 4 + 64);
            const int32_t capacity = static_cast<int32_t>(buffer.size());
            bench_bytes(item.label, item.text.size(), 4000, [&] {
                std::memcpy(buffer.data(), u16.data(),
                    u16.size() * sizeof(UChar));
                int32_t length = static_cast<int32_t>(u16.size());
                int32_t limit = length;
                status = U_ZERO_ERROR;
                utrans_transUChars(tr, buffer.data(), &length, capacity, 0,
                    &limit, &status);
            });
            utrans_close(tr);
        }
    }

    std::printf("\n-- segmentation --\n");
    const struct {
        const char* label;
        UBreakIteratorType type;
        int text;
        const char* locale;
    } break_cases[] = {
        {"grapheme ASCII", UBRK_CHARACTER, 0, "en"},
        {"grapheme mixed", UBRK_CHARACTER, 1, "en"},
        {"word ASCII", UBRK_WORD, 0, "en"},
        {"word mixed", UBRK_WORD, 1, "en"},
        {"word Thai dictionary", UBRK_WORD, 6, "th"},
        {"word CJK dictionary", UBRK_WORD, 7, "zh"},
        {"line break ASCII", UBRK_LINE, 0, "en"},
        {"line break mixed", UBRK_LINE, 1, "en"},
        {"line break chinese", UBRK_LINE, 4, "en"},
        {"line break e_marks", UBRK_LINE, 8, "en"},
        {"line break jamo", UBRK_LINE, 9, "en"},
    };
    for (const auto& item : break_cases) {
        UErrorCode status = U_ZERO_ERROR;
        const auto& u16 = texts[item.text].u16;
        UBreakIterator* iterator = ubrk_open(item.type, item.locale, u16.data(),
            static_cast<int32_t>(u16.size()), &status);
        if (U_FAILURE(status)) continue;
        bench_bytes(item.label, texts[item.text].utf8.size(), 4000, [&] {
            ubrk_setText(iterator, u16.data(), static_cast<int32_t>(u16.size()), &status);
            while (ubrk_next(iterator) != UBRK_DONE) {}
        });
        ubrk_close(iterator);
    }

    std::printf("\n-- regular expressions --\n");
    {
        struct RegexCase {
            const char* label;
            const char* pattern;
            const char* text;
        };
        const RegexCase cases[] = {
            {"literal find", "needle",
                "some text before needle and after needle "},
            {"class find", "[0-9]{3}-[0-9]{4}",
                "call 555-1234 or 555-9876 for details "},
            {"case-insensitive find", "(?i)needle",
                "some text before Needle and after NEEDLE "},
            {"required literal miss", ".*needle",
                "some text without the required token "},
            {"literal alternation find", "needle|pin",
                "some text with needle or pin in it "},
        };
        for (const auto& item : cases) {
            std::string text;
            for (int i = 0; i < 8; i++) text += item.text;
            const std::vector<UChar> pattern = to_u16(item.pattern);
            const std::vector<UChar> subject = to_u16(text);
            UErrorCode status = U_ZERO_ERROR;
            UParseError parse_error;
            URegularExpression* regex = uregex_open(pattern.data(),
                static_cast<int32_t>(pattern.size()), 0, &parse_error, &status);
            if (U_FAILURE(status)) {
                std::printf("%-32s open failed\n", item.label);
                continue;
            }
            uregex_setText(regex, subject.data(),
                static_cast<int32_t>(subject.size()), &status);
            bench_ops(item.label, 400, [&] {
                status = U_ZERO_ERROR;
                uregex_reset(regex, 0, &status);
                while (uregex_findNext(regex, &status)) {}
            });
            uregex_close(regex);
        }

        struct MatchCase {
            const char* label;
            const char* pattern;
            const char* text;
        };
        const MatchCase match_cases[] = {
            {"literal matches", "needle", "needle"},
            {"literal matches miss", "needle", "some other text"},
            {"class matches miss", "[0-9]+", "abcdef"},
        };
        for (const auto& item : match_cases) {
            const std::vector<UChar> pattern = to_u16(item.pattern);
            const std::vector<UChar> subject = to_u16(item.text);
            UErrorCode status = U_ZERO_ERROR;
            UParseError parse_error;
            URegularExpression* regex = uregex_open(pattern.data(),
                static_cast<int32_t>(pattern.size()), 0, &parse_error, &status);
            if (U_FAILURE(status)) continue;
            uregex_setText(regex, subject.data(),
                static_cast<int32_t>(subject.size()), &status);
            bench_ops(item.label, 20000, [&] {
                status = U_ZERO_ERROR;
                uregex_matches(regex, 0, &status);
            });
            uregex_close(regex);
        }

        const struct { const char* label; const char* pattern; } compile_cases[] = {
            {"compile literal", "needle"},
            {"compile class", "[0-9]{3}-[0-9]{4}"},
            {"compile alternation", "needle|pin"},
            {"compile lookbehind", "(?<=x)abc"},
            {"compile word boundary", "\\bneedle\\b"},
            {"compile word class", "\\w+needle"},
        };
        for (const auto& item : compile_cases) {
            const std::vector<UChar> pattern = to_u16(item.pattern);
            bench_ops(item.label, 2000, [&] {
                UErrorCode status = U_ZERO_ERROR;
                UParseError parse_error;
                URegularExpression* regex = uregex_open(pattern.data(),
                    static_cast<int32_t>(pattern.size()), 0, &parse_error,
                    &status);
                if (U_SUCCESS(status)) uregex_close(regex);
            });
        }
    }

    std::printf("\n-- locale formatting --\n");
    {
        UErrorCode status = U_ZERO_ERROR;
        UListFormatter* formatter = ulistfmt_open("en", &status);
        std::vector<std::vector<UChar>> items;
        for (const char* text : {"alpha", "beta", "gamma", "delta"}) {
            items.push_back(to_u16(text));
        }
        std::vector<const UChar*> pointers;
        std::vector<int32_t> lengths;
        for (const auto& item : items) {
            pointers.push_back(item.data());
            lengths.push_back(static_cast<int32_t>(item.size()));
        }
        UChar out[128];
        bench_ops("list format 4 items", 20000, [&] {
            status = U_ZERO_ERROR;
            ulistfmt_format(formatter, pointers.data(), lengths.data(), 4,
                out, 128, &status);
        });
        ulistfmt_close(formatter);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        URelativeDateTimeFormatter* formatter = ureldatefmt_open(
            "en", nullptr, UDAT_STYLE_LONG, UDISPCTX_CAPITALIZATION_NONE,
            &status);
        UChar out[128];
        bench_ops("relative time", 20000, [&] {
            status = U_ZERO_ERROR;
            ureldatefmt_format(formatter, -3, UDAT_REL_UNIT_DAY, out, 128,
                &status);
        });
        ureldatefmt_close(formatter);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UDateFormat* format = udat_open(UDAT_FULL, UDAT_FULL, "en", nullptr, 0,
            nullptr, 0, &status);
        UCalendar* calendar = ucal_open(nullptr, 0, "en", UCAL_DEFAULT, &status);
        ucal_setDateTime(calendar, 2026, UCAL_NOVEMBER, 19, 13, 45, 30, &status);
        const UDate when = ucal_getMillis(calendar, &status);
        UChar out[128];
        bench_ops("date full format", 20000, [&] {
            status = U_ZERO_ERROR;
            udat_format(format, when, out, 128, nullptr, &status);
        });
        ucal_close(calendar);
        udat_close(format);
    }

    std::printf("\n-- shaping --\n");
    {
        const std::string texts[] = {
            "\u0627\u0644\u0633\u0644\u0627\u0645 \u0639\u0644\u064a\u0643\u0645 \u0648\u0631\u062d\u0645\u0629 \u0627\u0644\u0644\u0647 \u0648\u0628\u0631\u0643\u0627\u062a\u0647 ",
            "\u0644\u0627 \u0625\u0644\u0647 \u0625\u0644\u0627 \u0627\u0644\u0644\u0647 ",
        };
        std::vector<std::vector<UChar>> u16s;
        size_t bytes = 0;
        for (const auto& text : texts) {
            u16s.push_back(to_u16(text));
            bytes += text.size();
        }
        std::vector<UChar> dest(512);
        bench_bytes("Arabic shaping", bytes, 2000, [&] {
            for (const auto& u16 : u16s) {
                UErrorCode status = U_ZERO_ERROR;
                int32_t length = u_shapeArabic(u16.data(),
                    static_cast<int32_t>(u16.size()), dest.data(),
                    static_cast<int32_t>(dest.size()), U_SHAPE_LETTERS_SHAPE,
                    &status);
                (void)length;
            }
        });
    }

    std::printf("\n-- spoof --\n");
    {
        const char* texts[] = {
            "paypal",
            "p\xD0\xB0ypal",
            "\xCE\x91\xCE\x92\xCE\x93",
            "\xD0\x90\xD0\x92\xD0\xA1",
            "l", "1", "O", "0", "rn", "m", "scope",
            "g\xD0\xBE\xD0\xBEgle",
            "micros\xD0\xBE\xD1\x8Bt",
            "fi", "fl",
        };
        const int count = (int)(sizeof(texts) / sizeof(texts[0]));
        UErrorCode status = U_ZERO_ERROR;
        USpoofChecker* sc = uspoof_open(&status);
        if (U_SUCCESS(status)) {
            uspoof_setChecks(sc, uspoof_getChecks(sc, &status) | USPOOF_CONFUSABLE, &status);
            char buffer[256];
            int next = 0;
            bench_ops("spoof bidi skeleton", 4000 * count, [&] {
                const char* text = texts[next % count];
                next++;
                status = U_ZERO_ERROR;
                int32_t length = uspoof_getBidiSkeletonUTF8(sc, UBIDI_LTR, text,
                    -1, buffer, sizeof(buffer), &status);
                (void)length;
            });
            uspoof_close(sc);
        }
    }

    std::printf("\n-- idna --\n");
    {
        const char* domains[] = {
            "example.com",
            "m\xC3\xBCnchen.de",
            "\xE4\xBE\x8B\xE3\x81\x88.\xE3\x83\x86\xE3\x82\xB9\xE3\x83\x88",
            "\xCF\x80\xCE\xB1\xCF\x81\xCE\xAC\xCE\xB4\xCE\xB5\xCE\xB9\xCE\xB3\xCE\xBC\xCE\xB1.\xCE\xB4\xCE\xBF\xCE\xBA\xCE\xB9\xCE\xBC\xCE\xAE",
            "\xE0\xA6\xAC\xE0\xA6\xBE\xE0\xA6\x82\xE0\xA6\xB2\xE0\xA6\xBE.\xE0\xA6\xAD\xE0\xA6\xBE\xE0\xA6\xB0\xE0\xA6\xA4",
            "xn--mnchen-3ya.de",
            "\xD0\xBF\xD1\x80\xD0\xB5\xD0\xB7\xD0\xB8\xD0\xB4\xD0\xB5\xD0\xBD\xD1\x82.\xD1\x80\xD1\x84",
            "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E.jp",
        };
        const int count = (int)(sizeof(domains) / sizeof(domains[0]));
        UErrorCode status = U_ZERO_ERROR;
        UIDNA* idna = uidna_openUTS46(0, &status);
        char buffer[512];
        UIDNAInfo info = UIDNA_INFO_INITIALIZER;
        if (U_SUCCESS(status)) {
            int next = 0;
            bench_ops("idna toASCII", 4000 * count, [&] {
                const char* domain = domains[next % count];
                next++;
                status = U_ZERO_ERROR;
                info = UIDNA_INFO_INITIALIZER;
                int32_t length = uidna_nameToASCII_UTF8(idna, domain, -1,
                    buffer, sizeof(buffer), &info, &status);
                (void)length;
            });
            next = 0;
            bench_ops("idna toUnicode", 4000 * count, [&] {
                const char* domain = domains[next % count];
                next++;
                status = U_ZERO_ERROR;
                info = UIDNA_INFO_INITIALIZER;
                int32_t length = uidna_nameToUnicodeUTF8(idna, domain, -1,
                    buffer, sizeof(buffer), &info, &status);
                (void)length;
            });
            uidna_close(idna);
        }
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
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_DECIMAL, nullptr, 0, "en", nullptr, &status);
        const std::vector<UChar> text = to_u16("1,234,567.89");
        bench_ops("parse decimal", 200000, [&] {
            status = U_ZERO_ERROR;
            int32_t position = 0;
            unum_parseDouble(format, text.data(),
                static_cast<int32_t>(text.size()), &position, &status);
        });
        unum_close(format);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_SCIENTIFIC, nullptr, 0, "en", nullptr, &status);
        UChar out[128];
        bench_ops("scientific number", 20000, [&] {
            status = U_ZERO_ERROR;
            unum_formatDouble(format, 1234.5, out, 128, nullptr, &status);
        });
        unum_close(format);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_CURRENCY, nullptr, 0, "en", nullptr, &status);
        UChar out[128];
        bench_ops("currency standard", 20000, [&] {
            status = U_ZERO_ERROR;
            unum_formatDouble(format, 1234.5, out, 128, nullptr, &status);
        });
        unum_close(format);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_CURRENCY_ACCOUNTING, nullptr, 0, "en", nullptr, &status);
        UChar out[128];
        bench_ops("accounting currency", 20000, [&] {
            status = U_ZERO_ERROR;
            unum_formatDouble(format, 1234.5, out, 128, nullptr, &status);
        });
        unum_close(format);
    }
    {
        UErrorCode status = U_ZERO_ERROR;
        UNumberFormat* format = unum_open(UNUM_CURRENCY_PLURAL, nullptr, 0, "en", nullptr, &status);
        UChar out[128];
        bench_ops("currency name", 20000, [&] {
            status = U_ZERO_ERROR;
            unum_formatDouble(format, 1234.5, out, 128, nullptr, &status);
        });
        unum_close(format);
    }
    return 0;
}
