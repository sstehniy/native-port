/* Files and paths. The game sees Windows paths; two roots map to the host:
 *   C:\Game\           the installed game folder, read-only (opening it for writing fails), except
 *                      its logs\, measurements\ and screenshots\ folders, which live in the profile
 *   C:\Users\Player\   the port's own profile, build/recomp/userdata/Player (D9: never the real saves)
 * Everything else does not exist. Names ignore case, as on Windows, also on case-sensitive volumes. */
#include "runtime.h"

#include <algorithm>
#include <atomic>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <filesystem>
#include <fnmatch.h>
#include <map>
#include <mutex>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#define GAME_ROOT "C:\\Game\\"
#define USER_ROOT "C:\\Users\\Player\\"

static std::string game_dir, user_dir;
static std::string current_dir = GAME_ROOT;

/* mkdir -p; returns the error, empty on success. */
static std::error_code make_directories(const std::string &path) {
    std::error_code error;
    std::filesystem::create_directories(path, error);
    return error;
}

/* D9: on the first run the port's save folder starts as a copy of the existing saves, which are only
 * read. SS_SEED_SAVES names another source folder; set but empty, it disables seeding. */
static void seed_saves() {
    const char *source = getenv("SS_SEED_SAVES"), *home = getenv("HOME");
    const std::string from = source ? source : std::string(home ? home : "") +
        "/Library/Application Support/CrossOver/Bottles/Order of the Sinking Star/drive_c/users/crossover/Saved Games/Order of the Sinking Star";
    const std::string to = user_dir + "Saved Games/Order of the Sinking Star", staging = to + ".seeding";
    std::error_code error;
    const auto seeded = [&] { return std::filesystem::exists(to, error) && !std::filesystem::is_empty(to, error); };
    if (seeded() || from.empty() || !std::filesystem::is_directory(from, error)) return;
    /* Launches that start together take turns; a later one finds the saves already there. */
    const std::string lock = user_dir + ".seeding.lock";
    const int fd = open(lock.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0 || flock(fd, LOCK_EX)) rt_fatal("cannot lock %s: %s", lock.c_str(), strerror(errno));
    if (seeded()) { close(fd); return; }
    /* Copied aside first, so an interrupted copy is never taken for the saves. */
    std::filesystem::remove_all(staging, error);
    if (!error) error = make_directories(staging);
    if (!error) std::filesystem::copy(from, staging, std::filesystem::copy_options::recursive, error);
    if (!error) std::filesystem::remove(to, error); /* the game may have left it empty */
    if (!error) std::filesystem::rename(staging, to, error);
    if (error) rt_fatal("cannot copy the saves from %s: %s", from.c_str(), error.message().c_str());
    close(fd);
    fprintf(stderr, "runtime: copied the saves from %s\n", from.c_str());
}

void rt_files_init(const char *exe_path) {
    game_dir = exe_path;
    if (const size_t slash = game_dir.rfind('/'); slash != std::string::npos) game_dir.resize(slash + 1);
    const char *profile = getenv("SS_PROFILE_DIR");
    std::error_code error;
    user_dir = (profile ? std::string(profile) : std::filesystem::current_path(error).string() + "/build/recomp/userdata/Player") + "/";
    const std::string game_writes = user_dir + "Game";
    if (error || (error = make_directories(game_writes))) rt_fatal("cannot create %s: %s", game_writes.c_str(), error.message().c_str());
    seed_saves();
}

/* ---- paths ---- */

/* A Windows path made absolute and normalized (backslashes, no `.`/`..`). */
static std::string full_path(std::string_view in) {
    std::string joined;
    if (in.size() >= 2 && in[1] == ':') joined = in;
    else if (!in.empty() && (in[0] == '\\' || in[0] == '/')) joined = "C:" + std::string(in);
    else joined = current_dir + std::string(in);
    std::replace(joined.begin(), joined.end(), '/', '\\');
    std::vector<std::string_view> parts;
    for (size_t at = 2; at <= joined.size();) {
        const size_t end = std::min(joined.find('\\', at), joined.size());
        const std::string_view part = std::string_view(joined).substr(at, end - at);
        at = end + 1;
        if (part.empty() || part == ".") continue;
        if (part == "..") { if (!parts.empty()) parts.pop_back(); continue; }
        parts.push_back(part);
    }
    std::string out = {(char)(joined[0] & ~0x20), ':'};
    for (const std::string_view part : parts) (out += '\\') += part;
    if (parts.empty()) out += '\\';
    return out;
}

