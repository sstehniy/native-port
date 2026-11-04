/* PE32+ loader: identity-mapped guest memory, host import thunks, TEB/PEB/TLS and entry dispatch.
 * Recompiled code stays local in build/recomp/. Unimplemented imports stop with a diagnostic. */
#include "runtime.h"
#include "crash.h"
#include <sys/ucontext.h>
#include "cpu/image_reservation.h"

#include <algorithm>
#include <vector>

#include <atomic>
#include <mutex>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define DEFAULT_LIB "build/recomp/librecomp.dylib"

enum { MAX_IMPORTS = 2048, GUEST_STACK_SIZE = 8 << 20 };

uint64_t bb_image_base; /* bbcpu's fault reports */

void *runtime_low_map(size_t size, int prot) {
    /* Keep guest stacks/TEBs clear of host code and allocator reservations during replay. */
    static std::atomic<uintptr_t> next = UINT64_C(0x10000000000);
    const size_t page = (size_t)getpagesize();
    if (!size || size > SIZE_MAX - page + 1) return nullptr;
    size = (size + page - 1) & ~(page - 1);
    const uintptr_t address = next.fetch_add(size, std::memory_order_relaxed);
    void *p = mmap((void *)address, size, prot, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == (void *)address) return p;
    if (p != MAP_FAILED) munmap(p, size);
    fprintf(stderr, "cannot reserve guest memory at %#llx (%zu bytes)\n", (unsigned long long)address, size);
    return nullptr;
}

static FILE *import_log;
static FILE *target_log;
static void on_target(uint64_t target, int kind) {
    if (fprintf(target_log, "%d\t%#llx\n", kind, (unsigned long long)target) < 0)
        rt_fatal("cannot write target log: %s", strerror(errno));
}
static Import imports[MAX_IMPORTS];
static uint32_t import_count;
static std::mutex imports_lock;
static std::atomic<uint64_t> import_calls;

[[noreturn]] void rt_fatal(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputs("STOP: ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    /* SS_STOP_DUMP=address:bytes,... (diagnostics): guest memory at the stop, as hex. */
    for (const char *dump = getenv("SS_STOP_DUMP"); dump && *dump;) {
        char *end;
        const uint64_t address = strtoull(dump, &end, 0);
        const unsigned long bytes = *end == ':' ? strtoul(end + 1, &end, 0) : 0;
        uint8_t data[256];
        mach_vm_size_t got = 0;
        const unsigned long size = bytes < sizeof(data) ? bytes : sizeof(data);
        /* A fault-safe read: rt_fatal also runs before the image is mapped. */
        if (mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)(uintptr_t)data, &got) != KERN_SUCCESS)
            got = 0;
        fprintf(stderr, "DUMP %#llx:", (unsigned long long)address);
        for (mach_vm_size_t i = 0; i < got; ++i) fprintf(stderr, "%02x", data[i]);
        fputs(got == size ? "\n" : " unreadable\n", stderr);
        dump = *end == ',' ? end + 1 : "";
    }
    if (import_log) fflush(import_log);
    fflush(nullptr);
    rt_math_report();
    _exit(2);
}

static uint16_t u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t u64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

/* ---- Win64 argument access for import handlers ---- */

uint64_t rt_arg(const WinCall *call, int index) {
    static const int regs[4] = {RCX, RDX, R8, R9};
    if (index < 4) return call->cpu->r[regs[index]];
    return u64((const uint8_t *)(uintptr_t)(call->stack_args + 8 * (uint64_t)index));
}

static Import *add_import(const char *dll, const char *name) {
    if (import_count == MAX_IMPORTS) rt_fatal("too many imports");
    Import *imp = &imports[import_count++];
    imp->dll = dll;
    imp->name = name;
    imp->handler = rt_find_handler(dll, name);
    return imp;
}

static uint64_t thunk_of(const Import *imp) { return THUNK_BASE + THUNK_STRIDE * (uint64_t)(imp - imports); }

