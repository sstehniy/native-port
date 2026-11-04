/* Import-level edge cases; Win64 varargs and callback lifecycle live in crt_guest.c. */
#include "../runtime.h"
#include <algorithm>
#include <cassert>
#include <climits>
#include <cfenv>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <sys/wait.h>
#include <unistd.h>

template <class... Args> static uint64_t call(const char *name, Args... values) {
    const uint64_t args[] = {static_cast<uint64_t>(values)...};
    uint64_t stack[16] = {};
    BbCpu cpu = {};
    const int regs[] = {RCX, RDX, R8, R9};
    for (size_t i = 0; i < sizeof...(values); ++i) {
        if (i < 4) cpu.r[regs[i]] = args[i];
        else stack[i] = args[i];
    }
    WinCall context{&cpu, (uintptr_t)stack, nullptr};
    const auto handler = rt_find_handler("ucrtbase.dll", name);
    assert(handler);
    return handler(&context);
}
template <class T> static uint64_t ptr(T *p) { return (uintptr_t)p; }

static void encoding() {
    char16_t wide[16];
    std::fill(std::begin(wide), std::end(wide), 0xcccc);
    const char text[] = "\xc3\xa9/\xe6\xb0\xb4/\xf0\x9f\x8c\x9f";
    const std::u16string expected = u"é/水/🌟";
    assert(call("MultiByteToWideChar", 65001, 8, ptr(text), -1, 0, 0) == 7);
    assert(call("MultiByteToWideChar", 65001, 8, ptr(text), -1, ptr(wide), 7) == 7 && wide[7] == 0xcccc);
    assert(wide == expected);
    char narrow[64] = {};
    assert(call("WideCharToMultiByte", 65001, 0, ptr(wide), -1, ptr(narrow), sizeof(narrow), 0, 0) == sizeof(text));
    assert(!strcmp(narrow, text));
    wide[0] = 0xcccc;
    assert(!call("MultiByteToWideChar", 65001, 0, ptr(text), -1, ptr(wide), 6) && rt_last_error() == 122 && wide[0] == 0xcccc);
    for (const std::string &bad : {std::string("\xc0\xaf"), std::string("\xed\xa0\x80"), std::string("\xf4\x90\x80\x80"), std::string("\xe2\x82")})
        assert(!call("MultiByteToWideChar", 65001, 8, ptr(bad.data()), bad.size(), ptr(wide), 16) && rt_last_error() == 1113);
    assert(call("MultiByteToWideChar", 65001, 0, ptr("\xe2\x82"), 2, ptr(wide), 16) == 1 && wide[0] == 0xfffd);
    assert(!call("MultiByteToWideChar", 65001, 1, ptr("x"), 1, ptr(wide), 16) && rt_last_error() == 1004);
    assert(!call("MultiByteToWideChar", 65001, 0, ptr("x"), -2, ptr(wide), 16) && rt_last_error() == 87);
    assert(!call("MultiByteToWideChar", 65001, 0, ptr("x"), 1, 0, 2) && rt_last_error() == 87);
    assert(!call("MultiByteToWideChar", 12345, 0, ptr("x"), 1, ptr(wide), 16) && rt_last_error() == 87);
    const char16_t invalid[] = {0xd800, 'X', 0};
    assert(!call("WideCharToMultiByte", 65001, 0x80, ptr(invalid), -1, ptr(narrow), 64, 0, 0) && rt_last_error() == 1113);
    assert(call("WideCharToMultiByte", 65001, 0, ptr(invalid), -1, ptr(narrow), 64, 0, 0) == 5 && !strcmp(narrow, "\xef\xbf\xbdX"));
    assert(call("MultiByteToWideChar", 0, 0, ptr("\x80\xe9"), 2, ptr(wide), 16) == 2 && wide[0] == 0x20ac && wide[1] == 0xe9);
    uint32_t used = 99;
    assert(call("WideCharToMultiByte", 1252, 0x400, ptr(u"€é水"), -1, ptr(narrow), 64, 0, ptr(&used)) == 4);
    assert(!memcmp(narrow, "\x80\xe9?", 4) && used == 1);
    assert(call("WideCharToMultiByte", 1252, 0, ptr(u"Āıα∞Ａ"), -1, ptr(narrow), 64, 0, ptr(&used)) == 6 && !strcmp(narrow, "Aia8A") && !used);
    assert(call("WideCharToMultiByte", 1252, 0x400, ptr(u"Āıα∞Ａ"), -1, ptr(narrow), 64, ptr("!"), ptr(&used)) == 6 && !strcmp(narrow, "!!!!!") && used);
    assert(call("WideCharToMultiByte", 65001, 0, ptr(u"a\0b"), 3, ptr(narrow), 64, 0, 0) == 3 && !memcmp(narrow, "a\0b", 3));
    assert(!call("FormatMessageW", 0x1200, 0, 5, 0, ptr(wide), 16, 0) && rt_last_error() == 122);
    char16_t message[128] = {};
    assert(call("FormatMessageW", 0x1200, 0, 5, 0, ptr(message), 128, 0) == 19 && std::u16string(message) == u"Access is denied.\r\n");
    assert(!call("FormatMessageW", 0x1200, 0, 0xfedcba, 0, ptr(message), 128, 0) && rt_last_error() == 317);
    char16_t *allocated = nullptr;
    assert(call("FormatMessageW", 0x1300, 0, 2, 0, ptr(&allocated), 0, 0) > 0 && allocated);
    assert(call("LocalFree", ptr(allocated)) == 0);
    const uint64_t inserts[] = {ptr(u"World"), ptr(u"Hello")};
    assert(call("FormatMessageW", 0x2400, ptr(u"%2, %1!s!!%n%0ignored"), 0, 0, ptr(message), 128, ptr(inserts)) == 15);
    assert(std::u16string(message) == u"Hello, World!\r\n");
    for (const auto &test : std::vector<std::pair<const char16_t *, const char16_t *>>{
            {u"A%nB%1%0tail", u"A\r\nB%1"}, {u"%% %r %t %b %12!s!", u"% \r \t   %12!s!"}}) {
        assert(call("FormatMessageW", 0x600, ptr(test.first), 0, 0, ptr(message), 128, 0) == std::u16string_view(test.second).size());
        assert(std::u16string(message) == test.second);
    }
    for (const auto &test : std::vector<std::pair<const char16_t *, const char16_t *>>{
            {u"A%nB", u"A\r\nB"}, {u"A%rB", u"A\rB"}, {u"A\nB", u"A B"}, {u"A\r\nB", u"A B"},
            {u"A\rB", u"A B"}, {u"A\nB%nC", u"A B\r\nC"}}) {
        assert(call("FormatMessageW", 0x4ff, ptr(test.first), 0, 0, ptr(message), 128, 0) == std::u16string_view(test.second).size());
        assert(std::u16string(message) == test.second);
    }
}

