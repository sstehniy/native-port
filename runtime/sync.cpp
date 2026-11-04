/* One lock makes acquisition of multiple waitable objects atomic. */
#include "runtime.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <list>
#include <mutex>
#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>

enum { WAIT_OBJECT_0 = 0, WAIT_IO_COMPLETION = 0xc0, WAIT_TIMEOUT = 258, WAIT_FAILED = 0xffffffff, INFINITE = 0xffffffff };
enum { MAX_HANDLES = 1 << 16, HANDLE_BASE = 0x1000, MAX_WAIT = 64 };
static std::mutex lock;
static std::condition_variable changed;
static std::array<std::shared_ptr<Object>, MAX_HANDLES> handles;
static std::unordered_map<std::u16string, std::weak_ptr<Object>> names;

static std::shared_ptr<Object> *slot_of(uint64_t handle) {
    if (handle < HANDLE_BASE || (handle - HANDLE_BASE) % 4 || (handle - HANDLE_BASE) / 4 >= MAX_HANDLES) return nullptr;
    return &handles[(handle - HANDLE_BASE) / 4];
}
static uint64_t new_handle_locked(std::shared_ptr<Object> object) {
    for (uint32_t i = 1; i < MAX_HANDLES; ++i)
        if (!handles[i]) {
            handles[i] = std::move(object);
            return HANDLE_BASE + 4 * (uint64_t)i;
        }
    rt_set_last_error(8);
    return 0;
}
uint64_t rt_new_handle(std::shared_ptr<Object> object) {
    std::lock_guard guard(lock);
    return new_handle_locked(std::move(object));
}
std::shared_ptr<Object> rt_object(uint64_t handle) {
    std::lock_guard guard(lock);
    const std::shared_ptr<Object> *slot = slot_of(handle);
    return slot ? *slot : nullptr;
}
uint64_t rt_close_handle(uint64_t handle) {
    std::shared_ptr<Object> object;
    {
        std::lock_guard guard(lock);
        if (std::shared_ptr<Object> *slot = slot_of(handle)) object = std::move(*slot);
    }
    if (!object) { rt_set_last_error(6); return 0; }
    return 1;
}
H(CloseHandle) { return rt_close_handle(A(0)); }

static uint64_t named_handle(std::shared_ptr<Object> object, const char16_t *name) {
    if (!name) return rt_new_handle(std::move(object));
    std::lock_guard guard(lock);
    for (auto it = names.begin(); it != names.end();) {
        if (it->second.expired()) it = names.erase(it);
        else ++it;
    }
    auto &slot = names[name];
    if (auto existing = slot.lock()) {
        if (existing->kind != object->kind) { rt_set_last_error(6); return 0; }
        rt_set_last_error(183);
        return new_handle_locked(std::move(existing));
    }
    const uint64_t handle = new_handle_locked(object);
    if (handle) { slot = object; rt_set_last_error(0); }
    return handle;
}

/* I/O completion routines for this thread's alertable waits. Only ReadFileEx/WriteFileEx queue them,
 * always for the calling thread (the game imports no QueueUserAPC), so no lock is needed. */
struct Completion {
    uint64_t routine;
    uint64_t args[3];
};
static thread_local std::deque<Completion> completions;
void rt_queue_completion(uint64_t routine, uint32_t error, uint32_t bytes, uint64_t overlapped) {
    completions.push_back({routine, {error, bytes, overlapped}});
}
/* Runs queued routines, including any they queue, like Windows user APC delivery; false when none were queued. */
static bool run_completions() {
    if (completions.empty()) return false;
    while (!completions.empty()) {
        const Completion completion = completions.front();
        completions.pop_front();
        bbcpu_call_win64(completion.routine, 3, completion.args);
    }
    return true;
}

