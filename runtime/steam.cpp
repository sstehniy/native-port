/* Offline Steam subset: local achievements and Win64 manual dispatch, without a Steam client. */
#include "runtime.h"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fcntl.h>
#include <filesystem>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static constexpr uint32_t APP_ID = 499170;
static constexpr uint64_t USER_ID = UINT64_C(76561197960265729);
static constexpr size_t MAX_ACHIEVEMENTS = 1024, MAX_EVENTS = 4096, MAX_RESULTS = 1024;
static constexpr char FILE_HEADER[] = "SS_STEAM_499170_V1\n";
enum { APPS, FRIENDS, INPUT, USER_STATS, USER, UTILS };
static const uint8_t interfaces[6] = {};
#define IFACE(i) ((uint64_t)(uintptr_t)&interfaces[i])
// Callback data uses Windows pack(8), including explicit padding rather than macOS SDK pack(4).
struct StatsReceived { uint64_t game; int32_t result; uint32_t pad; uint64_t user; };
struct StatsStored { uint64_t game; int32_t result; uint32_t pad; };
struct AchievementStored { uint64_t game; uint8_t group; char name[128]; uint8_t pad[3]; uint32_t current, maximum, tail; };
struct CallCompleted { uint64_t handle; int32_t callback; uint32_t size; };
struct CallbackMessage { int32_t user, callback; uint64_t data; int32_t size; uint32_t pad; };
static_assert(sizeof(StatsReceived) == 24 && offsetof(StatsReceived, user) == 16);
static_assert(sizeof(StatsStored) == 16 && sizeof(CallCompleted) == 16 && sizeof(CallbackMessage) == 24);
static_assert(sizeof(AchievementStored) == 152 && offsetof(AchievementStored, name) == 9 && offsetof(AchievementStored, current) == 140);
struct Event { int32_t id; std::vector<uint8_t> bytes; };
struct Result { StatsReceived data; bool ready; };
static std::mutex steam_lock;
static bool initialized, manual_dispatch;
static int32_t pipe_id, next_pipe = 1;
static uint64_t next_call = UINT64_C(0x100000001);
static std::set<std::string> achievements, changed;
static std::deque<Event> pending, callbacks;
static std::optional<Event> held;
static std::map<uint64_t, Result> results;
static std::string state_path;