static void strings() {
    char bytes[16] = "abcde";
    assert(call("memmove", ptr(bytes + 1), ptr(bytes), 5) == ptr(bytes + 1) && !memcmp(bytes, "aabcde", 6));
    assert(call("memset", ptr(bytes), 0x123, 3) == ptr(bytes) && !memcmp(bytes, "###", 3));
    assert(call("memcpy", ptr(bytes), ptr("a\0b\0"), 4) == ptr(bytes));
    assert(call("memchr", ptr(bytes), 'b', 4) == ptr(bytes + 2) && !call("memchr", ptr(bytes), 'z', 4));
    assert((int32_t)call("memcmp", ptr("\xff"), ptr("\x01"), 1) > 0);
    assert(call("strlen", ptr("abc")) == 3 && (int32_t)call("strcmp", ptr("abc"), ptr("abd")) < 0);
    assert(call("strncmp", ptr("abC"), ptr("abd"), 2) == 0);
    const char *text = "a-b-a";
    assert(call("strrchr", ptr(text), 'a') == ptr(text + 4) && call("strstr", ptr(text), ptr("b-a")) == ptr(text + 2));
    memset(bytes, '#', sizeof(bytes));
    assert(call("strncpy", ptr(bytes), ptr("ab"), 5) == ptr(bytes) && !memcmp(bytes, "ab\0\0\0#", 6));
    char16_t out[8];
    std::fill(std::begin(out), std::end(out), 0xcccc);
    assert(call("wcsncpy", ptr(out), ptr(u"水"), 4) == ptr(out) && out[0] == u'水' && !out[1] && !out[3] && out[4] == 0xcccc);
    assert(call("wcsstr", ptr(u"星水星"), ptr(u"水")) != 0);
    const char16_t *haystack = u"星水星";
    assert(call("wcsstr", ptr(haystack), ptr(u"")) == ptr(haystack));
    assert(!call("wcsstr", ptr(haystack), ptr(u"a")));
    assert(call("wcsncpy_s", ptr(out), 3, ptr(u"ABCD"), UINT64_MAX) == 80 && std::u16string(out) == u"AB");
    assert(call("wcsncpy_s", ptr(out), 3, ptr(u"ABCD"), 3) == 34 && !out[0]);
    assert(call("strncpy_s", ptr(out), 3, 0, 0) == 0 && !out[0]);
    for (const auto &test : std::vector<std::pair<const char *, int64_t>>{
        {"2147483647!", INT32_MAX}, {"2147483648!", INT32_MAX}, {"99999999999999999999999!", INT32_MAX},
        {"-2147483648!", INT32_MIN}, {"-2147483649!", INT32_MIN}, {"-99999999999999999999999!", INT32_MIN}}) {
        char *end = nullptr;
        assert((int64_t)call("strtol", ptr(test.first), ptr(&end), 10) == test.second && *end == '!');
    }
    char *end;
    assert(call("strtol", ptr("  +0x7f!"), ptr(&end), 0) == 127 && *end == '!');
    assert(call("_configthreadlocale", 99) == UINT32_MAX);
    assert(call("_initialize_onexit_table", 0) == UINT32_MAX && call("_execute_onexit_table", 0) == UINT32_MAX);
}