/* Whether `path` is `folder` or inside it, ignoring case; strips the folder when it is. */
static bool strip_folder(std::string_view &path, std::string_view folder) {
    if (path.size() < folder.size() || strncasecmp(path.data(), folder.data(), folder.size())) return false;
    if (path.size() > folder.size() && path[folder.size()] != '\\') return false;
    path.remove_prefix(folder.size());
    return true;
}

/* `base` + `relative` as spelled on the host: each component missing as given is matched against its
 * directory ignoring case. An unmatched component and the rest stay as given (a file about to be made).
 * shortcut: ASCII case folding; Windows also folds other letters. */
static std::string resolve_case(std::string base, std::string_view relative) {
    struct stat st;
    if (!lstat((base + std::string(relative)).c_str(), &st)) return base + std::string(relative);
    while (!relative.empty()) {
        const size_t end = std::min(relative.find('/'), relative.size());
        std::string name(relative.substr(0, end));
        if (lstat((base + name).c_str(), &st)) {
            DIR *dir = opendir(base.c_str());
            bool found = false;
            for (struct dirent *e; dir && !found && (e = readdir(dir));)
                if (!strcasecmp(e->d_name, name.c_str())) name = e->d_name, found = true;
            if (dir) closedir(dir);
            if (!found) return base + std::string(relative);
        }
        base += name;
        relative.remove_prefix(end);
        if (!relative.empty()) base += '/', relative.remove_prefix(1);
    }
    return base;
}

enum class Root { None, Game, User };
struct HostPath {
    Root root = Root::None;
    std::string path;
};

/* The host path for a Windows path, and which root it is under. */
static HostPath host_path(std::string_view windows) {
    const std::string full = full_path(windows);
    std::string_view rest = full;
    HostPath host;
    if (strip_folder(rest, "C:\\Game")) host.root = Root::Game;
    else if (strip_folder(rest, "C:\\Users\\Player")) host.root = Root::User;
    else {
        fprintf(stderr, "runtime: path outside the mapped roots: %s\n", full.c_str());
        return host;
    }
    if (!rest.empty()) rest.remove_prefix(1);
    std::string relative(rest);
    /* The game writes diagnostics and screenshots next to itself; keep them in the port's profile. */
    for (const std::string_view writable : {"logs", "measurements", "screenshots"}) {
        std::string_view folder = rest;
        if (host.root != Root::Game || !strip_folder(folder, writable)) continue;
        relative = "Game\\" + relative;
        host.root = Root::User;
    }
    std::replace(relative.begin(), relative.end(), '\\', '/');
    host.path = resolve_case(host.root == Root::Game ? game_dir : user_dir, relative);
    return host;
}

static uint32_t error_of(int e) {
    switch (e) {
    case ENOENT: return 2;            /* ERROR_FILE_NOT_FOUND */
    case ENOTDIR: return 3;           /* ERROR_PATH_NOT_FOUND */
    case EACCES: case EPERM: case EBADF: return 5; /* EBADF: writing a read-only handle */
    case EEXIST: return 183;          /* ERROR_ALREADY_EXISTS */
    case ENOTEMPTY: return 145;
    default: return 31;               /* ERROR_GEN_FAILURE */
    }
}

/* The host path of a guest wide path; sets ERROR_PATH_NOT_FOUND when it is outside the roots. */
static HostPath guest_host_path(const char16_t *windows) {
    HostPath host = host_path(rt_utf8(windows));
    if (host.root == Root::None) rt_set_last_error(3);
    return host;
}

H(GetFullPathNameW) {
    const std::string full = full_path(rt_utf8(P(0)));
    const uint32_t n = rt_put_wide(full, P(2), (uint32_t)A(1));
    if (A(3)) { /* lpFilePart */
        uint16_t *w = P(2), *last = nullptr;
        if (n < (uint32_t)A(1)) for (uint32_t i = 0; i < n; ++i) if (w[i] == '\\') last = &w[i + 1];
        rt_put<uint64_t>(P(3), last && *last ? (uint64_t)(uintptr_t)last : 0);
    }
    return n;
}
H(SetCurrentDirectoryW) {
    const std::string full = full_path(rt_utf8(P(0)));
    const HostPath host = host_path(full);
    struct stat st;
    if (host.root == Root::None || stat(host.path.c_str(), &st) || !S_ISDIR(st.st_mode)) {
        rt_set_last_error(3);
        return 0;
    }
    current_dir = full.back() == '\\' ? full : full + '\\';
    return 1;
}

