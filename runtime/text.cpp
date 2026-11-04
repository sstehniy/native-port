/* Win32 text conversions. ACP is Windows-1252 for the en-US system profile. */
#include "runtime.h"

#include <algorithm>
#include <climits>
#include "cp1252_bestfit.h"

static constexpr char16_t cp1252[] = {
    0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021,
    0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
    0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
};

static uint64_t conversion_error(uint32_t code) { rt_set_last_error(code); return 0; }

template <class Unit> static uint64_t put_converted(const std::basic_string<Unit> &text, void *out, int capacity) {
    if (text.size() > INT_MAX) return conversion_error(87);
    if (capacity) {
        if (text.size() > (size_t)capacity) return conversion_error(122);
        memcpy(out, text.data(), text.size() * sizeof(Unit));
    }
    return text.size();
}

H(MultiByteToWideChar) {
    const uint32_t page = A(0), flags = A(1);
    const char *source = P(2);
    const int32_t length = A(3), capacity = A(5);
    if (!source || !length || length < -1 || capacity < 0 || (capacity && (!P(4) || A(2) == A(4))))
        return conversion_error(87);
    if (page != 0 && page != 3 && page != 1252 && page != 65001) return conversion_error(87);
    if (flags & ~(page == 65001 ? 8u : 9u)) return conversion_error(1004);
    const std::string_view in(source, length == -1 ? strlen(source) + 1 : (size_t)length);
    std::u16string out;
    for (size_t i = 0; i < in.size();) {
        const uint8_t first = in[i++];
        uint32_t ch = first;
        if (page != 65001) {
            if (first >= 0x80 && first < 0xa0) ch = cp1252[first - 0x80];
        } else if (first >= 0x80) {
            int count = 0;
            if (first >= 0xc2 && first <= 0xdf) { count = 1; ch &= 31; }
            else if (first >= 0xe0 && first <= 0xef) { count = 2; ch &= 15; }
            else if (first >= 0xf0 && first <= 0xf4) { count = 3; ch &= 7; }
            bool valid = count != 0;
            for (int n = 0; valid && n < count; ++n) {
                if (i == in.size()) { valid = false; break; }
                const uint8_t next = in[i];
                if (next < 0x80 || next > 0xbf || (n == 0 &&
                    ((first == 0xe0 && next < 0xa0) || (first == 0xed && next >= 0xa0) ||
                     (first == 0xf0 && next < 0x90) || (first == 0xf4 && next >= 0x90)))) {
                    valid = false;
                    break;
                }
                ++i;
                ch = (ch << 6) | (next & 63);
            }
            if (!valid) {
                if (flags & 8) return conversion_error(1113);
                ch = 0xfffd;
            }
        }
        if (ch >= 0x10000) out += {(char16_t)(0xd800 + ((ch - 0x10000) >> 10)), (char16_t)(0xdc00 + (ch & 1023))};
        else out += (char16_t)ch;
    }
    return put_converted(out, P(4), capacity);
}

H(WideCharToMultiByte) {
    const uint32_t page = A(0), flags = A(1);
    const char16_t *source = P(2);
    const int32_t length = A(3), capacity = A(5);
    if (!source || !length || length < -1 || capacity < 0 || (capacity && (!P(4) || A(2) == A(4))))
        return conversion_error(87);
    if (page != 0 && page != 3 && page != 1252 && page != 65001) return conversion_error(87);
    if (page == 65001 && (P(6) || P(7))) return conversion_error(87);
    if (flags & ~(page == 65001 ? 0x80u : 0x400u)) return conversion_error(1004);
    const std::u16string_view in(source, length == -1 ? std::char_traits<char16_t>::length(source) + 1 : (size_t)length);
    std::string out;
    uint32_t used_default = 0;
    for (size_t i = 0; i < in.size(); ++i) {
        uint32_t ch = in[i];
        if (ch >= 0xd800 && ch <= 0xdbff && i + 1 < in.size() && in[i + 1] >= 0xdc00 && in[i + 1] <= 0xdfff)
            ch = 0x10000 + ((ch - 0xd800) << 10) + (in[++i] - 0xdc00);
        else if (ch >= 0xd800 && ch <= 0xdfff) {
            if (flags & 0x80) return conversion_error(1113);
            ch = 0xfffd;
        }
        if (page == 65001) {
            if (ch < 0x80) out += (char)ch;
            else if (ch < 0x800) out += {(char)(0xc0 | ch >> 6), (char)(0x80 | (ch & 63))};
            else if (ch < 0x10000) out += {(char)(0xe0 | ch >> 12), (char)(0x80 | (ch >> 6 & 63)), (char)(0x80 | (ch & 63))};
            else out += {(char)(0xf0 | ch >> 18), (char)(0x80 | (ch >> 12 & 63)), (char)(0x80 | (ch >> 6 & 63)), (char)(0x80 | (ch & 63))};
        } else {
            const auto found = std::find(std::begin(cp1252), std::end(cp1252), ch);
            if (ch < 0x80 || (ch >= 0xa0 && ch <= 0xff)) out += (char)ch;
            else if (found != std::end(cp1252)) out += (char)(0x80 + (found - cp1252));
            else {
                const auto best = std::lower_bound(std::begin(cp1252_bestfit), std::end(cp1252_bestfit), ch << 8);
                if (!(flags & 0x400) && ch >= 0xff01 && ch <= 0xff5e) out += (char)(ch - 0xfee0);
                else if (!(flags & 0x400) && best != std::end(cp1252_bestfit) && (*best >> 8) == ch) out += (char)*best;
                else { out += P(6) ? *static_cast<const char *>(P(6)) : '?'; used_default = 1; }
            }
        }
    }
    if (P(7)) rt_put(P(7), used_default);
    return put_converted(out, P(4), capacity);
}