uint64_t rt_dynamic_import(const char *dll, const char *name) {
    std::lock_guard guard(imports_lock);
    for (uint32_t i = 0; i < import_count; ++i)
        if (strcmp(imports[i].dll, "COM") && !strcmp(imports[i].name, name)) return imports[i].handler ? thunk_of(&imports[i]) : 0;
    const ImportHandler handler = rt_find_handler(dll, name);
    if (import_log) fprintf(import_log, "-\tGetProcAddress %s!%s%s\n", dll, name, handler ? "" : " (missing)");
    if (!handler) return 0;
    return thunk_of(add_import(strdup(dll), strdup(name)));
}
uint64_t rt_host_thunk(const char *name, ImportHandler handler) {
    if (!name || !handler) rt_fatal("invalid host method");
    std::lock_guard guard(imports_lock);
    for (uint32_t i = 0; i < import_count; ++i)
        if (!strcmp(imports[i].dll, "COM") && imports[i].handler == handler) return thunk_of(&imports[i]);
    if (import_count == MAX_IMPORTS) rt_fatal("too many imports and host methods");
    Import *imp = &imports[import_count++];
    *imp = {"COM", strdup(name), handler};
    return thunk_of(imp);
}

static void on_thunk(BbCpu *cpu, uint64_t address, uint64_t stack_args) {
    const uint32_t index = (uint32_t)((address - THUNK_BASE) / THUNK_STRIDE);
    Import descriptor;
    {
        std::lock_guard guard(imports_lock);
        if ((address - THUNK_BASE) % THUNK_STRIDE || index >= import_count)
            rt_fatal("call of unknown thunk %#llx", (unsigned long long)address);
        descriptor = imports[index];
    }
    const Import *imp = &descriptor;
    /* A `call` the interpreter handles has not pushed its return address yet (rip is the call). */
    const uint64_t caller = stack_args == cpu->r[RSP] + 8 ? u64((const uint8_t *)(uintptr_t)cpu->r[RSP]) : cpu->rip;
    const uint64_t call_number = import_calls.fetch_add(1, std::memory_order_relaxed) + 1;
    if (import_log) fprintf(import_log, "%llu\t%s!%s\t%#llx\n", (unsigned long long)call_number, imp->dll, imp->name,
            (unsigned long long)caller);
    if (!imp->handler) {
        if (import_log) fflush(import_log);
        rt_fatal("unimplemented import %s!%s (call %llu, from %#llx; rcx=%#llx rdx=%#llx r8=%#llx r9=%#llx)",
                 imp->dll, imp->name, (unsigned long long)call_number, (unsigned long long)caller,
                 (unsigned long long)cpu->r[RCX], (unsigned long long)cpu->r[RDX],
                 (unsigned long long)cpu->r[R8], (unsigned long long)cpu->r[R9]);
    }
    WinCall call = {cpu, stack_args, imp};
    cpu->r[RAX] = imp->handler(&call);
}

/* A host fault: report where the guest was (exact in the interpreter, the function's entry or
 * last call in recompiled code), with its registers. */
void rt_bind_thunks(void) {
    bbcpu_set_host_thunks(THUNK_BASE, THUNK_STRIDE * (uint64_t)MAX_IMPORTS, on_thunk); /* GetProcAddress adds more */
}

static void on_fault(int sig, siginfo_t *info, void *context) {
    uint32_t access = 0;
#if defined(__aarch64__)
    const auto machine = ((ucontext_t *)context)->uc_mcontext;
    const uint32_t esr = machine->__es.__esr;
    const unsigned kind = esr >> 26;
    if (kind == 0x20 || kind == 0x21) access = 8;
    else if (esr & (1u << 6)) access = 1;
#endif
    bbcpu_defer_fault(sig, (uintptr_t)info->si_addr, access);
    rt_crash_signal(sig, (uintptr_t)info->si_addr, bbcpu_thread_cpu());
    _exit(3);
}