/* SHGetKnownFolderPath(rfid, flags, token, PWSTR*): every known folder is under the profile. */
H(SHGetKnownFolderPath) {
    static const struct { uint32_t data1; const char *path; } folders[] = {
        {0x3eb685db, USER_ROOT "AppData\\Roaming"},       /* FOLDERID_RoamingAppData */
        {0xf1b32785, USER_ROOT "AppData\\Local"},         /* FOLDERID_LocalAppData */
        {0x4c5c32ff, USER_ROOT "Saved Games"},            /* FOLDERID_SavedGames */
        {0xfdd39ad0, USER_ROOT "Documents"},              /* FOLDERID_Documents */
        {0x5e6c858f, USER_ROOT},                          /* FOLDERID_Profile */
    };
    uint32_t data1;
    memcpy(&data1, P(0), 4);
    for (const auto &folder : folders) {
        if (folder.data1 != data1) continue;
        const std::string host = host_path(folder.path).path;
        if (const std::error_code error = make_directories(host)) rt_fatal("cannot create %s: %s", host.c_str(), error.message().c_str());
        const uint32_t size = rt_put_wide(folder.path, nullptr, 0);
        uint16_t *w = static_cast<uint16_t *>(malloc(size * 2)); /* the caller frees it with CoTaskMemFree */
        rt_put_wide(folder.path, w, size);
        rt_put<uint64_t>(P(3), (uint64_t)(uintptr_t)w);
        return 0;
    }
    fprintf(stderr, "runtime: unknown known folder %08x\n", data1);
    return 0x80070002; /* E_FILE_NOT_FOUND-ish HRESULT */
}

/* ---- file handles ---- */

struct File final : Object {
    static constexpr Kind type = Kind::File;
    explicit File(int fd) : Object(type), fd(fd) {}
    ~File() override { close(fd); }
    const int fd;
};

enum { GENERIC_WRITE = 0x40000000, CREATE_NEW = 1, CREATE_ALWAYS, OPEN_EXISTING, OPEN_ALWAYS, TRUNCATE_EXISTING };
#define INVALID_HANDLE UINT64_MAX

static uint64_t open_file(std::string_view windows_name, uint32_t access, uint32_t disposition) {
    const HostPath host = host_path(windows_name);
    if (host.root == Root::None) { rt_set_last_error(3); return INVALID_HANDLE; }
    const bool write = (access & GENERIC_WRITE) || disposition != OPEN_EXISTING;
    if (write && host.root == Root::Game) {
        fprintf(stderr, "runtime: refused write access in the game folder: %.*s\n", (int)windows_name.size(), windows_name.data());
        rt_set_last_error(5);
        return INVALID_HANDLE;
    }
    int flags = write ? O_RDWR : O_RDONLY;
    switch (disposition) {
    case CREATE_NEW: flags |= O_CREAT | O_EXCL; break;
    case CREATE_ALWAYS: flags |= O_CREAT | O_TRUNC; break;
    case OPEN_ALWAYS: flags |= O_CREAT; break;
    case TRUNCATE_EXISTING: flags |= O_TRUNC; break;
    default: break;
    }
    struct stat st;
    const bool existed = stat(host.path.c_str(), &st) == 0;
    if (existed && S_ISDIR(st.st_mode)) flags = O_RDONLY; /* FILE_FLAG_BACKUP_SEMANTICS directory handles */
    const int fd = open(host.path.c_str(), flags, 0644);
    if (fd < 0) { rt_set_last_error(errno == EEXIST ? 80 : error_of(errno)); return INVALID_HANDLE; } /* ERROR_FILE_EXISTS */
    const uint64_t h = rt_new_handle(std::make_shared<File>(fd));
    /* CREATE_ALWAYS/OPEN_ALWAYS report ERROR_ALREADY_EXISTS when the file was there. */
    rt_set_last_error(existed && (disposition == CREATE_ALWAYS || disposition == OPEN_ALWAYS) ? 183 : 0);
    return h;
}

