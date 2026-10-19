/* POSIX command supervisor; no Lua headers or library are required.
 * Author: WaterRun
 * File: posix_host.c
 * Date: 2026-10-12
 * Updated: 2026-10-19
 * Keep src/posix_host_source.lua synchronized with this file.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#ifdef __linux__
#include <sys/syscall.h>
#ifdef SYS_renameat2
extern long syscall(long number, ...);
#endif
#endif

static volatile sig_atomic_t interrupted;

static void signal_received(int signal_number)
{
    interrupted = signal_number;
}

static int number(const char *value, uint64_t *output)
{
    char *end;
    unsigned long long parsed;
    if (!value || !*value || strspn(value, "0123456789") != strlen(value)) return 0;
    errno = 0;
    parsed = strtoull(value, &end, 10);
    if (errno || *end) return 0;
    *output = (uint64_t)parsed;
    return 1;
}

static uint64_t milliseconds(void)
{
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC, &stamp) != 0) return UINT64_MAX;
    return (uint64_t)stamp.tv_sec * 1000 + (uint64_t)stamp.tv_nsec / 1000000;
}

static int write_all(int descriptor, const void *data, size_t size)
{
    const char *bytes = (const char *)data;
    while (size) {
        ssize_t written = write(descriptor, bytes, size);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 0;
        bytes += written;
        size -= (size_t)written;
    }
    return 1;
}

static int finish(const char *token, int code, const char *reason)
{
    char record[256];
    int length = snprintf(record, sizeof(record), "\n%s:%d:%s\n", token, code, reason);
    if (length < 0 || (size_t)length >= sizeof(record)
        || !write_all(STDOUT_FILENO, record, (size_t)length)) return 126;
    return code;
}

static int supervise(int argc, char **argv)
{
    uint64_t timeout, limit, env_count, started, stopping = 0, total = 0;
    int pipe_descriptors[2], index, code = 0, closed = 0, child_exited = 0, quiet_checks = 0;
    pid_t child, owner = getppid();
    const char *reason = "exit", *token, *directory = NULL;
    struct sigaction action;
    siginfo_t state;
    struct pollfd event;
    if (argc < 7 || !number(argv[2], &timeout) || !timeout || timeout > 86400000
        || !number(argv[3], &limit) || !limit || limit > 1073741824
        || !number(argv[5], &env_count) || env_count > 4096
        || env_count > (uint64_t)(argc - 7) / 2) return 127;
    token = argv[4];
    if (strlen(token) > 120 || strspn(token, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        != strlen(token)) return 127;
    {
        char record[192];
        int length = snprintf(record, sizeof(record), "%s:PID:%ld\n", token, (long)getpid());
        if (length < 0 || (size_t)length >= sizeof(record)
            || !write_all(STDOUT_FILENO, record, (size_t)length)) return 126;
    }
    /* Survive SIGKILL of the caller's group so owner death still cleans up the
     * command group. Lua relays an interrupted read to this reserved child PID. */
    if (setpgid(0, 0)) return finish(token, 125, "supervisor-error");
    index = 6 + (int)env_count * 2;
    if (!strcmp(argv[index], "--cwd")) {
        if (index + 3 >= argc || !argv[index + 1][0]) return 127;
        directory = argv[index + 1];
        index += 2;
    }
    if (strcmp(argv[index], "--") || index + 1 >= argc) return 127;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = signal_received;
    if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)
        || sigaction(SIGHUP, &action, NULL) || sigaction(SIGQUIT, &action, NULL))
        return finish(token, 125, "supervisor-error");
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, NULL)) return finish(token, 125, "supervisor-error");
    action.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &action, NULL)) return finish(token, 125, "supervisor-error");
    {
        sigset_t signals;
        sigemptyset(&signals);
        sigaddset(&signals, SIGINT); sigaddset(&signals, SIGTERM);
        sigaddset(&signals, SIGHUP); sigaddset(&signals, SIGQUIT);
        sigaddset(&signals, SIGCHLD);
        if (sigprocmask(SIG_UNBLOCK, &signals, NULL)) return finish(token, 125, "supervisor-error");
    }
    started = milliseconds();
    if (started == UINT64_MAX || pipe(pipe_descriptors))
        return finish(token, 125, "supervisor-error");
    child = fork();
    if (child == -1) {
        close(pipe_descriptors[0]); close(pipe_descriptors[1]);
        return finish(token, 125, "supervisor-error");
    }
    if (!child) {
        uint64_t position;
        action.sa_handler = SIG_DFL;
        sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
        sigaction(SIGHUP, &action, NULL); sigaction(SIGQUIT, &action, NULL);
        sigaction(SIGPIPE, &action, NULL);
        close(pipe_descriptors[0]);
        if (setpgid(0, 0) || dup2(pipe_descriptors[1], STDOUT_FILENO) == -1
            || dup2(pipe_descriptors[1], STDERR_FILENO) == -1) _exit(126);
        if (pipe_descriptors[1] > STDERR_FILENO) close(pipe_descriptors[1]);
        for (position = 0; position < env_count; ++position) {
            if (setenv(argv[6 + position * 2], argv[7 + position * 2], 1)) _exit(126);
        }
        if (directory && chdir(directory)) {
            perror("luainstaller: command directory");
            _exit(126);
        }
        execvp(argv[index + 1], argv + index + 1);
        perror("luainstaller: start command");
        _exit(errno == ENOENT ? 127 : 126);
    }
    close(pipe_descriptors[1]);
    /* Both sides establish the group before any timeout or signal can target it. */
    if (setpgid(child, child) && errno != EACCES && errno != ESRCH) interrupted = SIGTERM;
    event.fd = pipe_descriptors[0]; event.events = POLLIN | POLLHUP;
    if (fcntl(event.fd, F_SETFL, O_NONBLOCK) == -1) interrupted = SIGTERM;
    while (!closed || !child_exited) {
        uint64_t now = milliseconds();
        if (!stopping) {
            if (getppid() != owner) { code = 126; reason = "owner-exit"; }
            else if (interrupted) { code = 128 + interrupted; reason = "signal"; }
            else if (now == UINT64_MAX) { code = 125; reason = "supervisor-error"; }
            else if (now - started >= timeout) { code = 124; reason = "timeout"; }
            if (code) {
                stopping = now == UINT64_MAX ? started + timeout : now;
                kill(-child, interrupted ? interrupted : SIGTERM);
            }
        }
        if (stopping && (now == UINT64_MAX || now - stopping >= 1000)) {
            kill(-child, SIGKILL);
            break;
        }
        if (!closed) {
            int polled = poll(&event, 1, 20);
            if (polled < 0 && errno != EINTR) { code = 125; reason = "supervisor-error"; break; }
            if (polled > 0) {
                char bytes[16384];
                ssize_t count = read(event.fd, bytes, sizeof(bytes));
                if (count == 0) closed = 1;
                else if (count > 0) {
                    size_t accepted = (size_t)count;
                    if (accepted > limit - total) accepted = (size_t)(limit - total);
                    if (accepted && !write_all(STDOUT_FILENO, bytes, accepted)) {
                        code = 126; reason = "owner-exit"; break;
                    }
                    total += accepted;
                    if (accepted < (size_t)count && !stopping) {
                        code = 125; reason = "output-limit"; stopping = now;
                        kill(-child, SIGTERM);
                    }
                } else if (errno != EAGAIN && errno != EINTR) {
                    code = 125; reason = "supervisor-error"; break;
                }
            }
        } else {
            struct timespec pause = {0, quiet_checks++ < 20 ? 1000000 : 20000000};
            nanosleep(&pause, NULL);
        }
        memset(&state, 0, sizeof(state));
        /* WNOWAIT keeps the original child PID reserved until group cleanup. */
        if (waitid(P_PID, (id_t)child, &state, WEXITED | WNOHANG | WNOWAIT) == 0 && state.si_pid) {
            child_exited = 1;
            if (!code) code = state.si_code == CLD_EXITED ? state.si_status : 128 + state.si_status;
        }
    }
    kill(-child, SIGKILL);
    close(event.fd);
    /* A command stuck in kernel I/O must not make the caller's deadline unbounded. */
    {
        unsigned int attempts;
        for (attempts = 0; attempts < 100; ++attempts) {
            int waited;
            struct timespec pause = {0, 10000000};
            pid_t result = waitpid(child, &waited, WNOHANG);
            if (result == child || (result == -1 && errno == ECHILD)) break;
            if (result == -1 && errno != EINTR) break;
            nanosleep(&pause, NULL);
        }
    }
    return finish(token, code, reason);
}

