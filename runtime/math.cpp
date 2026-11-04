#include "runtime.h"
#include "math_image.h"
#include "recomp/rc.h"
extern "C" {
#include "cpu/trace.h"
}
#include <array>
#include <atomic>
#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <sys/mman.h>
#include <unordered_map>

static uint64_t image_base;
static const SsMathImage *image;
static std::unordered_map<uint64_t, RcFn> functions;
static std::atomic<uint64_t> matherr_callback;
static thread_local int math_errno;
static std::atomic<uint64_t> total_calls, total_steps;
/* E7 host math counters (below), by import index. */
static const char *const math_names[] = {"asinf", "atan2f", "cos", "cosf", "exp", "expf", "fmodf", "frexp",
                                         "log", "log10", "log10f", "pow", "powf", "sinf", "sqrtf", "tanf"};
static std::atomic<uint64_t> host_calls[16], check_calls[16], check_differ[16], check_max_ulps[16];

static void execute(BbCpu *cpu, uint64_t stop, bool generated);
static uint64_t step(BbCpu *cpu) {
    total_steps.fetch_add(1, std::memory_order_relaxed);
    return cpu->rip = bbcpu_step_insn(cpu, &bbcpu_block(cpu->rip)->insn[0]);
}
static void call(BbCpu *cpu, uint64_t target, uint64_t next) {
    cpu->r[RSP] -= 8;
    bb_store(cpu->r[RSP], 8, next);
    cpu->rip = target;
    execute(cpu, next, true);
}
static void tail(BbCpu *cpu) { execute(cpu, bb_load(cpu->r[RSP], 8), true); }
static void bail(BbCpu *cpu, uint64_t entry_rsp) {
    // Cold fragments share their caller's frame; entering them as new compiled functions loses it.
    execute(cpu, bb_load(entry_rsp, 8), false);
}

static bool crt_hook(BbCpu *cpu) {
    switch (cpu->rip - image_base) {
    case 0x12ac0: cpu->r[RAX] = (uintptr_t)&math_errno; break;
    case 0x1435c: cpu->r[RAX] = 0; break; // The runtime has one isolated CRT app context.
    case 0x25b50: cpu->r[RAX] = matherr_callback.load() != 0; break;
    case 0x9fabc: {
        const uint64_t callback = matherr_callback.load();
        cpu->r[RAX] = 0;
        if (callback) {
            const uint64_t args[] = {cpu->r[RCX]};
            cpu->r[RAX] = bbcpu_call_win64(callback, 1, args);
        }
        break;
    }
    case 0xb35d0:
        if (cpu->r[RCX] != bb_load(image_base + 0x137480, 8)) rt_fatal("UCRT math stack cookie mismatch");
        break;
    case 0xed5c0:
        memset((void *)(uintptr_t)cpu->r[RCX], (int)cpu->r[RDX], cpu->r[R8]);
        cpu->r[RAX] = cpu->r[RCX];
        break;
    default: return false;
    }
    cpu->rip = bb_load(cpu->r[RSP], 8);
    cpu->r[RSP] += 8;
    return true;
}

static void execute(BbCpu *cpu, uint64_t stop, bool generated) {
    while (cpu->rip != stop) {
        if (crt_hook(cpu)) continue;
        const uint64_t offset = cpu->rip - image_base;
        if (offset < image->text_offset || offset - image->text_offset >= image->text_size)
            rt_fatal("UCRT math left its numerical closure at %#llx", (unsigned long long)offset);
        const auto found = functions.find(offset);
        if (generated && found != functions.end()) found->second(cpu);
        else step(cpu);
    }
}

void rt_math_report() {
    bbcpu_recomp_flush_profile(); /* exit paths: also write an E6 PGO profile, if instrumented */
    uint64_t host = 0;
    for (auto &count : host_calls) host += count.load();
    if (host) fprintf(stderr, "host math: %llu calls\n", (unsigned long long)host);
    for (unsigned i = 0; i < 16; ++i)
        if (check_calls[i].load())
            fprintf(stderr, "host math check: %s %llu calls, %llu differ, max %llu ulps\n", math_names[i],
                    (unsigned long long)check_calls[i].load(), (unsigned long long)check_differ[i].load(),
                    (unsigned long long)check_max_ulps[i].load());
    if (!image) return;
    fprintf(stderr, "UCRT math: %llu calls, %llu interpreter instructions\n",
            (unsigned long long)total_calls.load(), (unsigned long long)total_steps.load());
}