H(CreateFileW) { return open_file(rt_utf8(P(0)), (uint32_t)A(1), (uint32_t)A(4)); }
H(CreateFileA) { return open_file(static_cast<const char *>(P(0)), (uint32_t)A(1), (uint32_t)A(4)); }

/* CRT FILE values are opaque guest handles, so no host FILE layout is exposed. */
struct Stream final : Object {
    static constexpr Kind type = Kind::Stream;
    Stream(FILE *file, bool text) : Object(type), file(file), text(text) {}
    ~Stream() override { if (file) fclose(file); }
    FILE *file;
    const bool text;
    std::mutex io;
};
static std::atomic<int> file_mode{0x4000}; // _O_TEXT
H(_set_fmode) {
    if (A(0) != 0x4000 && A(0) != 0x8000) return 22;
    file_mode.store((int)A(0));
    return 0;
}
H(_wfopen_s) {
    if (!P(0)) return 22;
    rt_put<uint64_t>(P(0), 0);
    if (!P(1) || !P(2)) return 22;
    const std::u16string_view mode(static_cast<const char16_t *>(P(2)));
    if (mode.empty() || (mode[0] != 'r' && mode[0] != 'w' && mode[0] != 'a')) return 22;
    bool update = false, binary = file_mode.load() == 0x8000, exclusive = false;
    for (size_t i = 1; i < mode.size(); ++i) {
        switch (mode[i]) {
        case '+': update = true; break;
        case 'b': binary = true; break;
        case 't': binary = false; break;
        case 'x': exclusive = true; break;
        case 'c': case 'n': case 'N': case 'S': case 'R': case 'T': case 'D':
            rt_fatal("unsupported CRT stream mode: %s", rt_utf8(mode).c_str());
        default: return 22;
        }
    }
    if (exclusive && mode[0] != 'w') return 22;
    const HostPath host = guest_host_path(P(1));
    if (host.root == Root::None) return 2;
    if (host.root == Root::Game && (mode[0] != 'r' || update)) return 13; // EACCES
    int flags = update ? O_RDWR : O_RDONLY;
    if (mode[0] == 'w') flags = (update ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
    else if (mode[0] == 'a') flags = (update ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
    if (exclusive) flags |= O_EXCL;
    const int fd = open(host.path.c_str(), flags, 0644);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENOTDIR) return 2;
        if (errno == EACCES || errno == EPERM) return 13;
        if (errno == EEXIST) return 17;
        return 5; // EIO
    }
    struct stat info;
    if (fstat(fd, &info) || S_ISDIR(info.st_mode)) { close(fd); return 13; }
    std::string native_mode(1, (char)mode[0]);
    if (update) native_mode += '+';
    FILE *file = fdopen(fd, native_mode.c_str());
    if (!file) { close(fd); return 5; }
    rt_put<uint64_t>(P(0), rt_new_handle(std::make_shared<Stream>(file, !binary)));
    return 0;
}
H(fwrite_) {
    const uint64_t size = A(1), count = A(2);
    if (!size || !count) return 0;
    if (!P(0) || count > SIZE_MAX / size) return 0;
    const auto stream = rt_object<Stream>(A(3));
    if (!stream) return 0;
    std::lock_guard guard(stream->io);
    if (!stream->file) return 0;
    if (!stream->text) return fwrite(P(0), size, count, stream->file);
    const char *source = P(0);
    const size_t bytes = size * count;
    std::string translated;
    for (size_t i = 0; i < bytes; ++i) {
        if (source[i] == '\n') translated += '\r';
        translated += source[i];
    }
    const size_t written = fwrite(translated.data(), 1, translated.size(), stream->file);
    size_t consumed = 0, physical = 0;
    for (; consumed < bytes; ++consumed) {
        physical += source[consumed] == '\n' ? 2 : 1;
        if (physical > written) break;
    }
    return consumed / size;
}
H(fclose_) {
    const auto stream = rt_object<Stream>(A(0));
    if (!stream) return UINT32_MAX;
    int result;
    {
        std::lock_guard guard(stream->io);
        if (!stream->file) return UINT32_MAX;
        result = fclose(stream->file);
        stream->file = nullptr;
    }
    rt_close_handle(A(0));
    return (uint32_t)result;
}