/* ---- the image ---- */

struct Image {
    uint64_t base, size, entry;
    uint32_t text_rva = 0, text_size = 0;
    uint32_t import_rva, import_size, tls_rva, reloc_rva, reloc_size;
    uint64_t stack_reserve, stack_commit;

    uint8_t *at(uint64_t rva, uint64_t bytes) const {
        if (rva > size || bytes > size - rva) rt_fatal("PE image range outside image: %#llx + %#llx",
            (unsigned long long)rva, (unsigned long long)bytes);
        return (uint8_t *)(uintptr_t)(base + rva);
    }
    const char *string(uint32_t rva) const {
        const char *s = (const char *)at(rva, 1);
        if (!memchr(s, 0, size - rva)) rt_fatal("unterminated PE import name");
        return s;
    }
};

static void protect_image(const Image *im) {
    const uint64_t nt_rva = u32(im->at(0x3c, 4));
    const uint8_t *nt = im->at(nt_rva, 24);
    if (u16(nt + 20) < 64) rt_fatal("invalid mapped PE optional header");
    const uint8_t *opt = im->at(nt_rva + 24, u16(nt + 20));
    const uint8_t *sections = im->at(nt_rva + 24 + u16(nt + 20), 40 * (uint64_t)u16(nt + 6));
    const size_t page = (size_t)getpagesize();
    std::vector<int> protections((im->size + page - 1) / page, PROT_NONE);
    const auto add = [&](uint32_t rva, uint32_t size, int prot) {
        im->at(rva, size);
        if (!size) return;
        for (size_t i = rva / page; i <= ((uint64_t)rva + size - 1) / page; ++i) protections[i] |= prot;
    };
    add(0, u32(opt + 60), PROT_READ);
    for (int i = 0; i < u16(nt + 6); ++i) {
        const uint8_t *s = sections + 40 * i;
        const uint32_t flags = u32(s + 36);
        int prot = PROT_NONE;
        if (flags & 0xe0000000u) prot = PROT_READ;
        if (flags & 0x80000000u) prot |= PROT_WRITE;
        add(u32(s + 12), std::max(u32(s + 8), u32(s + 16)), prot);
    }
    /* Shared 16 KiB pages need the union of their PE sections; guest x86 code is never host-executable. */
    for (size_t lo = 0, hi; lo < protections.size(); lo = hi) {
        for (hi = lo + 1; hi < protections.size() && protections[hi] == protections[lo]; ++hi) {}
        if (mprotect((void *)(uintptr_t)(im->base + lo * page), (hi - lo) * page, protections[lo]))
            rt_fatal("mprotect: %s", strerror(errno));
    }
}

static void relocate_image(const Image &im, uint64_t preferred) {
    const uint64_t delta = im.base - preferred;
    if (delta && !im.reloc_size) rt_fatal("cannot relocate image: no base relocations");
    for (uint64_t offset = 0; offset < im.reloc_size;) {
        if (im.reloc_size - offset < 8) rt_fatal("truncated PE relocation block");
        const uint8_t *block = im.at((uint64_t)im.reloc_rva + offset, 8);
        const uint32_t page = u32(block), bytes = u32(block + 4);
        if (bytes < 8 || (bytes & 1) || bytes > im.reloc_size - offset)
            rt_fatal("invalid PE relocation block size");
        im.at((uint64_t)im.reloc_rva + offset, bytes);
        for (uint32_t i = 8; i < bytes; i += 2) {
            const uint16_t fixup = u16(block + i);
            const unsigned type = fixup >> 12;
            if (!type) continue; /* IMAGE_REL_BASED_ABSOLUTE padding */
            if (type != 10) rt_fatal("unsupported PE relocation type %u", type);
            uint8_t *slot = im.at((uint64_t)page + (fixup & 0xfff), 8);
            if (delta) rt_put<uint64_t>(slot, u64(slot) + delta); /* IMAGE_REL_BASED_DIR64 */
        }
        offset += bytes;
    }
}