static void init_math() {
    const char *path = std::getenv("SS_MATH_LIB");
    void *library = dlopen(path ? path : "build/recomp/math/ucrt.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!library) rt_fatal("UCRT math: %s; run runtime/build.sh", dlerror());
    image = (const SsMathImage *)dlsym(library, "ss_math_image");
    const auto init = (RcInit)dlsym(library, BB_RECOMP_INIT);
    if (!image || !init || !image->size || image->size > 64 * 1024 * 1024 ||
        image->text_offset > image->size || image->text_size > image->size - image->text_offset)
        rt_fatal("invalid local UCRT math library");
    auto *memory = (uint8_t *)runtime_low_map(image->size, PROT_READ | PROT_WRITE);
    if (!memory) rt_fatal("cannot map UCRT math data");
    image_base = (uintptr_t)memory;
    memcpy(memory, image->bytes, image->size);
    for (size_t i = 0; i < image->reloc_count; ++i) {
        const uint32_t offset = image->relocs[i];
        if (offset > image->size || image->size - offset < 8) rt_fatal("invalid UCRT math relocation");
        bb_store(image_base + offset, 8, bb_load(image_base + offset, 8) + image_base - UINT64_C(0x180000000));
    }
    bbcpu_add_guest_code(image_base + image->text_offset, image->text_size);
    std::atexit(rt_math_report);
    static RcApi api = {BB_RECOMP_API_VERSION, image_base, step, call, tail, bail, nullptr};
    size_t count;
    const RcFunction *table = init(&api, &count);
    const char *no_direct = std::getenv("BB_RECOMP_NODIRECT");
    for (size_t i = 0; i < count; ++i) {
        functions.emplace(table[i].offset, table[i].fn);
        if (table[i].direct && (!no_direct || no_direct[0] != '1')) *table[i].direct = table[i].fn;
    }
}

void rt_math_init() {
    static std::once_flag once;
    std::call_once(once, init_math);
}

/* Host CRT math: the game's CRT math imports run as host libm calls instead of
 * the recompiled Microsoft UCRT (which needs a context copy and a private guest stack per
 * call). Only ordinary cases: finite, non-denormal arguments, round-to-nearest MXCSR without
 * DAZ and a finite, normal, nonzero result (frexp: a finite nonzero argument). Everything that could set errno or call
 * the user matherr handler (domain, pole, overflow, underflow) and every zero result keep the
 * UCRT path. Results may differ in the last bits; MXCSR status flags are not modeled.
 * SS_FP_EXACT=1 or SS_HOST_MATH_OFF=all|crt keep UCRT; SS_MATH_CHECK=1 runs both, returns the
 * UCRT result and reports per-function differing results and maximum ulps at exit. */
static int host_math_mode() {
    static const int mode = [] {
        const char *exact = std::getenv("SS_FP_EXACT"), *off = std::getenv("SS_HOST_MATH_OFF");
        const char *check = std::getenv("SS_MATH_CHECK");
        if ((exact && exact[0] == '1') || (off && (!strcmp(off, "all") || strstr(off, "crt")))) return 0;
        return check && check[0] == '1' ? 2 : 1;
    }();
    return mode;
}

static bool ordinary_float(float x) { return std::isnormal(x); }
static bool ordinary_double(double x) { return std::isnormal(x); }

/* The host result in *out (low lane bits), or false for the UCRT path. */
static bool host_result(const BbCpu *cpu, unsigned index, BbVec *out, int *exponent) {
    /* Not under DAZ or another rounding mode; denormal arguments, which UCRT may read as zero
     * under DAZ or treat specially, also keep the UCRT path. */
    if (cpu->mxcsr & 0x6040) return false;
    const float f = cpu->v[0].f[0], g = cpu->v[1].f[0];
    const double d = cpu->v[0].fd[0], e = cpu->v[1].fd[0];
    const bool dbl = index == 2 || index == 4 || index == 7 || index == 8 || index == 9 || index == 11;
    const bool binary = index == 1 || index == 6 || index == 11 || index == 12;
    if (dbl ? (std::fpclassify(d) == FP_SUBNORMAL || (binary && std::fpclassify(e) == FP_SUBNORMAL))
            : (std::fpclassify(f) == FP_SUBNORMAL || (binary && std::fpclassify(g) == FP_SUBNORMAL)))
        return false;
    *out = cpu->v[0];
    float rf = 0;
    double rd = 0;
    bool single = true;
    switch (index) {
    case 0: if (!std::isfinite(f)) return false; rf = asinf(f); break;
    case 1: if (!std::isfinite(f) || !std::isfinite(g)) return false; rf = atan2f(f, g); break;
    case 2: if (!std::isfinite(d)) return false; rd = cos(d); single = false; break;
    case 3: if (!std::isfinite(f)) return false; rf = cosf(f); break;
    case 4: if (!std::isfinite(d)) return false; rd = exp(d); single = false; break;
    case 5: if (!std::isfinite(f)) return false; rf = expf(f); break;
    case 6: if (!std::isfinite(f) || !std::isfinite(g)) return false; rf = fmodf(f, g); break;
    case 7:
        if (!std::isfinite(d) || d == 0) return false;
        out->fd[0] = frexp(d, exponent);
        return true;
    case 8: if (!std::isfinite(d)) return false; rd = log(d); single = false; break;
    case 9: if (!std::isfinite(d)) return false; rd = log10(d); single = false; break;
    case 10: if (!std::isfinite(f)) return false; rf = log10f(f); break;
    case 11: if (!std::isfinite(d) || !std::isfinite(e)) return false; rd = pow(d, e); single = false; break;
    case 12: if (!std::isfinite(f) || !std::isfinite(g)) return false; rf = powf(f, g); break;
    case 13: if (!std::isfinite(f)) return false; rf = sinf(f); break;
    case 14: if (!std::isfinite(f)) return false; rf = sqrtf(f); break;
    case 15: if (!std::isfinite(f)) return false; rf = tanf(f); break;
    default: return false;
    }
    if (single ? !ordinary_float(rf) : !ordinary_double(rd)) return false;
    if (single) out->f[0] = rf; else out->fd[0] = rd;
    return true;
}

static uint64_t ulps(uint64_t a, uint64_t b, int width) {
    const uint64_t sign = UINT64_C(1) << (width - 1);
    const auto order = [&](uint64_t x) { return x & sign ? (int64_t)(sign - 1) - (int64_t)(x & ~sign) - (int64_t)sign + 1 : (int64_t)x; };
    const int64_t x = order(a), y = order(b);
    return (uint64_t)(x > y ? x - y : y - x);
}

static uint64_t math_ucrt(WinCall *c, unsigned index);

static uint64_t math_call(WinCall *c, unsigned index) {
    const int mode = host_math_mode();
    if (mode) {
        BbVec result;
        int exponent = 0;
        if (host_result(c->cpu, index, &result, &exponent)) {
            if (mode == 1) {
                host_calls[index].fetch_add(1, std::memory_order_relaxed);
                if (index == 7) bb_store(c->cpu->r[RDX], 4, (uint32_t)exponent);
                c->cpu->v[0] = result;
                return 0;
            }
            const uint64_t answer = math_ucrt(c, index);
            const bool dbl = index == 2 || index == 4 || index == 7 || index == 8 || index == 9 || index == 11;
            const uint64_t host = dbl ? result.q[0] : result.d[0], ucrt = dbl ? c->cpu->v[0].q[0] : c->cpu->v[0].d[0];
            check_calls[index].fetch_add(1, std::memory_order_relaxed);
            bool differ = host != ucrt;
            if (index == 7) differ |= (uint32_t)exponent != (uint32_t)bb_load(c->cpu->r[RDX], 4);
            if (differ) {
                check_differ[index].fetch_add(1, std::memory_order_relaxed);
                const uint64_t distance = ulps(host, ucrt, dbl ? 64 : 32);
                uint64_t seen = check_max_ulps[index].load();
                while (distance > seen && !check_max_ulps[index].compare_exchange_weak(seen, distance)) {}
            }
            return answer;
        }
    }
    return math_ucrt(c, index);
}

static uint64_t math_ucrt(WinCall *c, unsigned index) {
    rt_math_init();
    if ((c->cpu->mxcsr & 0x1f80) != 0x1f80) rt_fatal("unmasked UCRT floating-point exceptions are unsupported");
    alignas(16) std::array<uint8_t, 65536> stack;
    BbCpu cpu = *c->cpu;
    cpu.r[RSP] = (uintptr_t)(stack.data() + stack.size()) - 40;
    constexpr uint64_t stop = 1;
    bb_store(cpu.r[RSP], 8, stop);
    cpu.rip = image_base + image->exports[index];
    total_calls.fetch_add(1, std::memory_order_relaxed);
    execute(&cpu, stop, true);
    c->cpu->v[0] = cpu.v[0];
    c->cpu->mxcsr = cpu.mxcsr;
    return 0;
}

#define MATH(name, index) H(math_##name) { return math_call(c, index); }
MATH(asinf, 0) MATH(atan2f, 1) MATH(cos, 2) MATH(cosf, 3) MATH(exp, 4) MATH(expf, 5)
MATH(fmodf, 6) MATH(frexp, 7) MATH(log, 8) MATH(log10, 9) MATH(log10f, 10) MATH(pow, 11)
MATH(powf, 12) MATH(sinf, 13) MATH(sqrtf, 14) MATH(tanf, 15)
H(get_errno) { return (uintptr_t)&math_errno; }
H(set_matherr) { matherr_callback.store(A(0)); return 0; }

const RtEntry rt_math_entries[] = {
    {"asinf", math_asinf}, {"atan2f", math_atan2f}, {"cos", math_cos}, {"cosf", math_cosf},
    {"exp", math_exp}, {"expf", math_expf}, {"fmodf", math_fmodf}, {"frexp", math_frexp},
    {"log", math_log}, {"log10", math_log10}, {"log10f", math_log10f}, {"pow", math_pow},
    {"powf", math_powf}, {"sinf", math_sinf}, {"sqrtf", math_sqrtf}, {"tanf", math_tanf},
    {"_errno", get_errno}, {"__setusermatherr", set_matherr}, {nullptr, nullptr}
};