static bool valid(int iface, uint64_t self) { return initialized && self == IFACE(iface); }
static bool valid_pipe(uint64_t pipe) { return initialized && manual_dispatch && (int32_t)pipe == pipe_id; }
static size_t queued() { return pending.size() + callbacks.size() + (held ? 1 : 0); }
template <class T> static void enqueue(int32_t id, const T &data) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&data);
    pending.push_back({id, std::vector<uint8_t>(bytes, bytes + sizeof(T))});
}
// shortcut: all 33 game IDs are printable ASCII; use a published UTF-8 catalog with a native Steamworks bridge.
static bool valid_name(const char *name) {
    if (!name) return false;
    const size_t size = strnlen(name, 128);
    if (!size || size == 128) return false;
    for (size_t i = 0; i < size; ++i) if ((uint8_t)name[i] < 33 || (uint8_t)name[i] > 126) return false;
    return true;
}
static bool load_achievements(std::set<std::string> &out) {
    const int fd = open(state_path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno == ENOENT;
    struct stat st{};
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size > (off_t)(MAX_ACHIEVEMENTS * 128 + 32)) { close(fd); return false; }
    FILE *file = fdopen(fd, "r");
    if (!file) { close(fd); return false; }
    char line[130];
    bool ok = fgets(line, sizeof(line), file) && !strcmp(line, FILE_HEADER);
    while (ok && fgets(line, sizeof(line), file)) {
        const size_t size = strlen(line);
        if (!size || line[size - 1] != '\n') { ok = false; break; }
        line[size - 1] = 0;
        if (!valid_name(line) || !out.insert(line).second || out.size() > MAX_ACHIEVEMENTS) { ok = false; break; }
    }
    if (ferror(file)) ok = false;
    if (fclose(file)) ok = false;
    return ok;
}
static bool persist_achievements() {
    const int lock = open((state_path + ".lock").c_str(), O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (lock < 0) return false;
    struct stat st{};
    if (fstat(lock, &st) || !S_ISREG(st.st_mode)) { close(lock); return false; }
    std::set<std::string> merged;
    bool ok = flock(lock, LOCK_EX) == 0 && load_achievements(merged);
    merged.insert(achievements.begin(), achievements.end());
    if (merged.size() > MAX_ACHIEVEMENTS) ok = false;
    std::string temporary = state_path + ".XXXXXX";
    if (ok) {
        const int fd = mkstemp(temporary.data());
        if (fd < 0) ok = false;
        else {
            FILE *file = fdopen(fd, "w");
            if (!file) { close(fd); ok = false; }
            else {
                if (fputs(FILE_HEADER, file) < 0) ok = false;
                for (const auto &name : merged) if (fprintf(file, "%s\n", name.c_str()) < 0) ok = false;
                if (fflush(file) || fsync(fd)) ok = false;
                if (fclose(file)) ok = false;
            }
            if (ok && rename(temporary.c_str(), state_path.c_str())) ok = false;
            if (!ok) unlink(temporary.c_str());
        }
    }
    close(lock);
    if (ok) achievements = std::move(merged);
    return ok;
}
static bool versions_match(const char *versions) {
    if (!versions) return true;
    static constexpr std::pair<std::string_view, std::string_view> supported[] = {
        {"STEAMAPPS_INTERFACE_VERSION", "STEAMAPPS_INTERFACE_VERSION009"},
        {"SteamFriends", "SteamFriends018"}, {"SteamInput", "SteamInput007"},
        {"STEAMUSERSTATS_INTERFACE_VERSION", "STEAMUSERSTATS_INTERFACE_VERSION013"},
        {"SteamUser", "SteamUser023"}, {"SteamUtils", "SteamUtils011"}
    };
    size_t remaining = 4096;
    while (remaining && *versions) {
        const size_t size = strnlen(versions, remaining);
        if (size == remaining) return false;
        const std::string_view version(versions, size);
        for (const auto &[prefix, exact] : supported) if (version.starts_with(prefix) && version != exact) return false;
        versions += size + 1; remaining -= size + 1;
    }
    return remaining != 0;
}
H(SteamAPI_RestartAppIfNecessary) { return 0; }
H(SteamInternal_SteamAPI_Init) {
    std::lock_guard guard(steam_lock);
    if (P(1)) *(char *)P(1) = 0;
    if (!versions_match(P(0))) {
        if (P(1)) snprintf(P(1), 1024, "Unsupported offline Steam interface version");
        return 3;
    }
    if (initialized) return 0;
    const char *profile = getenv("SS_PROFILE_DIR");
    const std::filesystem::path directory = std::filesystem::path(profile ? profile : "build/recomp/userdata/Player") / "SteamOffline";
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    state_path = (directory / "achievements.txt").string();
    std::set<std::string> loaded;
    if (error || !load_achievements(loaded) || next_pipe == INT32_MAX) {
        if (P(1)) snprintf(P(1), 1024, "Cannot load offline Steam achievements");
        return 1;
    }
    achievements = std::move(loaded);
    pipe_id = next_pipe++;
    initialized = true;
    // UserStats v013 already has local stats; announce them independently of any call result.
    enqueue(1101, StatsReceived{APP_ID, 1, 0, USER_ID});
    return 0;
}
H(SteamAPI_Shutdown) {
    std::lock_guard guard(steam_lock);
    if (initialized && !changed.empty() && !persist_achievements()) fputs("steam: cannot save pending offline achievements\n", stderr);
    initialized = manual_dispatch = false;
    achievements.clear(); changed.clear(); pending.clear(); callbacks.clear(); held.reset(); results.clear();
    pipe_id = 0;
    return 0;
}
H(SteamAPI_GetHSteamPipe) { std::lock_guard guard(steam_lock); return (uint32_t)pipe_id; }
H(SteamAPI_SteamApps_v009) { std::lock_guard guard(steam_lock); return initialized ? IFACE(APPS) : 0; }
H(SteamAPI_SteamFriends_v018) { std::lock_guard guard(steam_lock); return initialized ? IFACE(FRIENDS) : 0; }
H(SteamAPI_SteamInput_v007) { std::lock_guard guard(steam_lock); return initialized ? IFACE(INPUT) : 0; }
H(SteamAPI_SteamUserStats_v013) { std::lock_guard guard(steam_lock); return initialized ? IFACE(USER_STATS) : 0; }
H(SteamAPI_SteamUser_v023) { std::lock_guard guard(steam_lock); return initialized ? IFACE(USER) : 0; }
H(SteamAPI_SteamUtils_v011) { std::lock_guard guard(steam_lock); return initialized ? IFACE(UTILS) : 0; }
H(SteamAPI_ISteamApps_GetCurrentGameLanguage) { std::lock_guard guard(steam_lock); return valid(APPS, A(0)) ? (uintptr_t)"english" : 0; }
H(SteamAPI_ISteamApps_GetAvailableGameLanguages) { std::lock_guard guard(steam_lock); return valid(APPS, A(0)) ? (uintptr_t)"english" : 0; }
H(SteamAPI_ISteamApps_GetAppBuildId) { return 0; } // No Steam depot/build metadata is installed with this port.
H(SteamAPI_ISteamApps_GetCurrentBetaName) { if (P(1) && (int32_t)A(2) > 0) *(char *)P(1) = 0; return 0; }
H(SteamAPI_ISteamInput_Init) { std::lock_guard guard(steam_lock); return valid(INPUT, A(0)); }
H(SteamAPI_ISteamInput_GetControllerForGamepadIndex) { return 0; } // Native controllers use XInput (R3.05).
H(SteamAPI_ISteamInput_GetInputTypeForHandle) { return 0; } // k_ESteamInputType_Unknown, no Steam controller handles.
H(SteamAPI_ISteamUserStats_RequestUserStats) {
    std::lock_guard guard(steam_lock);
    if (!valid(USER_STATS, A(0)) || results.size() == MAX_RESULTS || queued() == MAX_EVENTS || next_call == UINT64_MAX) return 0;
    const uint64_t handle = next_call++;
    results.emplace(handle, Result{StatsReceived{APP_ID, A(1) == USER_ID ? 1 : 2, 0, A(1)}, false});
    enqueue(703, CallCompleted{handle, 1101, sizeof(StatsReceived)});
    return handle;
}
H(SteamAPI_ISteamUserStats_GetAchievement) {
    std::lock_guard guard(steam_lock);
    if (P(2)) *(uint8_t *)P(2) = 0;
    if (!valid(USER_STATS, A(0)) || !P(2) || !valid_name(P(1))) return 0;
    *(uint8_t *)P(2) = achievements.contains((const char *)P(1));
    return 1;
}
H(SteamAPI_ISteamUserStats_SetAchievement) {
    std::lock_guard guard(steam_lock);
    if (!valid(USER_STATS, A(0)) || !valid_name(P(1))) return 0;
    const std::string name = (const char *)P(1);
    if (!achievements.contains(name)) {
        if (achievements.size() == MAX_ACHIEVEMENTS) return 0;
        achievements.insert(name); changed.insert(name);
    }
    return 1;
}
H(SteamAPI_ISteamUserStats_StoreStats) {
    std::lock_guard guard(steam_lock);
    if (!valid(USER_STATS, A(0)) || queued() + changed.size() + 1 > MAX_EVENTS) return 0;
    if (!changed.empty() && !persist_achievements()) return 0;
    enqueue(1102, StatsStored{APP_ID, 1, 0});
    for (const auto &name : changed) {
        AchievementStored stored{}; stored.game = APP_ID;
        memcpy(stored.name, name.c_str(), name.size() + 1);
        enqueue(1103, stored);
    }
    changed.clear();
    return 1;
}
H(SteamAPI_ISteamUser_GetSteamID) { std::lock_guard guard(steam_lock); return valid(USER, A(0)) ? USER_ID : 0; }
H(SteamAPI_ISteamUtils_GetAppID) { std::lock_guard guard(steam_lock); return valid(UTILS, A(0)) ? APP_ID : 0; }
H(SteamAPI_ISteamUtils_IsRunningOnSteamHardware) { return 0; }
H(SteamAPI_ManualDispatch_Init) { std::lock_guard guard(steam_lock); manual_dispatch = initialized; return 0; }
H(SteamAPI_ManualDispatch_RunFrame) {
    std::lock_guard guard(steam_lock);
    if (valid_pipe(A(0))) {
        for (auto &[handle, result] : results) result.ready = true;
        while (!pending.empty()) { callbacks.push_back(std::move(pending.front())); pending.pop_front(); }
    }
    return 0;
}
H(SteamAPI_ManualDispatch_GetNextCallback) {
    std::lock_guard guard(steam_lock);
    if (!valid_pipe(A(0)) || !P(1) || held || callbacks.empty()) return 0;
    held = std::move(callbacks.front()); callbacks.pop_front();
    const CallbackMessage message{1, held->id, (uintptr_t)held->bytes.data(), (int32_t)held->bytes.size(), 0};
    memcpy(P(1), &message, sizeof(message));
    return 1;
}
H(SteamAPI_ManualDispatch_FreeLastCallback) { std::lock_guard guard(steam_lock); if (valid_pipe(A(0))) held.reset(); return 0; }
H(SteamAPI_ManualDispatch_GetAPICallResult) {
    std::lock_guard guard(steam_lock);
    if (P(5)) *(uint8_t *)P(5) = 1;
    if (!valid_pipe(A(0)) || !P(2) || !P(5) || (uint32_t)A(3) != sizeof(StatsReceived) || (uint32_t)A(4) != 1101) return 0;
    const auto found = results.find(A(1));
    if (found == results.end() || !found->second.ready) return 0;
    memcpy(P(2), &found->second.data, sizeof(StatsReceived));
    *(uint8_t *)P(5) = 0;
    results.erase(found);
    return 1;
}

#define E(name) {#name, name}
const RtEntry rt_steam_entries[] = {
    E(SteamAPI_RestartAppIfNecessary), E(SteamInternal_SteamAPI_Init), E(SteamAPI_Shutdown), E(SteamAPI_GetHSteamPipe),
    E(SteamAPI_SteamApps_v009), E(SteamAPI_SteamFriends_v018), E(SteamAPI_SteamInput_v007),
    E(SteamAPI_SteamUserStats_v013), E(SteamAPI_SteamUser_v023), E(SteamAPI_SteamUtils_v011),
    E(SteamAPI_ISteamApps_GetCurrentGameLanguage), E(SteamAPI_ISteamApps_GetAvailableGameLanguages),
    E(SteamAPI_ISteamApps_GetAppBuildId), E(SteamAPI_ISteamApps_GetCurrentBetaName), E(SteamAPI_ISteamInput_Init),
    E(SteamAPI_ISteamInput_GetControllerForGamepadIndex), E(SteamAPI_ISteamInput_GetInputTypeForHandle),
    E(SteamAPI_ISteamUserStats_RequestUserStats), E(SteamAPI_ISteamUserStats_GetAchievement),
    E(SteamAPI_ISteamUserStats_SetAchievement), E(SteamAPI_ISteamUserStats_StoreStats),
    E(SteamAPI_ISteamUser_GetSteamID), E(SteamAPI_ISteamUtils_GetAppID), E(SteamAPI_ISteamUtils_IsRunningOnSteamHardware),
    E(SteamAPI_ManualDispatch_Init), E(SteamAPI_ManualDispatch_RunFrame), E(SteamAPI_ManualDispatch_GetNextCallback),
    E(SteamAPI_ManualDispatch_FreeLastCallback), E(SteamAPI_ManualDispatch_GetAPICallResult),
    {nullptr, nullptr}
};