static uint32_t wait_handles(uint32_t count, const uint64_t *hs, bool all, uint32_t ms, bool alertable = false) {
    if (!hs || count < 1 || count > MAX_WAIT) { rt_set_last_error(87); return WAIT_FAILED; }
    std::array<std::shared_ptr<Object>, MAX_WAIT> objects;
    std::unique_lock guard(lock);
    for (uint32_t i = 0; i < count; ++i) {
        auto *slot = slot_of(hs[i]);
        if (!slot || !*slot) { rt_set_last_error(6); return WAIT_FAILED; }
        const Kind kind = (*slot)->kind;
        if (kind != Kind::Event && kind != Kind::Semaphore && kind != Kind::Thread && kind != Kind::File) {
            rt_set_last_error(6); return WAIT_FAILED;
        }
        objects[i] = *slot;
        for (uint32_t j = 0; j < i; ++j)
            if (hs[j] == hs[i] || (all && objects[j] == objects[i])) { rt_set_last_error(87); return WAIT_FAILED; }
    }
    uint32_t ready = 0;
    const auto satisfied = [&] {
        uint32_t ready_count = 0;
        for (uint32_t i = 0; i < count; ++i)
            if (objects[i]->ready()) { if (!ready_count) ready = i; ++ready_count; }
        return all ? ready_count == count : ready_count > 0;
    };
    /* Windows satisfies a wait from signaled objects before delivering pending completions. */
    if (alertable && !completions.empty() && !satisfied()) {
        guard.unlock();
        run_completions();
        return WAIT_IO_COMPLETION;
    }
    using Clock=std::chrono::steady_clock;
    const auto deadline=ms==INFINITE?Clock::time_point::max():Clock::now()+std::chrono::milliseconds(ms);
    bool pump=false;
    if (ms && !satisfied() && pthread_main_np()) {
        guard.unlock();pump=rt_window_pump_native();guard.lock();
    }
    bool done;
    if (pump) {
        // GPU waits on the game thread must keep AppKit services responsive.
        while (!satisfied() && Clock::now()<deadline) {
            changed.wait_until(guard,std::min(deadline,Clock::now()+std::chrono::milliseconds(10)),satisfied);
            if (!satisfied() && Clock::now()<deadline) {
                guard.unlock();rt_window_pump_native();guard.lock();
            }
        }
        done=satisfied();
    } else if (ms==INFINITE) { changed.wait(guard,satisfied);done=true; }
    else done=changed.wait_until(guard,deadline,satisfied);
    if (!done) return WAIT_TIMEOUT;
    if (!all) { objects[ready]->acquire(); return WAIT_OBJECT_0 + ready; }
    for (uint32_t i = 0; i < count; ++i) objects[i]->acquire();
    return WAIT_OBJECT_0;
}
H(WaitForSingleObject) { const uint64_t h = A(0); return wait_handles(1, &h, false, A(1)); }
H(WaitForSingleObjectEx) { const uint64_t h = A(0); return wait_handles(1, &h, false, A(1), (uint32_t)A(2) != 0); }
H(WaitForMultipleObjectsEx) { return wait_handles((uint32_t)A(0), P(1), (uint32_t)A(2) != 0, A(3), (uint32_t)A(4) != 0); }

struct Event final : Object {
    static constexpr Kind type = Kind::Event;
    Event(bool manual, bool set) : Object(type), manual(manual), set(set) {}
    bool ready() const override { return set; }
    void acquire() override { if (!manual) set = false; }
    const bool manual;
    bool set;
};
static uint64_t set_event(uint64_t handle, bool set) {
    const auto event = rt_object<Event>(handle);
    if (!event) { rt_set_last_error(6); return 0; }
    std::lock_guard guard(lock);
    event->set = set;
    changed.notify_all();
    return 1;
}
H(CreateEventW) { return named_handle(std::make_shared<Event>((uint32_t)A(1) != 0, (uint32_t)A(2) != 0), P(3)); }
H(SetEvent) { return set_event(A(0), true); }
H(ResetEvent) { return set_event(A(0), false); }
uint64_t rt_signal_event(uint64_t handle) { return set_event(handle,true); }

struct Semaphore final : Object {
    static constexpr Kind type = Kind::Semaphore;
    Semaphore(int32_t count, int32_t maximum) : Object(type), count(count), maximum(maximum) {}
    bool ready() const override { return count > 0; }
    void acquire() override { --count; }
    int32_t count;
    const int32_t maximum;
};
H(CreateSemaphoreW) {
    const int32_t count = A(1), maximum = A(2);
    if (count < 0 || maximum <= 0 || count > maximum) { rt_set_last_error(87); return 0; }
    return named_handle(std::make_shared<Semaphore>(count, maximum), P(3));
}
uint64_t rt_semaphore_create(int32_t initial, int32_t maximum) {
    if (initial < 0 || maximum <= 0 || initial > maximum) return 0;
    return rt_new_handle(std::make_shared<Semaphore>(initial, maximum));
}
bool rt_semaphore_release(uint64_t handle, int32_t count, int32_t *previous) {
    const auto semaphore = rt_object<Semaphore>(handle);
    if (!semaphore) { rt_set_last_error(6); return false; }
    if (count <= 0) { rt_set_last_error(87); return false; }
    std::lock_guard guard(lock);
    if (count > semaphore->maximum - semaphore->count) { rt_set_last_error(298); return false; }
    if (previous) rt_put<int32_t>(previous, semaphore->count);
    semaphore->count += count;
    changed.notify_all();
    return true;
}
bool rt_semaphore_try_wait(uint64_t handle) {
    const auto semaphore = rt_object<Semaphore>(handle);
    if (!semaphore) return false;
    std::lock_guard guard(lock);
    if (!semaphore->ready()) return false;
    semaphore->acquire();
    return true;
}
H(ReleaseSemaphore) { return rt_semaphore_release(A(0), A(1), P(2)); }