/* English messages for the errors our file, memory and synchronization services return.
 * shortcut: no module message resources or localized catalog; extend when a caller needs one. */
static const char *system_message(uint32_t code) {
    switch (code) {
    case 0: return "The operation completed successfully.\r\n";
    case 2: return "The system cannot find the file specified.\r\n";
    case 3: return "The system cannot find the path specified.\r\n";
    case 5: return "Access is denied.\r\n";
    case 6: return "The handle is invalid.\r\n";
    case 8: return "Not enough memory resources are available to process this command.\r\n";
    case 14: return "Not enough storage is available to complete this operation.\r\n";
    case 18: return "There are no more files.\r\n";
    case 31: return "A device attached to the system is not functioning.\r\n";
    case 38: return "Reached the end of the file.\r\n";
    case 50: return "The request is not supported.\r\n";
    case 80: return "The file exists.\r\n";
    case 87: return "The parameter is incorrect.\r\n";
    case 112: return "There is not enough space on the disk.\r\n";
    case 122: return "The data area passed to a system call is too small.\r\n";
    case 126: return "The specified module could not be found.\r\n";
    case 127: return "The specified procedure could not be found.\r\n";
    case 145: return "The directory is not empty.\r\n";
    case 183: return "Cannot create a file when that file already exists.\r\n";
    case 258: return "The wait operation timed out.\r\n";
    case 259: return "No more data is available.\r\n";
    case 487: return "Attempt to access invalid address.\r\n";
    case 995: return "The I/O operation has been aborted because of either a thread exit or an application request.\r\n";
    case 997: return "Overlapped I/O operation is in progress.\r\n";
    case 1113: return "No mapping for the Unicode character exists in the target multi-byte code page.\r\n";
    default: return nullptr;
    }
}

H(FormatMessageW) {
    const uint32_t flags = A(0);
    if (!P(4) || (flags & 0x400 && flags & 0x1800)) return conversion_error(87);
    std::u16string text;
    if (flags & 0x400) {
        if (!P(1)) return conversion_error(87);
        text = static_cast<const char16_t *>(P(1));
    } else {
        if (!(flags & 0x1000)) return conversion_error(317);
        const char *message = system_message((uint32_t)A(2));
        if (!message) return conversion_error(317);
        text = rt_utf16(message);
    }
    std::u16string out;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] != '%') {
            if ((flags & 0xff) == 0xff && (text[i] == '\r' || text[i] == '\n')) {
                if (text[i] == '\r' && i + 1 < text.size() && text[i + 1] == '\n') ++i;
                out += ' ';
            } else out += text[i];
            continue;
        }
        if (++i == text.size()) return conversion_error(87);
        char16_t ch = text[i];
        if (ch == '0') break;
        if (ch == 'n') out += u"\r\n";
        else if (ch == 'r') out += '\r';
        else if (ch == 't') out += '\t';
        else if (ch == 'b') out += ' ';
        else if (ch >= '1' && ch <= '9') {
            const size_t start = i - 1;
            unsigned index = ch - '0';
            if (i + 1 < text.size() && text[i + 1] >= '0' && text[i + 1] <= '9') index = index * 10 + text[++i] - '0';
            if (flags & 0x200) {
                size_t end = i + 1;
                if (end < text.size() && text[end] == '!') {
                    const size_t close = text.find('!', end + 1);
                    end = close == std::u16string::npos ? text.size() : close + 1;
                }
                out.append(text, start, end - start);
                i = end - 1;
                continue;
            }
            if (!P(6)) return conversion_error(87);
            const uint64_t *args = P(6);
            if (!(flags & 0x2000)) args = reinterpret_cast<const uint64_t *>(*args);
            // The game's system-error calls ignore inserts; FROM_STRING supports UTF-16 string inserts.
            if (i + 1 < text.size() && text[i + 1] == '!') {
                if (text.substr(i + 1, 3) != u"!s!") return conversion_error(87);
                i += 3;
            }
            const char16_t *insert = reinterpret_cast<const char16_t *>(args[index - 1]);
            if (!insert) return conversion_error(87);
            out += insert;
        } else out += ch;
    }
    if ((flags & 0xff) && (flags & 0xff) != 0xff) return conversion_error(87);
    char16_t *buffer = P(4);
    if (flags & 0x100) {
        buffer = static_cast<char16_t *>(rt_local_alloc(std::max<uint64_t>(out.size() + 1, (uint32_t)A(5)) * 2));
        if (!buffer) return conversion_error(8);
        rt_put<uint64_t>(P(4), reinterpret_cast<uintptr_t>(buffer));
    } else if (out.size() >= (uint32_t)A(5)) return conversion_error(122);
    memcpy(buffer, out.c_str(), (out.size() + 1) * 2);
    return out.size();
}

const RtEntry rt_text_entries[] = {
    {"MultiByteToWideChar", MultiByteToWideChar}, {"WideCharToMultiByte", WideCharToMultiByte},
    {"FormatMessageW", FormatMessageW}, {nullptr, nullptr},
};
