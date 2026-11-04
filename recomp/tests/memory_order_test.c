/* R1.05: x86-TSO litmus tests and a locked-instruction stress test on real host threads
 * (tools/recomp_memory_order.py). Usage: memory-order-test fixture.elf functions iterations
 * rounds stress_iterations. Prints one JSON line; exits non-zero on a forbidden outcome. */
#include "../src/cpu/cpu_internal.h"
#include "memory_order_offsets.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>

uint64_t bb_image_base;
/* The CPU logs to stdout; the JSON is printed whole at the end. */
static FILE *json;
void *runtime_low_map(size_t size, int prot) {
    void *p = mmap(NULL, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

typedef struct { unsigned char ident[16]; uint16_t type, machine; uint32_t version;
    uint64_t entry, phoff, shoff; uint32_t flags; uint16_t ehsize, phentsize, phnum,
    shentsize, shnum, shstrndx; } ElfHeader;
typedef struct { uint32_t type, flags; uint64_t offset, vaddr, paddr, filesz, memsz, align; } ElfSegment;

static void load_fixture(const char *path) {
    FILE *f = fopen(path, "rb");
    assert(f && fseek(f, 0, SEEK_END) == 0);
    const long size = ftell(f);
    assert(size >= (long)sizeof(ElfHeader) && fseek(f, 0, SEEK_SET) == 0);
    uint8_t *data = malloc((size_t)size);
    assert(data && fread(data, 1, (size_t)size, f) == (size_t)size);
    fclose(f);
    const ElfHeader *header = (const ElfHeader *)data;
    assert(memcmp(header->ident, "\177ELF\2\1\1", 7) == 0 && header->machine == 62);
    const ElfSegment *p = (const ElfSegment *)(data + header->phoff);
    assert(header->phnum == 1 && p->type == 1 && p->offset + p->filesz <= (uint64_t)size);
    uint8_t *image = runtime_low_map((size_t)(p->vaddr + p->memsz), PROT_READ | PROT_WRITE);
    assert(image);
    bb_image_base = (uint64_t)(uintptr_t)image;
    memcpy(image + p->vaddr, data + p->offset, (size_t)p->filesz);
    bbcpu_add_guest_code((uintptr_t)image + p->vaddr, (size_t)p->memsz);
    free(data);
}

enum { SB, MP, LB, W22, IRIW };
enum { X = 0, Y = 64 };
typedef struct {
    const char *name;
    int kind, control; /* control: the "forbidden" outcome is allowed (no fence) */
    uint64_t fn[4];
} Test;

static const Test tests[] = {
    {"sb_none", SB, 1, {GUEST_SB_NONE, GUEST_SB_NONE}},
    {"sb_mfence", SB, 0, {GUEST_SB_MFENCE, GUEST_SB_MFENCE}},
    {"sb_lock_add", SB, 0, {GUEST_SB_LOCK_ADD, GUEST_SB_LOCK_ADD}},
    {"sb_lock_or", SB, 0, {GUEST_SB_LOCK_OR, GUEST_SB_LOCK_OR}},
    {"sb_lock_inc", SB, 0, {GUEST_SB_LOCK_INC, GUEST_SB_LOCK_INC}},
    {"sb_lock_xadd", SB, 0, {GUEST_SB_LOCK_XADD, GUEST_SB_LOCK_XADD}},
    {"sb_xchg", SB, 0, {GUEST_SB_XCHG, GUEST_SB_XCHG}},
    {"sb_cas_fail", SB, 0, {GUEST_SB_CAS_FAIL, GUEST_SB_CAS_FAIL}},
    {"sb_cas_ok", SB, 0, {GUEST_SB_CAS_OK, GUEST_SB_CAS_OK}},
    {"sb_cas64_fail", SB, 0, {GUEST_SB_CAS64_FAIL, GUEST_SB_CAS64_FAIL}},
    {"rmw_xadd", SB, 0, {GUEST_RMW_XADD, GUEST_RMW_XADD}},
    {"rmw_xchg", SB, 0, {GUEST_RMW_XCHG, GUEST_RMW_XCHG}},
    {"rmw_cas", SB, 0, {GUEST_RMW_CAS, GUEST_RMW_CAS}},
    {"vsb_none", SB, 1, {GUEST_VSB_NONE, GUEST_VSB_NONE}},
    {"vsb_mfence", SB, 0, {GUEST_VSB_MFENCE, GUEST_VSB_MFENCE}},
    {"vsb_lock_add", SB, 0, {GUEST_VSB_LOCK_ADD, GUEST_VSB_LOCK_ADD}},
    {"vsb_lock_xadd", SB, 0, {GUEST_VSB_LOCK_XADD, GUEST_VSB_LOCK_XADD}},
    {"vsb_xchg", SB, 0, {GUEST_VSB_XCHG, GUEST_VSB_XCHG}},
    {"vsb_cas_fail", SB, 0, {GUEST_VSB_CAS_FAIL, GUEST_VSB_CAS_FAIL}},
    {"usb_lock_add", SB, 0, {GUEST_USB_LOCK_ADD, GUEST_USB_LOCK_ADD}},
    {"usb_cas_fail", SB, 0, {GUEST_USB_CAS_FAIL, GUEST_USB_CAS_FAIL}},
    {"mp", MP, 0, {GUEST_MP_WRITER, GUEST_MP_READER}},
    {"mp_vector", MP, 0, {GUEST_MPV_WRITER, GUEST_MPV_READER}},
    {"lb", LB, 0, {GUEST_LB, GUEST_LB}},
    {"2+2w", W22, 0, {GUEST_W22, GUEST_W22}},
    {"iriw", IRIW, 0, {GUEST_IRIW_WRITER, GUEST_IRIW_WRITER, GUEST_MP_READER, GUEST_MP_READER}},
};

typedef struct { uint64_t fn, args[6], result; pthread_t thread; } Worker;

static void *worker_main(void *arg) {
    Worker *w = arg;
    w->result = bbcpu_call_win64(bb_image_base + w->fn, 6, w->args);
    return NULL;
}

static void run_threads(Worker *workers, int count) {
    for (int i = 0; i < count; ++i) assert(pthread_create(&workers[i].thread, NULL, worker_main, &workers[i]) == 0);
    for (int i = 0; i < count; ++i) assert(pthread_join(workers[i].thread, NULL) == 0);
}

/* Outcome key per iteration and whether it is forbidden under x86-TSO. */
static unsigned outcome(const Test *t, const uint32_t *const out[4], const uint8_t *slot, size_t i, int *forbidden) {
    const uint32_t a = out[0][i], b = out[1][i];
    switch (t->kind) {
    case SB: *forbidden = !a && !b; return (a != 0) * 2 + (b != 0);
    case MP: *forbidden = b == 2; return b;
    case LB: *forbidden = a && b; return (a != 0) * 2 + (b != 0);
    case W22: {
        uint32_t x, y;
        memcpy(&x, slot + X, 4);
        memcpy(&y, slot + Y, 4);
        *forbidden = x == 1 && y == 1;
        return x * 3 + y;
    }
    default: { /* IRIW: both readers see their first write but not the second */
        const uint32_t c = out[2][i], d = out[3][i];
        *forbidden = c == 2 && d == 2;
        return c * 4 + d;
    }
    }
}

static int run_test(const Test *t, size_t iterations, int rounds, int first) {
    const int threads = t->kind == IRIW ? 4 : 2;
    /* Offsets (mine, other) per thread; MP/IRIW readers load "other" (r11) first. */
    static const uint64_t two[2][2] = {{X, Y}, {Y, X}}, mp[2][2] = {{X, Y}, {X, Y}};
    static const uint64_t iriw[4][2] = {{X, Y}, {Y, X}, {Y, X}, {X, Y}};
    const uint64_t (*offsets)[2] = two;
    if (t->kind == IRIW) offsets = iriw;
    else if (t->kind == MP) offsets = mp;
    unsigned long long histogram[16] = {0}, forbidden_count = 0;
    uint8_t *slots = NULL;
    uint32_t *out[4];
    assert(posix_memalign((void **)&slots, 256, iterations * 256) == 0);
    for (int i = 0; i < threads; ++i) assert((out[i] = malloc(iterations * 4)));
    for (int round = 0; round < rounds; ++round) {
        memset(slots, 0, iterations * 256);
        Worker workers[4];
        for (int i = 0; i < threads; ++i) {
            workers[i] = (Worker){.fn = t->fn[i], .args = {(uint64_t)(uintptr_t)slots, iterations,
                                  (uint64_t)(uintptr_t)out[i], (uint64_t)threads, offsets[i][0], offsets[i][1]}};
        }
        run_threads(workers, threads);
        for (size_t i = 0; i < iterations; ++i) {
            int forbidden = 0;
            const unsigned key = outcome(t, (const uint32_t *const *)out, slots + i * 256, i, &forbidden);
            assert(key < 16);
            ++histogram[key];
            forbidden_count += (unsigned long long)forbidden;
        }
    }
    fprintf(json, "%s\"%s\":{\"iterations\":%llu,\"%s\":%llu,\"outcomes\":{", first ? "" : ",", t->name,
           (unsigned long long)iterations * (unsigned long long)rounds, t->control ? "relaxed_observed" : "forbidden",
           forbidden_count);
    int comma = 0;
    for (unsigned k = 0; k < 16; ++k) {
        if (!histogram[k]) continue;
        fprintf(json, "%s\"%u\":%llu", comma ? "," : "", k, histogram[k]);
        comma = 1;
    }
    fprintf(json, "}}");
    free(slots);
    for (int i = 0; i < threads; ++i) free(out[i]);
    return !t->control && forbidden_count;
}

static int run_stress(uint64_t iterations) {
    enum { THREADS = 8 };
    uint8_t *shared = NULL;
    assert(posix_memalign((void **)&shared, 256, 1024) == 0);
    memset(shared, 0, 1024);
    Worker workers[THREADS];
    for (int i = 0; i < THREADS; ++i)
        workers[i] = (Worker){.fn = GUEST_STRESS, .args = {(uint64_t)(uintptr_t)shared, iterations, (uint64_t)i}};
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    run_threads(workers, THREADS);
    clock_gettime(CLOCK_MONOTONIC, &end);
    const uint64_t n = iterations * THREADS;
    uint64_t tickets = 0, u64[8];
    uint32_t u32[4];
    for (int i = 0; i < THREADS; ++i) tickets += workers[i].result;
    memcpy(&u32[0], shared + 0, 4);    /* xadd */
    memcpy(&u32[1], shared + 64, 4);   /* inc */
    memcpy(&u32[2], shared + 640, 4);  /* cas32 loop */
    memcpy(&u32[3], shared + 448, 4);  /* add 3 */
    memcpy(&u64[0], shared + 128, 8);  /* cas64 loop */
    memcpy(&u64[1], shared + 256, 8);  /* under the xchg lock */
    memcpy(&u64[2], shared + 272, 8);  /* vector lanes under the xchg lock */
    memcpy(&u64[3], shared + 280, 8);
    memcpy(&u64[4], shared + 585, 8);  /* unaligned, under the cmpxchg lock */
    memcpy(&u64[5], shared + 384, 8);  /* dec */
    uint32_t bits;
    memcpy(&bits, shared + 320, 4);
    const int ok = u32[0] == (uint32_t)n && u32[1] == (uint32_t)n && u32[2] == (uint32_t)n &&
                   u32[3] == (uint32_t)(3 * n) && u64[0] == n && u64[1] == n && u64[2] == n && u64[3] == n &&
                   u64[4] == n && u64[5] == (uint64_t)-(int64_t)n && bits == (1u << THREADS) - 1 &&
                   tickets == n * (n - 1) / 2 && shared[192] == 0 && shared[576] == 0;
    fprintf(json, ",\"stress\":{\"threads\":%d,\"iterations_per_thread\":%llu,\"passed\":%s,\"xadd\":%u,\"inc\":%u,"
           "\"cas32\":%u,\"add3\":%u,\"cas64\":%llu,\"xchg_locked\":%llu,\"vector_locked\":[%llu,%llu],"
           "\"cmpxchg_locked_unaligned\":%llu,\"dec\":%lld,\"or_bits\":%u,\"ticket_sum\":%llu,\"expected_ticket_sum\":%llu,\"seconds\":%.3f}",
           THREADS, (unsigned long long)iterations, ok ? "true" : "false", u32[0], u32[1], u32[2], u32[3],
           (unsigned long long)u64[0], (unsigned long long)u64[1], (unsigned long long)u64[2], (unsigned long long)u64[3],
           (unsigned long long)u64[4], (long long)u64[5], bits, (unsigned long long)tickets,
           (unsigned long long)(n * (n - 1) / 2), (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9);
    free(shared);
    return !ok;
}

int main(int argc, char **argv) {
    assert(argc == 6);
    setenv("BB_JIT", "0", 1);
    load_fixture(argv[1]);
    bbcpu_recomp_load(bb_image_base);
    assert(bbcpu_recomp_functions() == strtoull(argv[2], NULL, 10));
    const size_t iterations = strtoull(argv[3], NULL, 10);
    const int rounds = atoi(argv[4]);
    char *text = NULL;
    size_t length = 0;
    assert((json = open_memstream(&text, &length)));
    int failed = 0, first = 1;
    fprintf(json, "{\"recompiled_functions\":%zu,\"tests\":{", bbcpu_recomp_functions());
    for (size_t i = 0; i < sizeof(tests) / sizeof(*tests); ++i) {
        failed |= run_test(&tests[i], iterations, rounds, first);
        first = 0;
    }
    fprintf(json, "}");
    const uint64_t stress = strtoull(argv[5], NULL, 10);
    if (stress) failed |= run_stress(stress);
    fprintf(json, ",\"passed\":%s}", failed ? "false" : "true");
    fclose(json);
    printf("\n%s\n", text);
    free(text);
    return failed;
}