static Image map_image(const char *path) {
    const int fd = open(path, O_RDONLY);
    if (fd < 0) rt_fatal("%s: %s", path, strerror(errno));
    struct stat st;
    if (fstat(fd, &st) || st.st_size < 64) rt_fatal("%s: missing PE headers", path);
    uint8_t *file = static_cast<uint8_t *>(mmap(nullptr, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0));
    close(fd);
    if (file == MAP_FAILED) rt_fatal("%s: %s", path, strerror(errno));
    const auto bytes = [&](uint64_t offset, uint64_t size) {
        if (offset > (uint64_t)st.st_size || size > (uint64_t)st.st_size - offset)
            rt_fatal("%s: truncated PE file (input file mapping %p, size %#llx)", path, file,
                     (unsigned long long)st.st_size);
        return file + offset;
    };
    if (memcmp(file, "MZ", 2)) rt_fatal("%s: not a PE image", path);
    const uint64_t nt_offset = u32(file + 0x3c);
    const uint8_t *nt = bytes(nt_offset, 24);
    if (memcmp(nt, "PE\0\0", 4) || u16(nt + 4) != 0x8664) rt_fatal("%s: not a PE32+ x86-64 image", path);
    const uint32_t section_count = u16(nt + 6), opt_size = u16(nt + 20);
    const uint8_t *opt = bytes(nt_offset + 24, opt_size);
    if (opt_size < 112 || u16(opt) != 0x20b) rt_fatal("%s: not PE32+", path);
    const uint32_t directories = u32(opt + 108);
    if (directories > (opt_size - 112) / 8) rt_fatal("invalid PE directory count");
    const auto directory = [&](unsigned index, unsigned field) -> uint32_t {
        return index < directories ? u32(opt + 112 + index * 8 + field) : 0;
    };
    Image im = {
        .base = u64(opt + 24), .size = u32(opt + 56), .entry = u32(opt + 16),
        .import_rva = directory(1, 0), .import_size = directory(1, 4), .tls_rva = directory(9, 0),
        .reloc_rva = directory(5, 0), .reloc_size = directory(5, 4),
        .stack_reserve = u64(opt + 72), .stack_commit = u64(opt + 80),
    };
    const uint64_t preferred = im.base;
    const uint32_t headers = u32(opt + 60);
    const uint8_t *sections = bytes(nt_offset + 24 + opt_size, 40 * section_count);
    if (!im.size || !im.base || (im.base & 0xffff) || im.size > UINT64_MAX - im.base ||
        !section_count || section_count > 96 || headers > im.size || headers < nt_offset + 24 + opt_size + 40 * section_count)
        rt_fatal("invalid PE image layout");
    bytes(0, headers);
    im.at(im.entry, 1);
    for (int index : {1, 5, 9}) {
        const uint32_t rva = directory(index, 0), size = directory(index, 4);
        if (rva || size) {
            if (!rva || !size) rt_fatal("invalid PE directory range");
            im.at(rva, size);
        }
    }
    if (im.tls_rva && directory(9, 4) < 40) rt_fatal("truncated PE TLS directory");
    for (uint32_t i = 0; i < section_count; ++i) {
        const uint8_t *s = sections + 40 * i;
        im.at(u32(s + 12), std::max(u32(s + 8), u32(s + 16)));
        bytes(u32(s + 20), u32(s + 16));
    }
    const kern_return_t error = bb_reserve_image(im.base, im.size);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "loader: cannot reserve the image at %#llx: %s (input file mapping %p, size %#llx); relocating\n",
                (unsigned long long)im.base, mach_error_string(error), file, (unsigned long long)st.st_size);
        void *fallback = runtime_low_map(im.size, PROT_READ | PROT_WRITE);
        if (!fallback) rt_fatal("cannot allocate relocation fallback");
        im.base = (uint64_t)(uintptr_t)fallback;
    }
    memcpy(im.at(0, headers), file, headers);
    for (uint32_t i = 0; i < section_count; ++i) {
        const uint8_t *s = sections + 40 * i;
        const uint32_t vsize = u32(s + 8), rva = u32(s + 12), raw_size = u32(s + 16), raw = u32(s + 20);
        const uint32_t size = vsize ? vsize : raw_size;
        memcpy(im.at(rva, size), file + raw, std::min(raw_size, size));
        if (!memcmp(s, ".text", 6)) { im.text_rva = rva; im.text_size = size; }
    }
    if (!im.text_size || im.entry < im.text_rva || im.entry - im.text_rva >= im.text_size)
        rt_fatal("%s: entry outside .text", path);
    relocate_image(im, preferred);
    im.entry += im.base;
    munmap(file, (size_t)st.st_size);
    return im;
}