/* ReadFileEx/WriteFileEx(file, buffer, size, OVERLAPPED *, routine) at the OVERLAPPED offset. The
 * transfer finishes before returning; its routine still runs only in this thread's next alertable
 * wait, as on Windows. Failures Windows reports synchronously (EOF included) queue no routine.
 * shortcut: blocking pread/pwrite; move transfers to a worker if Wwise streaming stalls on them. */
static uint64_t transfer_ex(WinCall *c, bool write) {
    const std::shared_ptr<File> f = rt_object<File>(A(0));
    if (!f) { rt_set_last_error(6); return 0; }
    if (!P(3) || !A(4)) { rt_set_last_error(87); return 0; }
    uint8_t *overlapped = P(3);
    uint32_t low, high;
    memcpy(&low, overlapped + 16, 4);
    memcpy(&high, overlapped + 20, 4);
    off_t offset = (off_t)((uint64_t)high << 32 | low);
    if (write && low == UINT32_MAX && high == UINT32_MAX) { /* Windows: append at the end of the file */
        struct stat st;
        if (fstat(f->fd, &st)) { rt_set_last_error(error_of(errno)); return 0; }
        offset = st.st_size;
    }
    const size_t size = (uint32_t)A(2);
    const ssize_t n = write ? pwrite(f->fd, P(1), size, offset) : pread(f->fd, P(1), size, offset);
    if (n < 0) { rt_set_last_error(error_of(errno)); return 0; }
    if (!write && !n && size) { rt_set_last_error(38); return 0; } /* ERROR_HANDLE_EOF */
    rt_put<uint64_t>(overlapped, 0);                               /* Internal: STATUS_SUCCESS */
    rt_put<uint64_t>(overlapped + 8, (uint64_t)n);                 /* InternalHigh: bytes transferred */
    rt_queue_completion(A(4), 0, (uint32_t)n, A(3));
    rt_set_last_error(0);
    return 1;
}
H(ReadFileEx) { return transfer_ex(c, false); }
H(WriteFileEx) { return transfer_ex(c, true); }
H(ReadFile) {
    const std::shared_ptr<File> f = rt_object<File>(A(0));
    if (!f) { rt_set_last_error(6); return 0; }
    if (A(4)) rt_fatal("ReadFile with OVERLAPPED is not implemented");
    const ssize_t n = read(f->fd, P(1), (size_t)(uint32_t)A(2));
    if (n < 0) { rt_set_last_error(error_of(errno)); return 0; }
    if (A(3)) rt_put<uint32_t>(P(3), (uint32_t)n);
    return 1;
}
bool rt_write_handle(uint64_t handle, const void *data, size_t size) {
    const auto file = rt_object<File>(handle);
    if (!file) { rt_set_last_error(6); return false; }
    auto *at = (const uint8_t *)data;
    while (size) {
        const ssize_t written = write(file->fd, at, size);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { rt_set_last_error(error_of(errno)); return false; }
        at += written;
        size -= (size_t)written;
    }
    return true;
}