static int administrator(uid_t uid)
{
#ifdef __ANDROID__
    /* AOSP AID_SYSTEM owns protected app-data ancestors. */
    if (uid == 1000) return 1;
#endif
    return uid == 0;
}

static int administrator_group(gid_t gid)
{
#ifdef __ANDROID__
    if (gid == 1000) return 1;
#endif
    return gid == 0;
}

static int trusted_directory(const char *path, struct stat *info, int allow_link)
{
    struct stat link_info;
    errno = 0;
    if (lstat(path, info)) return 0;
    if (S_ISLNK(info->st_mode)) {
        char *resolved;
        size_t index;
        link_info = *info;
        int system_link = strchr(path + 1, '/') == NULL;
#ifdef __ANDROID__
        if (!strcmp(path, "/data/user/0")) system_link = 1;
#endif
        if (!allow_link || !administrator(link_info.st_uid) || !system_link
            || stat(path, info) || !administrator(info->st_uid)) { errno = EPERM; return 0; }
        resolved = realpath(path, NULL);
        if (!resolved) return 0;
        for (index = 1; resolved[index]; ++index) {
            struct stat ancestor;
            if (resolved[index] != '/') continue;
            resolved[index] = 0;
            if (!trusted_directory(resolved, &ancestor, 0)) { free(resolved); return 0; }
            resolved[index] = '/';
        }
        free(resolved);
    }
    if (!S_ISDIR(info->st_mode) || (!administrator(info->st_uid) && info->st_uid != getuid())) { errno = EPERM; return 0; }
    if (!(info->st_mode & S_ISVTX) && ((info->st_mode & 0002)
        || ((info->st_mode & 0020) && !administrator_group(info->st_gid)))) { errno = EPERM; return 0; }
    return 1;
}