static void bind_imports(const Image *im) {
    if (!im->import_rva) return;
    for (uint64_t offset = 0; offset + 20 <= im->import_size; offset += 20) {
        const uint8_t *d = im->at((uint64_t)im->import_rva + offset, 20);
        if (!u32(d + 12)) return;
        const char *dll = im->string(u32(d + 12));
        const uint32_t names = u32(d) ? u32(d) : u32(d + 16);
        if (!names || !u32(d + 16)) rt_fatal("invalid PE import table");
        for (uint64_t k = 0;; ++k) {
            const uint64_t entry = u64(im->at(names + 8 * k, 8));
            if (!entry) break;
            char ordinal[8];
            snprintf(ordinal, sizeof(ordinal), "#%u", (unsigned)(entry & 0xffff));
            const char *name;
            if (entry >> 63) name = strdup(ordinal);
            else {
                if (entry > UINT32_MAX - 2) rt_fatal("invalid PE import name RVA");
                name = im->string((uint32_t)entry + 2);
            }
            const uint64_t thunk = thunk_of(add_import(dll, name));
            rt_put<uint64_t>(im->at(u32(d + 16) + 8 * k, 8), thunk);
        }
    }
    rt_fatal("unterminated PE import directory");
}

/* ---- the main thread: TEB, PEB, TLS ---- */

static uint8_t *peb;
static const uint8_t *tls_directory;
static uint64_t thread_stack_reserve = 1 << 20, thread_stack_commit = 4096;

size_t rt_thread_stack_size(uint64_t requested, bool reservation) {
    const uint64_t maximum = UINT64_C(0x7fffffff0000) - 0x100000;
    if (requested > maximum || thread_stack_reserve > maximum || thread_stack_commit > maximum) return 0;
    uint64_t size = thread_stack_reserve;
    if (reservation && requested) size = requested;
    else if (requested >= size && requested) size = (requested + 0xfffff) & ~UINT64_C(0xfffff);
    size = std::max(size, thread_stack_commit);
    return (std::max<uint64_t>(size, getpagesize()) + 0xffff) & ~UINT64_C(0xffff);
}

static void setup_process(const Image *im) {
    if (!im->stack_reserve || !im->stack_commit || im->stack_commit > im->stack_reserve)
        rt_fatal("invalid PE stack sizes");
    thread_stack_reserve = im->stack_reserve;
    thread_stack_commit = im->stack_commit;
    peb = static_cast<uint8_t *>(calloc(1, 0x1000));
    if (!peb) rt_fatal("out of memory");
    memcpy(peb + 0x10, &im->base, 8); /* ImageBaseAddress */
    if (!im->tls_rva) return;
    tls_directory = im->at(im->tls_rva, 40);
    const uint64_t start = u64(tls_directory), end = u64(tls_directory + 8);
    if (end < start) rt_fatal("invalid PE TLS template");
    if (start || end) {
        if (start < im->base) rt_fatal("invalid PE TLS template");
        im->at(start - im->base, end - start);
    }
    const uint64_t index = u64(tls_directory + 16), callbacks = u64(tls_directory + 24);
    if (index < im->base) rt_fatal("invalid PE TLS index");
    rt_put<uint32_t>(im->at(index - im->base, 4), 0);
    if (callbacks) {
        if (callbacks < im->base) rt_fatal("invalid PE TLS callback array");
        for (uint64_t offset = callbacks - im->base;; offset += 8) {
            const uint64_t target = u64(im->at(offset, 8));
            if (!target) break;
            if (target < im->base + im->text_rva || target - im->base - im->text_rva >= im->text_size)
                rt_fatal("PE TLS callback outside .text");
        }
    }
}