struct Thread final : Object {
    static constexpr Kind type = Kind::Thread;
    Thread(uint64_t start, uint64_t param, size_t size, bool suspended)
        : Object(type), start(start), param(param), size(size), suspended(suspended) {}
    ~Thread() override { if (mapping) munmap(mapping, size + 2 * getpagesize()); }
    bool ready() const override { return exited; }
    const uint64_t start, param;
    const size_t size;
    void *mapping = nullptr;
    std::mutex gate;
    std::condition_variable resumed;
    bool suspended;
    uint32_t id = 0;
    bool exited = false; // Wait state and settings use the process-wide lock.
    uint32_t exit_code = 0;
    uint64_t affinity = (UINT64_C(1) << sysconf(_SC_NPROCESSORS_ONLN)) - 1;
};
static thread_local Thread *current_thread;

static void *thread_main(void *arg) {
    const std::unique_ptr<std::shared_ptr<Thread>> owner(static_cast<std::shared_ptr<Thread> *>(arg));
    Thread &t = **owner;
    uint64_t tid;
    if (pthread_threadid_np(nullptr, &tid)) rt_fatal("cannot read worker thread ID");
    {
        std::unique_lock gate(t.gate);
        t.id = (uint32_t)tid;
        t.resumed.notify_all();
        t.resumed.wait(gate, [&] { return !t.suspended; });
    }
    current_thread = &t;
    uint8_t *stack = static_cast<uint8_t *>(t.mapping) + getpagesize();
    const uint64_t teb = rt_thread_init(stack, t.size, 2);
    const uint32_t code = bbcpu_call_on_stack_win64(t.start, 1, &t.param, stack, t.size);
    rt_thread_detach(teb, stack, t.size);
    current_thread = nullptr;
    if (munmap(t.mapping, t.size + 2 * getpagesize())) rt_fatal("cannot release worker stack");
    t.mapping = nullptr;
    {
        std::lock_guard guard(lock);
        t.exit_code = code;
        t.exited = true;
        changed.notify_all();
    }
    return nullptr;
}
static uint64_t create_thread(uint64_t requested, uint64_t start, uint64_t param, uint32_t flags, uint32_t *tid_out) {
    const size_t size = rt_thread_stack_size(requested, (flags & 0x10000) != 0);
    if (!size || !start || (flags & ~(4u | 0x10000u))) { rt_set_last_error(87); return 0; }
    auto thread = std::make_shared<Thread>(start, param, size, (flags & 4) != 0);
    thread->mapping = runtime_low_map(size + 2 * getpagesize(), PROT_NONE);
    if (!thread->mapping) { rt_set_last_error(8); return 0; }
    if (mprotect(static_cast<uint8_t *>(thread->mapping) + getpagesize(), size, PROT_READ | PROT_WRITE)) {
        rt_set_last_error(8); return 0;
    }
    const uint64_t handle = rt_new_handle(thread);
    if (!handle) return 0;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr)) { rt_close_handle(handle); rt_set_last_error(8); return 0; }
    int error = pthread_attr_setstacksize(&attr, (size_t)8 << 20);
    if (!error) error = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (error) { pthread_attr_destroy(&attr); rt_close_handle(handle); rt_set_last_error(8); return 0; }
    auto *owner = new std::shared_ptr<Thread>(thread);
    pthread_t host;
    error = pthread_create(&host, &attr, thread_main, owner);
    pthread_attr_destroy(&attr);
    if (error) { delete owner; rt_close_handle(handle); rt_set_last_error(8); return 0; }
    {
        std::unique_lock gate(thread->gate);
        thread->resumed.wait(gate, [&] { return thread->id != 0; });
        if (tid_out) *tid_out = thread->id;
    }
    printf("runtime: thread %#llx start %#llx param %#llx stack %zu%s\n", (unsigned long long)handle,
           (unsigned long long)start, (unsigned long long)param, size, (flags & 4) ? " (suspended)" : "");
    return handle;
}
H(CreateThread) { return create_thread(A(1), A(2), A(3), A(4), P(5)); }
H(_beginthreadex) { return create_thread((uint32_t)A(1), A(2), A(3), A(4), P(5)); }
H(ResumeThread) {
    const auto thread = rt_object<Thread>(A(0));
    if (!thread) { rt_set_last_error(6); return UINT32_MAX; }
    std::lock_guard gate(thread->gate);
    const uint32_t previous = thread->suspended;
    thread->suspended = false;
    thread->resumed.notify_all();
    return previous;
}
H(GetExitCodeThread) {
    const auto thread = rt_object<Thread>(A(0));
    if (!thread || !P(1)) { rt_set_last_error(6); return 0; }
    std::lock_guard guard(lock);
    rt_put<uint32_t>(P(1), thread->exited ? thread->exit_code : 259);
    return 1;
}
H(SetThreadPriority) {
    const bool self = A(0) == UINT64_MAX - 1;
    const auto owner = self ? std::shared_ptr<Thread>() : rt_object<Thread>(A(0));
    Thread *thread = self ? current_thread : owner.get();
    if (!self && !thread) { rt_set_last_error(6); return 0; }
    const int32_t priority = A(1);
    const bool background = priority == 0x10000 || priority == 0x20000;
    if ((background && !self) || (!background && (priority < -2 || priority > 2) && priority != -15 && priority != 15)) {
        rt_set_last_error(87); return 0;
    }
    std::lock_guard guard(lock);
    printf("runtime: SetThreadPriority(%#llx, %d) accepted, host scheduling unchanged\n", (unsigned long long)A(0), priority);
    return 1;
}
H(SetThreadAffinityMask) {
    const bool self = A(0) == UINT64_MAX - 1;
    const auto owner = self ? std::shared_ptr<Thread>() : rt_object<Thread>(A(0));
    Thread *thread = self ? current_thread : owner.get();
    if (!self && !thread) { rt_set_last_error(6); return 0; }
    const uint64_t mask = A(1), available = (UINT64_C(1) << sysconf(_SC_NPROCESSORS_ONLN)) - 1;
    if (!mask || (mask & ~available)) { rt_set_last_error(87); return 0; }
    static thread_local uint64_t main_affinity = available;
    std::lock_guard guard(lock);
    uint64_t &affinity = thread ? thread->affinity : main_affinity;
    const uint64_t previous = affinity;
    affinity = mask;
    printf("runtime: SetThreadAffinityMask(%#llx, %#llx) accepted, host placement unchanged\n",
           (unsigned long long)A(0), (unsigned long long)mask);
    return previous;
}
static void sleep_ms(uint32_t ms) {
    if (!ms) { std::this_thread::yield(); return; }
    if (ms == INFINITE) {
        std::unique_lock guard(lock);
        changed.wait(guard, [] { return false; });
    } else std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}