static int output_parents(const char *value)
{
    char *path;
    size_t index, length;
    struct stat info;
    if (!value || value[0] != '/' || !value[1]) return 1;
    length = strlen(value);
    if (length > 32768) return 1;
    path = (char *)malloc(length + 1);
    if (!path) return 1;
    memcpy(path, value, length + 1);
    for (index = 1; index <= length; ++index) {
        char saved;
        if (index != 1 && path[index] != '/') continue;
        saved = path[index]; path[index] = 0;
        if (index == 1) { path[0] = '/'; path[1] = 0; }
        if (!trusted_directory(path, &info, 1)) {
            int missing = errno == ENOENT;
            if (!missing) fprintf(stderr, "luainstaller: unsafe output ancestor: %s\n", path);
            free(path); return missing ? 0 : 1;
        }
        if (printf("%ju:%ju:%ju:%jo\n", (uintmax_t)info.st_dev, (uintmax_t)info.st_ino,
            (uintmax_t)info.st_uid, (uintmax_t)info.st_mode) < 0) { free(path); return 1; }
        path[index] = saved;
    }
    if (lstat(value, &info) == 0 && S_ISDIR(info.st_mode)
        && !trusted_directory(value, &info, 0)) {
        fprintf(stderr, "luainstaller: unsafe output directory: %s\n", value);
        free(path); return 1;
    }
    free(path);
    return 0;
}