/* The calling host thread's TEB (stack bounds, self, TLS array with the image's block, PEB). */
uint64_t rt_thread_init(const void *stack, size_t size, uint32_t reason) {
    const uint64_t start = tls_directory ? u64(tls_directory) : 0;
    const uint64_t end = tls_directory ? u64(tls_directory + 8) : 0;
    const uint32_t zero_fill = tls_directory ? u32(tls_directory + 32) : 0;
    if (end < start || end - start > SIZE_MAX - 0x2200 - zero_fill)
        rt_fatal("invalid TLS template size");
    uint8_t *teb = static_cast<uint8_t *>(runtime_low_map(0x2200 + end - start + zero_fill, PROT_READ | PROT_WRITE));
    if (!teb) rt_fatal("cannot allocate thread TEB/TLS");
    const uint64_t stack_base = (uint64_t)(uintptr_t)stack + size, stack_limit = (uint64_t)(uintptr_t)stack;
    const uint64_t self = (uint64_t)(uintptr_t)teb, peb_address = (uint64_t)(uintptr_t)peb;
    uint64_t tid;
    pthread_threadid_np(nullptr, &tid);
    memcpy(teb + 0x08, &stack_base, 8);
    memcpy(teb + 0x10, &stack_limit, 8);
    memcpy(teb + 0x30, &self, 8);
    rt_put<uint64_t>(teb + 0x40, (uint64_t)getpid());
    rt_put<uint64_t>(teb + 0x48, (uint32_t)tid);
    memcpy(teb + 0x60, &peb_address, 8);
    if (tls_directory) {
        uint8_t *block = teb + 0x2200;
        uint64_t *array = (uint64_t *)(void *)(teb + 0x2000);
        if (end > start) memcpy(block, (const void *)(uintptr_t)start, end - start);
        array[0] = (uint64_t)(uintptr_t)block;
        rt_put<uint64_t>(teb + 0x58, (uint64_t)(uintptr_t)array);
    }
    bbcpu_set_gs_base(self);
    if (tls_directory && u64(tls_directory + 24)) {
        const uint64_t *callbacks = (const uint64_t *)(uintptr_t)u64(tls_directory + 24);
        const uint64_t args[] = {bb_image_base, reason, 0};
        for (size_t i = 0; callbacks[i]; ++i)
            bbcpu_call_on_stack_win64(callbacks[i], 3, args, (void *)stack, size);
    }
    return self;
}

void rt_thread_detach(uint64_t teb, void *stack, size_t size) {
    if (tls_directory && u64(tls_directory + 24)) {
        const uint64_t *callbacks = (const uint64_t *)(uintptr_t)u64(tls_directory + 24);
        const uint64_t args[] = {bb_image_base, 3, 0}; /* DLL_THREAD_DETACH */
        for (size_t i = 0; callbacks[i]; ++i)
            bbcpu_call_on_stack_win64(callbacks[i], 3, args, stack, size);
    }
    const uint64_t bytes = tls_directory ? u64(tls_directory + 8) - u64(tls_directory) + u32(tls_directory + 32) : 0;
    bbcpu_thread_cleanup();
    if (munmap((void *)(uintptr_t)teb, 0x2200 + bytes)) rt_fatal("cannot release thread TEB/TLS");
}

