/* Microsoft formatting over Win64 va_list slots, never the host's va_list or wchar_t ABI. */
#include "runtime.h"

#include <algorithm>
#include <bit>
#include <charconv>
#include <climits>
#include <cmath>
#include <cfenv>
#include <cstdio>
#include <locale.h>
#include <vector>

enum : uint64_t { LEGACY_TERMINATION = 1, STANDARD_SNPRINTF = 2, LEGACY_WIDE = 4,
                  LEGACY_EXPONENT = 16, STANDARD_ROUNDING = 32 };

static std::string hex_float(uint64_t bits, char type, int precision, bool alternate, uint64_t options) {
    const char *digits = type == 'A' ? "0123456789ABCDEF" : "0123456789abcdef";
    const unsigned exponent_bits = (bits >> 52) & 2047;
    uint64_t mantissa = bits & UINT64_C(0xfffffffffffff);
    int exponent = 0;
    if (exponent_bits) { mantissa |= UINT64_C(1) << 52; exponent = (int)exponent_bits - 1023; }
    else if (mantissa) exponent = -1022;
    if (precision < 0) precision = 13;
    if (precision < 13) {
        const unsigned shift = 52 - precision * 4;
        const uint64_t tail = mantissa & ((UINT64_C(1) << shift) - 1), half = UINT64_C(1) << (shift - 1);
        uint64_t kept = mantissa >> shift;
        bool up = tail >= half;
        if (options & STANDARD_ROUNDING) {
            const int rounding = fegetround();
            if (rounding == FE_TONEAREST) up = tail > half || (tail == half && (kept & 1));
            else if (rounding == FE_UPWARD) up = tail && !(bits >> 63);
            else if (rounding == FE_DOWNWARD) up = tail && (bits >> 63);
            else up = false;
        }
        if (up) ++kept;
        mantissa = kept << shift;
    }
    std::string out = type == 'A' ? "0X" : "0x";
    out += digits[mantissa >> 52];
    if (precision || alternate) out += '.';
    for (int i = 0; i < precision; ++i) {
        if (i < 13) out += digits[(mantissa >> (48 - 4 * i)) & 15];
        else out += '0';
    }
    out += type == 'A' ? 'P' : 'p';
    if (exponent >= 0) out += '+';
    out += std::to_string(exponent);
    return out;
}

/* An exact decimal tie whose lower neighbor is even. Check its binary factors so high precision
 * ties work too; perturbing the double would change more digits than the last printed one. */
static bool legacy_rounds_down(uint64_t bits, int64_t places) {
    uint64_t mantissa = bits & UINT64_C(0xfffffffffffff);
    const int exponent_bits = (bits >> 52) & 2047;
    int exponent = -1074;
    if (exponent_bits) { mantissa |= UINT64_C(1) << 52; exponent = exponent_bits - 1075; }
    if (!mantissa) return false;
    if (places + exponent + std::countr_zero(mantissa) != -1) return false;
    for (int64_t i = 0; i > places; --i) {
        if (mantissa % 5) return false;
        mantissa /= 5;
    }
    return ((mantissa >> std::countr_zero(mantissa)) & 3) == 1;
}