H(WriteFile) {
    const std::shared_ptr<File> f = rt_object<File>(A(0));
    if (!f) { rt_set_last_error(6); return 0; }
    if (A(4)) rt_fatal("WriteFile with OVERLAPPED is not implemented");
    const ssize_t n = write(f->fd, P(1), (size_t)(uint32_t)A(2));
    if (n < 0) { rt_set_last_error(error_of(errno)); return 0; }
    if (A(3)) rt_put<uint32_t>(P(3), (uint32_t)n);
    return 1;
}
H(SetFilePointerEx) {
    const std::shared_ptr<File> f = rt_object<File>(A(0));
    if (!f) { rt_set_last_error(6); return 0; }
    const off_t at = lseek(f->fd, (off_t)A(1), (int)A(3)); /* FILE_BEGIN/CURRENT/END = SEEK_SET/CUR/END */
    if (at < 0) { rt_set_last_error(131); return 0; }
    if (A(2)) rt_put<int64_t>(P(2), at);
    return 1;
}
/* fstat of a file handle's descriptor; sets ERROR_INVALID_HANDLE on failure. */
static bool stat_handle(uint64_t handle, struct stat &st) {
    const std::shared_ptr<File> f = rt_object<File>(handle);
    if (f && fstat(f->fd, &st) == 0) return true;
    rt_set_last_error(6);
    return false;
}
H(GetFileSizeEx) {
    struct stat st;
    if (!stat_handle(A(0), st)) return 0;
    rt_put<int64_t>(P(1), st.st_size);
    return 1;
}
H(GetFileSize) {
    struct stat st;
    if (!stat_handle(A(0), st)) return 0xffffffff;
    if (A(1)) rt_put<uint32_t>(P(1), (uint32_t)((uint64_t)st.st_size >> 32));
    return (uint32_t)st.st_size;
}
static uint64_t filetime(struct timespec t) {
    return ((uint64_t)t.tv_sec + UINT64_C(11644473600)) * 10000000 + (uint64_t)t.tv_nsec / 100;
}
H(GetFileTime) {
    struct stat st;
    if (!stat_handle(A(0), st)) return 0;
    if (A(1)) rt_put<uint64_t>(P(1), filetime(st.st_birthtimespec));
    if (A(2)) rt_put<uint64_t>(P(2), filetime(st.st_atimespec));
    if (A(3)) rt_put<uint64_t>(P(3), filetime(st.st_mtimespec));
    return 1;
}
H(FlushFileBuffers) { const std::shared_ptr<File> f = rt_object<File>(A(0)); return f && fsync(f->fd) == 0; }

enum { FILE_ATTRIBUTE_READONLY = 1, FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_NORMAL = 0x80 };
H(GetFileAttributesW) {
    const HostPath host = guest_host_path(P(0));
    struct stat st;
    if (host.root == Root::None) return 0xffffffff;
    if (stat(host.path.c_str(), &st)) { rt_set_last_error(error_of(errno)); return 0xffffffff; }
    return S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
}
H(CreateDirectoryW) {
    const HostPath host = guest_host_path(P(0));
    if (host.root == Root::None) return 0;
    if (host.root == Root::Game) { rt_set_last_error(5); return 0; }
    if (mkdir(host.path.c_str(), 0755)) { rt_set_last_error(error_of(errno)); return 0; }
    return 1;
}
H(DeleteFileW) {
    const HostPath host = guest_host_path(P(0));
    if (host.root == Root::None) return 0;
    if (host.root == Root::Game) { rt_set_last_error(5); return 0; }
    if (unlink(host.path.c_str())) { rt_set_last_error(error_of(errno)); return 0; }
    return 1;
}
H(MoveFileW) {
    const HostPath from = guest_host_path(P(0));
    if (from.root == Root::None) return 0;
    const HostPath to = guest_host_path(P(1));
    if (to.root == Root::None) return 0;
    if (from.root == Root::Game || to.root == Root::Game) { rt_set_last_error(5); return 0; }
    struct stat st;
    if (!stat(to.path.c_str(), &st)) { rt_set_last_error(183); return 0; }
    if (rename(from.path.c_str(), to.path.c_str())) { rt_set_last_error(error_of(errno)); return 0; }
    return 1;
}
/* ReplaceFileW(replaced, replacement, backup, ...). Both files must exist; on any failure the
 * replaced file keeps its name (a save is never left missing). */
enum { ERROR_UNABLE_TO_REMOVE_REPLACED = 1175, ERROR_UNABLE_TO_MOVE_REPLACEMENT = 1176 };
H(ReplaceFileW) {
    const HostPath replaced = guest_host_path(P(0));
    if (replaced.root == Root::None) return 0;
    const HostPath replacement = guest_host_path(P(1));
    if (replacement.root == Root::None) return 0;
    HostPath backup{Root::User, {}};
    if (A(2) && (backup = guest_host_path(P(2))).root == Root::None) return 0;
    if (replaced.root == Root::Game || replacement.root == Root::Game || backup.root == Root::Game) { rt_set_last_error(5); return 0; }
    struct stat st;
    if (stat(replaced.path.c_str(), &st)) { rt_set_last_error(error_of(errno)); return 0; }
    if (stat(replacement.path.c_str(), &st)) { rt_set_last_error(ERROR_UNABLE_TO_MOVE_REPLACEMENT); return 0; }
    if (A(2) && rename(replaced.path.c_str(), backup.path.c_str())) { rt_set_last_error(ERROR_UNABLE_TO_REMOVE_REPLACED); return 0; }
    if (rename(replacement.path.c_str(), replaced.path.c_str())) {
        if (A(2) && rename(backup.path.c_str(), replaced.path.c_str()))
            rt_fatal("ReplaceFileW: cannot restore %s from %s", replaced.path.c_str(), backup.path.c_str());
        rt_set_last_error(ERROR_UNABLE_TO_MOVE_REPLACEMENT);
        return 0;
    }
    return 1;
}