/* Keep dyld's __GUEST segment at D2's fixed address, before libc initializes. */
static void exec_without_aslr(char **argv) {
    if (getenv("SS_NO_ASLR")) return;
    setenv("SS_NO_ASLR", "1", 1);
    enum { POSIX_SPAWN_DISABLE_ASLR = 0x0100 };
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_DISABLE_ASLR);
    extern char **environ;
    pid_t pid;
    const int error = posix_spawn(&pid, argv[0], nullptr, &attr, argv, environ);
    rt_fatal("cannot run without ASLR: %s", strerror(error));
}

int main(int argc, char **argv) {
    exec_without_aslr(argv);
    const char *exe = argc > 1 ? argv[1] : getenv("SS_GAME_EXE");
    if (argc == 1) {
        const auto status = rt_prepare_package(exe);
        if (status == RtPackageStatus::Cancelled) return 0;
        if (status == RtPackageStatus::Failed) return 1;
    }
    if (!exe || !*exe) {
        fprintf(stderr, "Usage: %s /path/to/sinking_star.exe\n", argv[0]);
        return 2;
    }
    const char *log_path = getenv("SS_IMPORT_LOG");
    setenv("BB_JIT", "0", 0);                  /* D4: the interpreter is the fallback, not the JIT */
    setenv("BB_RECOMP_LIB", DEFAULT_LIB, 0);
    if (log_path && *log_path) {
        import_log = fopen(log_path, "w");
        if (!import_log) rt_fatal("%s: %s", log_path, strerror(errno));
        setvbuf(import_log, nullptr, _IOLBF, 0); /* complete up to a crash */
        fputs("call\timport\tcaller\n", import_log);
    }
    const char *target_path = getenv("SS_TARGET_LOG");
    if (target_path) {
        target_log = fopen(target_path, "w");
        if (!target_log) rt_fatal("%s: %s", target_path, strerror(errno));
        setvbuf(target_log, nullptr, _IOLBF, 0);
        fputs("kind\ttarget\n", target_log);
        bbcpu_set_target_observer(on_target);
    }
    setvbuf(stdout, nullptr, _IOLBF, 0);
    struct sigaction fault = {};
    fault.sa_sigaction = on_fault;
    fault.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &fault, nullptr);
    sigaction(SIGBUS, &fault, nullptr);
    sigaction(SIGILL, &fault, nullptr);
    sigaction(SIGFPE, &fault, nullptr);

    const Image im = map_image(exe);
    rt_files_init(exe);
    rt_process_init(exe, std::max(0, argc - 2), argv + std::min(argc, 2));
    bb_image_base = im.base;
    rt_crash_init(im.base, im.size, exe);
    bind_imports(&im);
    setup_process(&im);
    protect_image(&im);
    bbcpu_add_guest_code(im.base + im.text_rva, im.text_size);
    rt_bind_thunks();
    rt_audio_init();
    bbcpu_recomp_load(im.base);
    rt_math_init();
    rt_gamepad_init();
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, nullptr, 0) != 0) translated = 0;
    printf("loader: %s at %#llx, %u imports, entry %#llx; native arm64 process (proc_translated=%d)\n", exe,
           (unsigned long long)im.base, import_count, (unsigned long long)im.entry, translated);

    uint8_t *stack = static_cast<uint8_t *>(runtime_low_map(GUEST_STACK_SIZE, PROT_READ | PROT_WRITE));
    if (!stack) rt_fatal("cannot allocate guest stack");
    rt_thread_init(stack, GUEST_STACK_SIZE, 1); /* DLL_PROCESS_ATTACH */
    const uint64_t result = bbcpu_call_on_stack_win64(im.entry, 0, nullptr, stack, GUEST_STACK_SIZE);
    printf("loader: entry point returned %#llx after %llu import calls\n", (unsigned long long)result,
           (unsigned long long)import_calls.load(std::memory_order_relaxed));
    if (import_log) fclose(import_log);
    return (int)result;
}
