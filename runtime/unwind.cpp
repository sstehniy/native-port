#include "crash.h"
#include <algorithm>
#include <mach/mach.h>
#include <mach/mach_vm.h>

bool rt_read_guest(uint64_t address, void *out, size_t size) {
    if (!size) return true;
    if (!address || size > UINT64_MAX - address) return false;
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)out, &got) == KERN_SUCCESS && got == size;
}

extern uint64_t rt_crash_base, rt_crash_size;
static bool image_read(uint64_t address, void *out, size_t size) {
    return address >= rt_crash_base && address - rt_crash_base <= rt_crash_size &&
           size <= rt_crash_size - (address - rt_crash_base) && rt_read_guest(address, out, size);
}
static bool function_at(uint64_t at, RtFunction &fn) {
    return image_read(at, &fn, sizeof(fn)) && fn.begin < fn.end && fn.end <= rt_crash_size && fn.unwind < rt_crash_size;
}

uint64_t rt_lookup_function(uint64_t pc) {
    if (pc < rt_crash_base || pc - rt_crash_base >= rt_crash_size) return 0;
    uint32_t nt, directory[2];
    if (!image_read(rt_crash_base + 0x3c, &nt, 4) ||
        !image_read(rt_crash_base + nt + 24 + 112 + 3 * 8, directory, 8)) return 0;
    const uint64_t table = rt_crash_base + directory[0], offset = pc - rt_crash_base;
    if (directory[1] % 12 || directory[0] > rt_crash_size || directory[1] > rt_crash_size - directory[0]) return 0;
    size_t low = 0, high = directory[1] / 12;
    while (low < high) {
        const size_t mid = low + (high - low) / 2;
        RtFunction fn;
        if (!function_at(table + mid * 12, fn)) return 0;
        if (offset < fn.begin) high = mid;
        else if (offset >= fn.end) low = mid + 1;
        else return table + mid * 12;
    }
    return 0;
}

static bool pop(RtContext &c, uint64_t &value) {
    if (c.r[RSP] > UINT64_MAX - 8 || !rt_read_guest(c.r[RSP], &value, 8)) return false;
    c.r[RSP] += 8;
    return true;
}

/* Epilogues have a restricted grammar; inspect a copy before committing any stack changes. */
static bool epilog(RtContext &context, const RtFunction &fn, uint64_t *pointers) {
    std::array<uint64_t, 32> saved = {};
    RtContext c = context;
    uint64_t pc = c.rip;
    bool first = true;
    for (unsigned n = 0; n < 32 && pc - rt_crash_base < fn.end; ++n) {
        uint8_t code[15] = {};
        const size_t available = std::min<uint64_t>(sizeof(code), rt_crash_base + fn.end - pc);
        if (!image_read(pc, code, available)) return false;
        size_t length = 0;
        if (first && code[0] == 0x48 && code[1] == 0x83 && code[2] == 0xc4 && available >= 4) {
            c.r[RSP] += (int8_t)code[3]; length = 4;
        } else if (first && code[0] == 0x48 && code[1] == 0x81 && code[2] == 0xc4 && available >= 7) {
            uint32_t size; memcpy(&size, code + 3, 4); c.r[RSP] += (int32_t)size; length = 7;
        } else if (first && (code[0] & 0xfe) == 0x48 && code[1] == 0x8d && ((code[2] >> 3) & 7) == RSP) {
            const unsigned mod = code[2] >> 6, base = (code[2] & 7) + ((code[0] & 1) ? 8 : 0);
            if (available < 4 || (base & 7) == RSP || (mod != 1 && mod != 2)) return false;
            int32_t displacement;
            if (mod == 1) { displacement = (int8_t)code[3]; length = 4; }
            else { if (available < 7) return false; memcpy(&displacement, code + 3, 4); length = 7; }
            c.r[RSP] = c.r[base] + (int64_t)displacement;
        } else {
            unsigned at = 0, extra = 0;
            if (code[0] == 0x41) { at = 1; extra = 8; }
            if ((code[at] & 0xf8) == 0x58) {
                uint64_t value;
                saved[16 + (code[at] & 7) + extra] = c.r[RSP];
                if (!pop(c, value)) return false;
                c.r[(code[at] & 7) + extra] = value;
                length = at + 1;
            } else {
                if (code[0] == 0xf3) at = 1;
                bool finish = code[at] == 0xc3 || code[at] == 0xc2;
                if (code[0] == 0xe9 || code[0] == 0xeb) {
                    int32_t displacement = (int8_t)code[1];
                    const unsigned size = code[0] == 0xe9 ? 5 : 2;
                    if (available < size) return false;
                    if (size == 5) memcpy(&displacement, code + 1, 4);
                    const uint64_t target = pc + size + (int64_t)displacement;
                    finish = target < rt_crash_base + fn.begin || target >= rt_crash_base + fn.end;
                }
                if (code[0] == 0xff && (code[1] & 0x38) == 0x20 && (code[1] >> 6) == 0) finish = true;
                if ((code[0] & 0xf8) == 0x48 && code[1] == 0xff && (code[2] & 0xf8) == 0xe0) finish = true;
                if (!finish || !pop(c, c.rip)) return false;
                if (code[at] == 0xc2) { if (available < at + 3) return false; uint16_t bytes; memcpy(&bytes, code + at + 1, 2); c.r[RSP] += bytes; }
                c.rip = bbcpu_unwind_return(c.rip);
                context = c;
                memcpy(pointers, saved.data(), sizeof(saved));
                return true;
            }
        }
        first = false;
        pc += length;
    }
    return false;
}