/* SHFileOperationW(SHFILEOPSTRUCTW *). The game only deletes folders (FO_DELETE), without UI; pFrom
 * is a list of names ending in an empty one. Returns 0 or an error code. */
H(SHFileOperationW) {
    uint8_t *op = P(0);
    uint32_t function;
    uint64_t from;
    memcpy(&function, op + 8, 4);
    memcpy(&from, op + 16, 8);
    if (function != 3) rt_fatal("SHFileOperationW function %u is not implemented", function);
    rt_put<uint32_t>(op + 36, 0); /* fAnyOperationsAborted */
    for (const char16_t *name = (const char16_t *)(uintptr_t)from; *name; name += std::char_traits<char16_t>::length(name) + 1) {
        const std::string windows = rt_utf8(name);
        if (windows.find_first_of("*?") != std::string::npos) rt_fatal("SHFileOperationW wildcards are not implemented: %s", windows.c_str());
        const HostPath host = host_path(windows);
        if (host.root == Root::None) return 3;
        if (host.root == Root::Game) return 5; /* destructive calls stay inside the port's own folders */
        struct stat st;
        if (lstat(host.path.c_str(), &st)) return error_of(errno);
        std::error_code error;
        std::filesystem::remove_all(host.path, error);
        if (error) return error_of(error.value());
    }
    return 0;
}

/* ---- directory search: FindFirstFileExW (FindExInfoBasic/Standard) ---- */

struct Find final : Object {
    static constexpr Kind type = Kind::Find;
    Find(DIR *dir, std::string directory, std::string pattern)
        : Object(type), dir(dir), directory(std::move(directory)), pattern(std::move(pattern)) {}
    ~Find() override { closedir(dir); }
    DIR *const dir;
    const std::string directory, pattern;
};

/* WIN32_FIND_DATAW (592 bytes) from the next matching entry; false at the end. */
static bool next_match(const Find &f, uint8_t *out) {
    for (struct dirent *e; (e = readdir(f.dir));) {
        if (fnmatch(f.pattern.c_str(), e->d_name, FNM_CASEFOLD)) continue;
        struct stat st;
        if (stat((f.directory + '/' + e->d_name).c_str(), &st)) continue;
        memset(out, 0, 592);
        rt_put<uint32_t>(out, S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL);
        rt_put<uint64_t>(out + 4, filetime(st.st_birthtimespec));
        rt_put<uint64_t>(out + 12, filetime(st.st_atimespec));
        rt_put<uint64_t>(out + 20, filetime(st.st_mtimespec));
        rt_put<uint32_t>(out + 28, (uint32_t)((uint64_t)st.st_size >> 32));
        rt_put<uint32_t>(out + 32, (uint32_t)st.st_size);
        rt_put_wide(e->d_name, reinterpret_cast<uint16_t *>(out + 44), 260);
        return true;
    }
    return false;
}

H(FindFirstFileExW) {
    const HostPath host = guest_host_path(P(0));
    if (host.root == Root::None) return INVALID_HANDLE;
    const size_t slash = host.path.rfind('/');
    std::string directory = host.path.substr(0, slash), pattern = host.path.substr(slash + 1);
    if (pattern == "*.*") pattern = "*";
    DIR *dir = opendir(directory.c_str());
    if (!dir) { rt_set_last_error(3); return INVALID_HANDLE; }
    auto find = std::make_shared<Find>(dir, std::move(directory), std::move(pattern));
    if (!next_match(*find, P(2))) { rt_set_last_error(2); return INVALID_HANDLE; }
    return rt_new_handle(std::move(find));
}
H(FindNextFileW) {
    const std::shared_ptr<Find> find = rt_object<Find>(A(0));
    if (!find) { rt_set_last_error(6); return 0; }
    if (!next_match(*find, P(1))) { rt_set_last_error(18); return 0; } /* ERROR_NO_MORE_FILES */
    return 1;
}
H(FindClose) { return rt_close_handle(A(0)); }