H(Sleep) { sleep_ms(A(0)); return 0; }
H(SleepEx) {
    if ((uint32_t)A(1) && run_completions()) return WAIT_IO_COMPLETION;
    sleep_ms(A(0));
    return 0;
}

/* Condition variables need no allocated object in guest memory and have no destroy API. */
template <class T> static std::atomic_ref<T *> host_slot(void *guest) { return std::atomic_ref<T *>(*static_cast<T **>(guest)); }
static pthread_mutex_t *cs_mutex(void *cs) {
    const auto slot = host_slot<pthread_mutex_t>(cs);
    if (auto *m = slot.load(std::memory_order_acquire)) return m;
    static std::mutex create;
    std::lock_guard guard(create);
    pthread_mutex_t *m = slot.load(std::memory_order_relaxed);
    if (!m) {
        m = new pthread_mutex_t;
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        const int error = pthread_mutex_init(m, &attr);
        pthread_mutexattr_destroy(&attr);
        if (error) rt_fatal("cannot initialize guest critical section");
        slot.store(m, std::memory_order_release);
    }
    return m;
}
H(InitializeCriticalSection) { memset(P(0), 0, 40); cs_mutex(P(0)); return 0; }
H(InitializeCriticalSectionAndSpinCount) {
    memset(P(0), 0, 40);
    cs_mutex(P(0));
    rt_put<uint64_t>(static_cast<uint8_t *>(P(0)) + 32, (uint32_t)A(1));
    return 1;
}
H(EnterCriticalSection) { if (pthread_mutex_lock(cs_mutex(P(0)))) rt_fatal("cannot enter guest critical section"); return 0; }
H(LeaveCriticalSection) { if (pthread_mutex_unlock(cs_mutex(P(0)))) rt_fatal("cannot leave guest critical section"); return 0; }
H(DeleteCriticalSection) {
    auto *m = host_slot<pthread_mutex_t>(P(0)).load(std::memory_order_acquire);
    if (m) {
        if (pthread_mutex_destroy(m)) rt_fatal("deleting an owned guest critical section");
        delete m;
    }
    memset(P(0), 0, 40);
    return 0;
}
struct AddressWait {
    uint64_t address;
    bool condition;
    bool woken = false;
    std::condition_variable changed;
};
static std::mutex address_lock;
static std::list<AddressWait *> address_waiters;
static bool wait_address(std::unique_lock<std::mutex> &guard, uint64_t address, bool condition, uint32_t ms,
                         pthread_mutex_t *release = nullptr) {
    AddressWait waiter{.address = address, .condition = condition};
    const auto it = address_waiters.insert(address_waiters.end(), &waiter);
    if (release && pthread_mutex_unlock(release)) rt_fatal("condition wait without owning its critical section");
    bool done;
    if (ms == INFINITE) { waiter.changed.wait(guard, [&] { return waiter.woken; }); done = true; }
    else done = waiter.changed.wait_for(guard, std::chrono::milliseconds(ms), [&] { return waiter.woken; });
    address_waiters.erase(it);
    guard.unlock();
    if (release && pthread_mutex_lock(release)) rt_fatal("cannot reacquire critical section after condition wait");
    if (!done) rt_set_last_error(1460);
    return done;
}
static void wake_address(uint64_t address, bool condition, bool all) {
    std::lock_guard guard(address_lock);
    for (auto *waiter : address_waiters) {
        if (waiter->address != address || waiter->condition != condition || waiter->woken) continue;
        waiter->woken = true;
        waiter->changed.notify_one();
        if (!all) break;
    }
}
H(WaitOnAddress) {
    const uint64_t address = A(0), compare = A(1), size = A(2);
    if (!address || !compare || (size != 1 && size != 2 && size != 4 && size != 8)) { rt_set_last_error(87); return 0; }
    std::unique_lock guard(address_lock);
    if (bb_load(address, size) != bb_load(compare, size)) return 1;
    return wait_address(guard, address, false, A(3));
}
H(WakeByAddressSingle) { wake_address(A(0), false, false); return 0; }
H(WakeByAddressAll) { wake_address(A(0), false, true); return 0; }
H(InitializeConditionVariable) { memset(P(0), 0, 8); return 0; }
H(WakeConditionVariable) { wake_address(A(0), true, false); return 0; }
H(WakeAllConditionVariable) { wake_address(A(0), true, true); return 0; }
H(SleepConditionVariableCS) {
    pthread_mutex_t *mutex = cs_mutex(P(1));
    std::unique_lock guard(address_lock);
    return wait_address(guard, A(0), true, A(2), mutex);
}
H(InitializeSListHead) {
    if (A(0) & 15) rt_fatal("unaligned SLIST_HEADER");
    memset(P(0), 0, 16);
    return 0;
}

#define E(name) {#name, name}
const RtEntry rt_sync_entries[] = {
    E(CloseHandle), E(WaitForSingleObject), E(WaitForSingleObjectEx), E(WaitForMultipleObjectsEx),
    E(CreateEventW), E(SetEvent), E(ResetEvent), E(CreateSemaphoreW), E(ReleaseSemaphore),
    E(CreateThread), E(_beginthreadex), E(ResumeThread), E(GetExitCodeThread), E(SetThreadPriority),
    E(SetThreadAffinityMask), E(Sleep), E(SleepEx), E(WaitOnAddress), E(WakeByAddressSingle), E(WakeByAddressAll),
    E(InitializeCriticalSection), E(InitializeCriticalSectionAndSpinCount), E(EnterCriticalSection),
    E(LeaveCriticalSection), E(DeleteCriticalSection), E(InitializeConditionVariable), E(SleepConditionVariableCS),
    E(WakeConditionVariable), E(WakeAllConditionVariable), E(InitializeSListHead),
    {nullptr, nullptr},
};