static void formatting() {
    struct Case { const char *format, *expected; std::vector<uint64_t> args; uint64_t options = 0; };
    for (const auto &test : std::vector<Case>{
        {"%I64d %I64u", "-9223372036854775808 18446744073709551615", {UINT64_C(0x8000000000000000), UINT64_MAX}},
        {"%ld %lu %hhd %hd", "-1 4294967295 -1 -32768", {UINT64_MAX, UINT64_MAX, 255, 32768}},
        {"%Iu %zu %td", "4294967296 4294967296 -4294967296", {UINT64_C(1)<<32, UINT64_C(1)<<32, (uint64_t)-INT64_C(4294967296)}},
        {"%#08x|%+.5d|%-6.3s|%*.*s|%.0u|%#.0o", "0x00002a|+00042|abc   |   ab||0", {42,42,ptr("abcdef"),5,2,ptr("abc"),0,0}},
        {"%ls %S %hs %C %%", "wide WIDE byte X %", {ptr(u"wide"),ptr(u"WIDE"),ptr("byte"),'X'}},
        {"%p %p", "0000000000001234 0000000000000000", {0x1234,0}},
        {"%s %.3s", "(null) (nu", {0,0}},
        {"%.2f %.3e %.4g", "1.25 1.250e+00 1.25", {UINT64_C(0x3ff4000000000000),UINT64_C(0x3ff4000000000000),UINT64_C(0x3ff4000000000000)}},
        {"%.0f %.0f", "3 -3", {UINT64_C(0x4004000000000000),UINT64_C(0xc004000000000000)}},
        {"%.0f %.0f", "2 -2", {UINT64_C(0x4004000000000000),UINT64_C(0xc004000000000000)},32},
        {"%.1e", "1.0e+000", {UINT64_C(0x3ff0000000000000)},16},
        {"%f %F", "inf -INF", {UINT64_C(0x7ff0000000000000),UINT64_C(0xfff0000000000000)}},
    }) {
        char out[256] = {};
        const uint64_t n = call("__stdio_common_vsprintf", test.options, ptr(out), sizeof(out), ptr(test.format), 0, ptr(test.args.data()));
        if (n != strlen(test.expected) || strcmp(out, test.expected)) fprintf(stderr, "format %s: got <%s> (%llu), expected <%s>\n", test.format, out, (unsigned long long)n, test.expected);
        assert(n == strlen(test.expected) && !strcmp(out, test.expected));
    }
    for (uint64_t options : {0,1,2}) for (size_t capacity = 0; capacity <= 5; ++capacity) {
        char out[8]; memset(out, '#', sizeof(out));
        const int32_t result = call("__stdio_common_vsprintf", options, ptr(out), capacity, ptr("ABCD"), 0, 0);
        if (options == 2) { assert(result == 4); if (capacity) assert(out[capacity - 1] == 0); }
        else if (capacity > 4 || (options == 1 && capacity == 4)) assert(result == 4);
        else if (options == 0 && capacity) assert(result == -2);
        else assert(result == -1);
        assert(out[capacity] == '#');
    }
    assert(call("__stdio_common_vsprintf", 2, 0, 0, ptr("ABCD"), 0, 0) == 4);
    char16_t wide[64] = {};
    const uint64_t args[] = {ptr(u"星🌟"), ptr("byte"), ptr(u"wide"), ptr("small"), 42};
    assert(call("__stdio_common_vswprintf_s", 4, ptr(wide), 64, ptr(u"%s %S %ls %hs %d"), 0, ptr(args)) == 22);
    assert(std::u16string(wide) == u"星🌟 byte wide small 42");
    const uint64_t narrow_arg[] = {ptr("byte")};
    assert(call("__stdio_common_vswprintf_s", 0, ptr(wide), 64, ptr(u"%s"), 0, ptr(narrow_arg)) == 4 && std::u16string(wide) == u"byte");
    assert((int32_t)call("__stdio_common_vswprintf_s", 0, ptr(wide), 4, ptr(u"ABCD"), 0, 0) == -1 && !wide[0]);
    char out[16] = "unchanged";
    int count = 77;
    const uint64_t count_arg[] = {ptr(&count)};
    assert((int32_t)call("__stdio_common_vsprintf", 0, ptr(out), 16, ptr("%n"), 0, ptr(count_arg)) == -1 && count == 77 && !out[0]);
    fenv_t saved;
    fegetenv(&saved); fesetround(FE_UPWARD);
    const uint64_t tie[] = {UINT64_C(0x4004000000000000)};
    assert(call("__stdio_common_vsprintf", 32, ptr(out), 16, ptr("%.0f"), 0, ptr(tie)) == 1 && !strcmp(out, "2"));
    assert(fegetround() == FE_UPWARD);
    fesetenv(&saved);
}

static void fatal_calls() {
    for (const auto &test : std::vector<std::pair<const char *, const char *>>{
            {"_wassert", "assertion failed: water"}, {"_purecall", "game called _purecall()"},
            {"terminate", "game called terminate()"}}) {
        int errors[2]; assert(pipe(errors) == 0);
        fflush(nullptr);
        const pid_t child = fork(); assert(child >= 0);
        if (!child) {
            close(errors[0]); assert(dup2(errors[1], STDERR_FILENO) >= 0); close(errors[1]);
            call(test.first, ptr(u"water"), ptr(u"test"), 42); _exit(99);
        }
        close(errors[1]);
        char message[256] = {};
        FILE *log = fdopen(errors[0], "r"); assert(log);
        const size_t n = fread(message, 1, sizeof(message) - 1, log); fclose(log);
        int status; assert(waitpid(child, &status, 0) == child);
        assert(n > 0 && strstr(message, test.second) && WIFEXITED(status) && WEXITSTATUS(status) == 2);
    }
}

int main() {
    encoding();
    strings();
    formatting();
    fatal_calls();
    puts("CRT import edge cases passed");
}
