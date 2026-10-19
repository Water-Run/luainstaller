/* A live pipe outlasts the killed owner: progress must follow owner identity. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static void delay(void)
{
    struct timespec duration = {0, 50000000};
    nanosleep(&duration, NULL);
}

static off_t file_size(const char *path)
{
    struct stat info;
    return stat(path, &info) == 0 ? info.st_size : 0;
}

static pid_t renderer(const char *binary, const char *sink, int *control)
{
    int descriptors[2];
    pid_t child;
    char owner[64];
    if (pipe(descriptors)) return -1;
    snprintf(owner, sizeof(owner), "%ld", (long)getpid());
    child = fork();
    if (child == 0) {
        close(descriptors[1]);
        if (dup2(descriptors[0], STDIN_FILENO) < 0) _exit(120);
        close(descriptors[0]);
        execl(binary, binary, "progress", owner, "owner-lifecycle", sink, (char *)NULL);
        _exit(121);
    }
    close(descriptors[0]);
    if (child < 0) { close(descriptors[1]); return -1; }
    *control = descriptors[1];
    return child;
}

static int terminal_progress(const char *binary)
{
    int master, terminal, descriptors[2], index, status = 0, flags;
    pid_t child;
    struct winsize viewport;
    char owner[64], capture[4096];
    size_t length = 0;
    master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) || unlockpt(master)) {
        fprintf(stderr, "cannot allocate PTY: %s\n", strerror(errno)); return 0;
    }
    if (fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) < 0) return 0;
    terminal = open(ptsname(master), O_RDWR | O_NOCTTY);
    if (terminal < 0 || pipe(descriptors)) {
        fprintf(stderr, "cannot open PTY: %s\n", strerror(errno)); close(master); return 0;
    }
    memset(&viewport, 0, sizeof(viewport)); viewport.ws_row = 20; viewport.ws_col = 8;
    if (ioctl(terminal, TIOCSWINSZ, &viewport)) {
        fprintf(stderr, "cannot size PTY: %s\n", strerror(errno)); return 0;
    }
    flags = fcntl(terminal, F_GETFL);
    snprintf(owner, sizeof(owner), "%ld", (long)getpid());
    child = fork();
    if (child == 0) {
        close(master); close(descriptors[1]);
        if (dup2(terminal, STDERR_FILENO) < 0 || dup2(descriptors[0], STDIN_FILENO) < 0) _exit(120);
        close(terminal); close(descriptors[0]);
        execl(binary, binary, "progress", owner, "too-wide-label", (char *)NULL);
        _exit(121);
    }
    close(descriptors[0]);
    if (child < 0) { close(descriptors[1]); close(terminal); close(master); return 0; }
    for (index = 0; index < 12; ++index) {
        ssize_t count = read(master, capture + length, sizeof(capture) - length - 1);
        if (count > 0) length += (size_t)count;
        delay();
    }
    close(descriptors[1]);
    for (index = 0; index < 80; ++index) {
        if (waitpid(child, &status, WNOHANG) == child) break;
        delay();
    }
    if (index == 80) { kill(child, SIGKILL); waitpid(child, &status, 0); }
    capture[length] = 0;
    if (index == 80 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fprintf(stderr, "PTY child status=%d; wait=%d; bytes=%lu\n", status, index, (unsigned long)length);
    status = index < 80 && WIFEXITED(status) && WEXITSTATUS(status) == 0
        && flags == fcntl(terminal, F_GETFL) && strstr(capture, "[|]")
        && strstr(capture, "[/]") && !strstr(capture, "too-wide-label");
    if (!status) fprintf(stderr, "PTY frame check: bytes=%lu; flags=%d/%d; first=%d second=%d label=%d\n",
        (unsigned long)length, flags, fcntl(terminal, F_GETFL), strstr(capture, "[|]") != NULL,
        strstr(capture, "[/]") != NULL, strstr(capture, "too-wide-label") != NULL);
    close(terminal); close(master);
    return status;
}

int main(int argc, char **argv)
{
    pid_t child, owner, parent = getpid();
    int control, inherited[2], index, status, ready = 0;
    off_t settled;
    if (argc != 4) return 2;
    child = renderer(argv[1], argv[2], &control);
    if (child < 0) return 3;
    for (index = 0; index < 80; ++index) {
        if (file_size(argv[2]) > 40) { ready = 1; break; }
        delay();
    }
    close(control);
    for (index = 0; index < 80; ++index) {
        if (waitpid(child, &status, WNOHANG) == child) break;
        delay();
    }
    if (index == 80) { kill(child, SIGKILL); waitpid(child, &status, 0); return 4; }
    if (!ready || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 5;
    if (!terminal_progress(argv[1])) return 9;

    /* The fixture retains a write end so EOF cannot mask a missing owner check. */
    if (pipe(inherited)) return 6;
    owner = fork();
    if (owner == 0) {
        pid_t helper;
        char owner_text[64];
        if (setpgid(0, 0)) _exit(122);
        snprintf(owner_text, sizeof(owner_text), "%ld", (long)getpid());
        helper = fork();
        if (helper == 0) {
            close(inherited[1]);
            if (dup2(inherited[0], STDIN_FILENO) < 0) _exit(123);
            close(inherited[0]);
            execl(argv[1], argv[1], "progress", owner_text, "killed-owner", argv[3], (char *)NULL);
            _exit(124);
        }
        close(inherited[0]); close(inherited[1]);
        if (helper < 0) _exit(125);
        while (getppid() == parent) delay();
        kill(helper, SIGTERM);
        waitpid(helper, &status, 0);
        _exit(0);
    }
    close(inherited[0]);
    if (owner < 0) { close(inherited[1]); return 7; }
    ready = 0;
    for (index = 0; index < 80; ++index) {
        if (file_size(argv[3]) > 40) { ready = 1; break; }
        delay();
    }
    kill(owner, SIGKILL);
    for (index = 0; index < 10; ++index) delay();
    settled = file_size(argv[3]);
    for (index = 0; index < 8; ++index) delay();
    status = ready && settled == file_size(argv[3]);
    /* Keep the owner unreaped until cleanup: its PID reserves the process group. */
    kill(-owner, SIGKILL);
    waitpid(owner, NULL, 0);
    close(inherited[1]);
    if (!status) return 8;
    puts("progress stops after EOF and owner death");
    return 0;
}