/* ---- file mappings (read-only views of files) ---- */

struct Mapping final : Object {
    static constexpr Kind type = Kind::Mapping;
    Mapping(int fd, uint64_t size) : Object(type), fd(fd), size(size) {}
    ~Mapping() override { close(fd); }
    const int fd; /* its own descriptor: the mapping outlives its file handle, as on Windows */
    const uint64_t size;
};

/* CreateFileMapping(file, attributes, protect, size high, size low, name). */
static uint64_t create_mapping(WinCall *c) {
    if (A(0) == INVALID_HANDLE) rt_fatal("CreateFileMapping without a file is not implemented");
    if (A(5)) rt_fatal("named file mappings are not implemented");
    if ((uint32_t)A(2) != 2) rt_fatal("CreateFileMapping with protection %#x is not implemented", (uint32_t)A(2)); /* PAGE_READONLY */
    struct stat st;
    if (!stat_handle(A(0), st)) return 0;
    const uint64_t size = A(3) << 32 | (uint32_t)A(4);
    if (!size && !st.st_size) { rt_set_last_error(1006); return 0; }         /* ERROR_FILE_INVALID */
    if (size > (uint64_t)st.st_size) { rt_set_last_error(8); return 0; }     /* a read-only file cannot grow */
    const int fd = dup(rt_object<File>(A(0))->fd);
    if (fd < 0) { rt_set_last_error(error_of(errno)); return 0; }
    rt_set_last_error(0);
    return rt_new_handle(std::make_shared<Mapping>(fd, size ? size : (uint64_t)st.st_size));
}
H(CreateFileMappingW) { return create_mapping(c); }
H(CreateFileMappingA) { return create_mapping(c); }

static std::mutex views_lock;
static std::map<uint64_t, size_t> views; /* view address -> length, for UnmapViewOfFile */

/* MapViewOfFile(mapping, access, offset high, offset low, bytes); 0 bytes maps to the end. */
H(MapViewOfFile) {
    const std::shared_ptr<Mapping> m = rt_object<Mapping>(A(0));
    if (!m) { rt_set_last_error(6); return 0; }
    const uint64_t offset = A(2) << 32 | (uint32_t)A(3);
    if ((uint32_t)A(1) != 4) { rt_set_last_error(5); return 0; }            /* only FILE_MAP_READ on a read-only mapping */
    if (offset % 0x10000) { rt_set_last_error(1132); return 0; }           /* ERROR_MAPPED_ALIGNMENT */
    if (offset >= m->size || A(4) > m->size - offset) { rt_set_last_error(5); return 0; }
    const size_t size = A(4) ? A(4) : m->size - offset;
    void *p = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, m->fd, (off_t)offset);
    if (p == MAP_FAILED) { rt_set_last_error(8); return 0; }
    std::lock_guard hold(views_lock);
    views[(uint64_t)(uintptr_t)p] = size;
    return (uint64_t)(uintptr_t)p;
}
H(UnmapViewOfFile) {
    std::lock_guard hold(views_lock);
    const auto view = views.find(A(0));
    if (view == views.end()) { rt_set_last_error(487); return 0; }          /* ERROR_INVALID_ADDRESS */
    munmap((void *)(uintptr_t)view->first, view->second);
    views.erase(view);
    return 1;
}

#define E(name) {#name, name}
const RtEntry rt_file_entries[] = {
    E(_wfopen_s), E(_set_fmode), {"fwrite", fwrite_}, {"fclose", fclose_},
    E(GetFullPathNameW), E(SetCurrentDirectoryW), E(SHGetKnownFolderPath),
    E(CreateFileW), E(CreateFileA), E(ReadFile), E(ReadFileEx), E(WriteFile), E(WriteFileEx),
    E(SetFilePointerEx), E(GetFileSizeEx), E(GetFileSize), E(GetFileTime), E(FlushFileBuffers),
    E(GetFileAttributesW), E(CreateDirectoryW), E(DeleteFileW), E(MoveFileW), E(ReplaceFileW),
    E(SHFileOperationW), E(FindFirstFileExW), E(FindNextFileW), E(FindClose), E(CreateFileMappingW), E(CreateFileMappingA),
    E(MapViewOfFile), E(UnmapViewOfFile),
    {nullptr, nullptr},
};