template <class Ch> static bool format(std::basic_string<Ch> &out, const Ch *f, const uint8_t *args, uint64_t options) {
    const auto next = [&]() {
        if (!args) rt_fatal("printf missing guest argument list");
        uint64_t value;
        memcpy(&value, args, 8);
        args += 8;
        return value;
    };
    const auto decimal = [&f](int &n) {
        n = 0;
        while (*f >= '0' && *f <= '9') {
            if (n > (INT_MAX - (*f - '0')) / 10) return false;
            n = n * 10 + *f++ - '0';
        }
        return true;
    };
    while (*f) {
        if (*f != '%') { out += *f++; continue; }
        ++f;
        if (*f == '%') { out += *f++; continue; }
        bool left = false, plus = false, space = false, zero = false, alternate = false;
        for (bool flags = true; flags;) {
            switch (*f) {
            case '-': left = true; ++f; break;
            case '+': plus = true; ++f; break;
            case ' ': space = true; ++f; break;
            case '0': zero = true; ++f; break;
            case '#': alternate = true; ++f; break;
            default: flags = false;
            }
        }
        int width = 0, precision = -1;
        if (*f == '*') {
            width = (int32_t)next(); ++f;
            if (width == INT_MIN) return false;
            if (width < 0) { left = true; width = -width; }
        } else if (!decimal(width)) return false;
        if (*f == '.') {
            ++f;
            if (*f == '*') { precision = (int32_t)next(); ++f; }
            else if (!decimal(precision)) return false;
        }
        enum Length { Default, HH, H, L, LL, I, I32, I64, W, Z, T, J, BigL } length = Default;
        switch (*f) {
        case 'h': ++f; length = H; if (*f == 'h') { ++f; length = HH; } break;
        case 'l': ++f; length = L; if (*f == 'l') { ++f; length = LL; } break;
        case 'I':
            ++f; length = I;
            if (f[0] == '3' && f[1] == '2') { f += 2; length = I32; }
            else if (f[0] == '6' && f[1] == '4') { f += 2; length = I64; }
            break;
        case 'w': ++f; length = W; break;
        case 'z': ++f; length = Z; break;
        case 't': ++f; length = T; break;
        case 'j': ++f; length = J; break;
        case 'L': ++f; length = BigL; break;
        }
        const Ch type = *f;
        if (!type) return false;
        ++f;
        std::basic_string<Ch> piece;
        size_t prefix = 0;
        bool numeric = false;
        if (type == 's' || type == 'S' || type == 'c' || type == 'C') {
            bool wide = false;
            if (length == L || length == W) wide = true;
            else if (length != H && length != HH) {
                wide = type == 'S' || type == 'C';
                if constexpr (sizeof(Ch) == 2) {
                    if (options & LEGACY_WIDE) wide = !wide;
                }
            }
            const uint64_t value = next();
            const bool string = type == 's' || type == 'S';
            const auto append_unit = [&](uint16_t unit) {
                if constexpr (sizeof(Ch) == 1) { if (unit > 255) return false; }
                piece += (Ch)unit;
                return true;
            };
            if (!string) {
                if (!append_unit(wide ? (uint16_t)value : (uint8_t)value)) return false;
            } else if (!value) {
                for (const char ch : std::string_view("(null)")) piece += (Ch)ch;
                if (precision >= 0 && piece.size() > (size_t)precision) piece.resize(precision);
            } else {
                const uint8_t *p = reinterpret_cast<const uint8_t *>(value);
                while (precision < 0 || piece.size() < (size_t)precision) {
                    uint16_t unit = 0;
                    memcpy(&unit, p, wide ? 2 : 1);
                    if (!unit) break;
                    if (!append_unit(unit)) return false;
                    p += wide ? 2 : 1;
                }
            }
        } else if (type == 'd' || type == 'i' || type == 'u' || type == 'o' || type == 'x' || type == 'X' || type == 'p') {
            numeric = true;
            const bool explicit_precision = precision >= 0;
            const bool signed_type = type == 'd' || type == 'i';
            const bool pointer = type == 'p';
            uint64_t value = next();
            unsigned bits = 32;
            if (length == HH) bits = 8;
            else if (length == H) bits = 16;
            else if (pointer || length == LL || length == I64 || length == I || length == Z || length == T || length == J) bits = 64;
            if (bits < 64) value &= (UINT64_C(1) << bits) - 1;
            const bool negative = signed_type && (value & (UINT64_C(1) << (bits - 1)));
            if (negative) {
                if (bits < 64) value |= UINT64_MAX << bits;
                value = 0 - value;
                piece += '-';
            } else if (signed_type && plus) piece += '+';
            else if (signed_type && space) piece += ' ';
            int base = 10;
            if (type == 'o') base = 8;
            else if (type == 'x' || type == 'X' || pointer) base = 16;
            if (alternate && value && base == 16 && !pointer) { piece += '0'; piece += type; }
            prefix = piece.size();
            char digits[65];
            const auto converted = std::to_chars(digits, digits + sizeof(digits), value, base);
            size_t count = converted.ptr - digits;
            if (!value && precision == 0 && !pointer) count = 0;
            if (pointer) precision = 16;
            if (alternate && base == 8 && (!count || digits[0] != '0')) precision = std::max<int>(precision, (int)count + 1);
            if (precision > (int)count) piece.append(precision - count, '0');
            for (size_t i = 0; i < count; ++i) {
                char ch = digits[i];
                if ((type == 'X' || pointer) && ch >= 'a' && ch <= 'f') ch -= 'a' - 'A';
                piece += (Ch)ch;
            }
            if (explicit_precision && !pointer) zero = false;
        } else if (type == 'f' || type == 'F' || type == 'e' || type == 'E' || type == 'g' || type == 'G' || type == 'a' || type == 'A') {
            numeric = true;
            const uint64_t bits = next();
            double value;
            memcpy(&value, &bits, 8);
            std::string spec = "%";
            if (plus) spec += '+';
            else if (space) spec += ' ';
            if (alternate) spec += '#';
            if (precision >= 0) spec += '.' + std::to_string(precision);
            spec += (char)type;
            static locale_t c_locale = newlocale(LC_ALL_MASK, "C", nullptr);
            std::string text;
            const bool negative = bits >> 63;
            const bool capitals = type >= 'A' && type <= 'Z';
            if (!std::isfinite(value)) {
                if (std::isinf(value)) text = "inf";
                else if (!(bits & (UINT64_C(1) << 51))) text = "nan(snan)";
                else if (bits == UINT64_C(0xfff8000000000000)) text = "nan(ind)";
                else text = "nan";
                if (capitals) for (char &ch : text) if (ch >= 'a' && ch <= 'z') ch -= 'a' - 'A';
            } else if (type == 'a' || type == 'A') {
                text = hex_float(bits, (char)type, precision, alternate, options);
            } else {
                const int n = snprintf_l(nullptr, 0, c_locale, spec.c_str(), value);
                if (n < 0) return false;
                std::vector<char> buffer((size_t)n + 1);
                snprintf_l(buffer.data(), buffer.size(), c_locale, spec.c_str(), value);
                text.assign(buffer.data(), n);
                if (!(options & STANDARD_ROUNDING) && value != 0) {
                    int64_t places = precision < 0 ? 6 : precision;
                    if (type != 'f' && type != 'F') {
                        char scientific[64];
                        snprintf_l(scientific, sizeof(scientific), c_locale, "%.17e", value);
                        const int magnitude = atoi(strchr(scientific, 'e') + 1);
                        if (type == 'g' || type == 'G') places = std::max<int64_t>(1, places) - 1;
                        places -= magnitude;
                    }
                    if (legacy_rounds_down(bits, places)) {
                        size_t end = text.find_first_of("eE");
                        if (end == std::string::npos) end = text.size();
                        while (end && (text[end - 1] < '0' || text[end - 1] > '9')) --end;
                        if (end) ++text[end - 1];
                    }
                }
            }
            if ((type == 'g' || type == 'G') && !alternate) {
                const size_t point = text.find('.');
                if (point != std::string::npos) {
                    size_t end = text.find_first_of("eE", point);
                    if (end == std::string::npos) end = text.size();
                    size_t keep = end;
                    while (keep > point + 1 && text[keep - 1] == '0') --keep;
                    if (keep == point + 1) --keep;
                    text.erase(keep, end - keep);
                }
            }
            if (!std::isfinite(value) || type == 'a' || type == 'A') {
                if (negative) text.insert(0, 1, '-');
                else if (plus) text.insert(0, 1, '+');
                else if (space) text.insert(0, 1, ' ');
            }
            if ((options & LEGACY_EXPONENT) && type != 'a' && type != 'A') {
                const size_t e = text.find_last_of("eE");
                if (e != std::string::npos && text.size() - e == 4) text.insert(e + 2, 1, '0');
            }
            for (char ch : text) piece += (Ch)ch;
            if (!piece.empty() && (piece[0] == '-' || piece[0] == '+' || piece[0] == ' ')) prefix = 1;
            if (piece.size() >= prefix + 2 && piece[prefix] == '0' && (piece[prefix + 1] == 'x' || piece[prefix + 1] == 'X')) prefix += 2;
            if (!std::isfinite(value)) zero = false;
        } else return false; // Includes %n, disabled by default in UCRT.
        if ((size_t)width > piece.size()) {
            const size_t padding = width - piece.size();
            if (left) piece.append(padding, ' ');
            else piece.insert(numeric && zero ? prefix : 0, padding, numeric && zero ? '0' : ' ');
        }
        if (piece.size() > INT_MAX - out.size()) return false;
        out += piece;
    }
    return true;
}