static int progress(int argc, char **argv)
{
    static const char frames[] = "|/-\\";
    pid_t owner;
    struct sigaction action;
    struct pollfd input;
    uint64_t next_frame = 0;
    uint64_t owner_number;
    unsigned int frame = 0;
    int output = STDERR_FILENO, result = 0;
    char line[4200];
    size_t label_size;
    if ((argc != 4 && argc != 5) || !number(argv[2], &owner_number)
        || !owner_number || owner_number > INT_MAX) return 127;
    owner = (pid_t)owner_number;
    if (getppid() != owner) return 0;
    label_size = strlen(argv[3]);
    if (label_size > 4096) return 127;
    if (argc == 5) {
        output = open(argv[4], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (output < 0) return 1;
    } else {
        const char *terminal;
        struct stat original, opened;
        if (!isatty(output) || fstat(output, &original)) return 1;
        terminal = ttyname(output);
        if (!terminal) return 1;
        output = open(terminal, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW);
        if (output < 0) return 1;
        if (fstat(output, &opened) || !S_ISCHR(opened.st_mode)
            || opened.st_rdev != original.st_rdev) { close(output); return 1; }
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = signal_received;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)
        || sigaction(SIGHUP, &action, NULL) || sigaction(SIGQUIT, &action, NULL)) {
        if (output != STDERR_FILENO) close(output);
        return 1;
    }
    signal(SIGPIPE, SIG_IGN);
    input.fd = STDIN_FILENO;
    input.events = POLLIN;
    while (!interrupted && getppid() == owner) {
        uint64_t now = milliseconds();
        int timeout, ready;
        if (now == UINT64_MAX) { result = 1; break; }
        if (now >= next_frame) {
            struct winsize viewport;
            const char *label = argv[3];
            int columns = 80, length;
            if (argc == 4 && ioctl(output, TIOCGWINSZ, &viewport) == 0 && viewport.ws_col)
                columns = viewport.ws_col;
            if (label_size + 4 >= (size_t)columns) label = "";
            length = columns > 4
                ? snprintf(line, sizeof(line), "\r\033[2K[%c] %s", frames[frame++ % 4], label)
                : snprintf(line, sizeof(line), "\r\033[2K");
            if (length < 0 || (size_t)length >= sizeof(line)
                || !write_all(output, line, (size_t)length)) { result = 1; break; }
            next_frame = now + 100;
        }
        timeout = next_frame > now ? (int)(next_frame - now) : 0;
        if (timeout > 100) timeout = 100;
        input.revents = 0;
        ready = poll(&input, 1, timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            result = 1; break;
        }
        if (input.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
        if (input.revents & POLLIN) {
            char data[128];
            ssize_t count = read(STDIN_FILENO, data, sizeof(data));
            if (count <= 0) break;
        }
    }
    if (!write_all(output, "\r\033[2K", 5)) result = 1;
    if (output != STDERR_FILENO && close(output)) result = 1;
    return result;
}

static int publish_file(const char *source, const char *destination)
{
    struct stat info;
    if (lstat(source, &info) || !S_ISREG(info.st_mode)) {
        fputs("publication source is not a regular file\n", stderr); return 1;
    }
#if defined(__linux__) && defined(SYS_renameat2)
    /* Android app storage can refuse hard links. RENAME_NOREPLACE supplies the
     * same atomic guarantee and doesn't overwrite an output created in a race. */
    if (syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, 1u) == 0) return 0;
    if (errno == EEXIST) { fputs("destination already exists\n", stderr); return 1; }
#endif
    if (link(source, destination) == 0) return 0;
    fprintf(stderr, "atomic file publication failed: %s\n", strerror(errno));
    return 1;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "publish_file")) return publish_file(argv[2], argv[3]);
    if (argc > 1 && !strcmp(argv[1], "progress")) return progress(argc, argv);
    if (argc > 1 && !strcmp(argv[1], "exec")) return supervise(argc, argv);
    if (argc == 3 && !strcmp(argv[1], "output_parents")) return output_parents(argv[2]);
    if (argc == 3 && !strcmp(argv[1], "file_size")) {
        struct stat info;
        if (lstat(argv[2], &info) || !S_ISREG(info.st_mode) || info.st_size < 0) return 1;
        return printf("%ju", (uintmax_t)info.st_size) < 0 ? 1 : 0;
    }
    return 127;
}