static unsigned code_slots(unsigned op, unsigned info) {
    if (op == 1) {
        if (info == 0) return 2;
        if (info == 1) return 3;
        return 0;
    }
    if (op == 4 || op == 8) return 2;
    if (op == 5 || op == 9) return 3;
    if (op == 0 || op == 2 || op == 3 || op == 10) return 1;
    return 0;
}

bool rt_unwind(RtContext &context, uint64_t function, uint32_t type, uint64_t *handler,
               uint64_t *data, uint64_t *frame, uint64_t *pointers) {
    RtContext c = context;
    uint64_t h = 0, d = 0, establisher = c.r[RSP];
    std::array<uint64_t, 32> saved = {};
    if (!function) {
        if (!pop(c, c.rip)) return false;
    } else {
        RtFunction fn;
        if (!function_at(function, fn) || c.rip < rt_crash_base + fn.begin || c.rip >= rt_crash_base + fn.end) return false;
        uint8_t head[4];
        if (!image_read(rt_crash_base + fn.unwind, head, 4)) return false;
        const bool in_prolog = c.rip - rt_crash_base - fn.begin < head[1];
        if (!in_prolog && epilog(c, fn, saved.data())) {
            context = c;
            if (handler) *handler = 0;
            if (data) *data = 0;
            if (frame) *frame = establisher;
            if (pointers) memcpy(pointers, saved.data(), sizeof(saved));
            return true;
        }
        const uint64_t prolog_offset = c.rip - rt_crash_base - fn.begin;
        bool machine_frame = false;
        for (unsigned chain = 0;; ++chain) {
            if (chain == 32 || !image_read(rt_crash_base + fn.unwind, head, 4) || (head[0] & 7) != 1) return false;
            const uint8_t flags = head[0] >> 3, count = head[2], fp = head[3] & 15;
            uint16_t codes[256];
            if (!image_read(rt_crash_base + fn.unwind + 4, codes, count * 2)) return false;
            bool frame_established = !in_prolog || chain != 0;
            if (!frame_established) {
                for (unsigned i = 0; i < count;) {
                    const unsigned op = (codes[i] >> 8) & 15;
                    const unsigned slots = code_slots(op, codes[i] >> 12);
                    if (!slots || slots > count - i) return false;
                    if (op == 3 && (codes[i] & 255) <= prolog_offset) frame_established = true;
                    i += slots;
                }
            }
            uint64_t stack_base = c.r[RSP];
            if (fp && frame_established) stack_base = c.r[fp] - (head[3] >> 4) * 16;
            if (!chain) establisher = stack_base;
            for (unsigned i = 0; i < count;) {
                const unsigned offset = codes[i] & 255, op = (codes[i] >> 8) & 15, reg = codes[i] >> 12;
                const unsigned slots = code_slots(op, reg);
                if (!slots || slots > count - i) return false;
                uint64_t value = 0;
                if (slots >= 2) value = codes[i + 1];
                if (slots == 3) value |= (uint32_t)codes[i + 2] << 16;
                if (chain || !in_prolog || offset <= prolog_offset) {
                    if (op == 0) {
                        saved[16 + reg] = c.r[RSP];
                        if (!pop(c, c.r[reg])) return false;
                    } else if (op == 1) c.r[RSP] += reg ? value : value * 8;
                    else if (op == 2) c.r[RSP] += reg * 8 + 8;
                    else if (op == 3) { if (!fp) return false; c.r[RSP] = c.r[fp] - (head[3] >> 4) * 16; }
                    else if (op == 4 || op == 5) {
                        const uint64_t address = stack_base + value * (op == 4 ? 8 : 1);
                        if (!rt_read_guest(address, &c.r[reg], 8)) return false;
                        saved[16 + reg] = address;
                    } else if (op == 8 || op == 9) {
                        const uint64_t address = stack_base + value * (op == 8 ? 16 : 1);
                        if (!rt_read_guest(address, c.floating + 160 + reg * 16, 16)) return false;
                        saved[reg] = address;
                    } else if (op == 10) {
                        if (reg > 1) return false;
                        const uint64_t address = c.r[RSP] + reg * 8;
                        uint64_t values[5];
                        if (!rt_read_guest(address, values, sizeof(values))) return false;
                        c.rip = values[0]; c.cs = (uint16_t)values[1]; c.eflags = (uint32_t)values[2];
                        c.r[RSP] = values[3]; c.ss = (uint16_t)values[4];
                        machine_frame = true;
                    }
                }
                i += slots;
            }
            const uint64_t trailer = rt_crash_base + fn.unwind + 4 + ((count + 1) & ~1u) * 2;
            if (flags & 4) {
                if ((flags & 3) || !function_at(trailer, fn)) return false;
                continue;
            }
            if (!in_prolog && (flags & type & 3)) {
                uint32_t rva;
                if (!image_read(trailer, &rva, 4) || rva >= rt_crash_size) return false;
                h = rt_crash_base + rva;
                d = trailer + 4;
            }
            break;
        }
        if (!machine_frame && !pop(c, c.rip)) return false;
    }
    c.rip = bbcpu_unwind_return(c.rip);
    context = c;
    if (handler) *handler = h;
    if (data) *data = d;
    if (frame) *frame = establisher;
    if (pointers) memcpy(pointers, saved.data(), sizeof(saved));
    return true;
}