template <class Ch> static uint64_t print(WinCall *c, bool secure) {
    Ch *buffer = P(1);
    const uint64_t capacity = A(2), options = A(0);
    const bool standard = (options & STANDARD_SNPRINTF) && !(options & LEGACY_TERMINATION);
    if (!P(3) || (!buffer && capacity) || (secure && (!buffer || !capacity))) {
        if (buffer && capacity) buffer[0] = 0;
        return UINT32_MAX;
    }
    if (A(4)) rt_fatal("printf explicit CRT locales are unsupported");
    if (options & ~UINT64_C(55)) rt_fatal("unsupported printf options %#llx", (unsigned long long)options);
    std::basic_string<Ch> text;
    fenv_t saved;
    fegetenv(&saved);
    fesetenv(FE_DFL_ENV);
    const int rounding[] = {FE_TONEAREST, FE_DOWNWARD, FE_UPWARD, FE_TOWARDZERO};
    if (options & STANDARD_ROUNDING) fesetround(rounding[(c->cpu->mxcsr >> 13) & 3]);
    const bool success = format(text, static_cast<const Ch *>(P(3)), P(5), options);
    fesetenv(&saved);
    if (!success) {
        if (buffer && capacity) buffer[0] = 0;
        return UINT32_MAX;
    }
    if (!buffer) return text.size();
    size_t count = std::min<uint64_t>(text.size(), capacity);
    if (standard && capacity) count = std::min<uint64_t>(count, capacity - 1);
    if (count) memcpy(buffer, text.data(), count * sizeof(Ch));
    if (count < capacity) buffer[count] = 0;
    if (standard) return text.size();
    if (text.size() >= capacity) {
        if (options & LEGACY_TERMINATION && text.size() == capacity) return text.size();
        if (!(options & LEGACY_TERMINATION) && capacity) buffer[capacity - 1] = 0;
        if (secure) { buffer[0] = 0; return UINT32_MAX; }
        if (!(options & LEGACY_TERMINATION) && capacity) return (uint32_t)-2;
        return UINT32_MAX;
    }
    return text.size();
}

H(__stdio_common_vsprintf) { return print<char>(c, false); }
H(__stdio_common_vswprintf_s) { return print<char16_t>(c, true); }

const RtEntry rt_stdio_entries[] = {
    {"__stdio_common_vsprintf", __stdio_common_vsprintf},
    {"__stdio_common_vswprintf_s", __stdio_common_vswprintf_s}, {nullptr, nullptr},
};
