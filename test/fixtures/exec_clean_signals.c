#define _POSIX_C_SOURCE 200809L

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    struct sigaction action;
    int signals[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT };
    size_t index;
    if (argc < 2) return 2;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    if (sigemptyset(&action.sa_mask) != 0) return 3;
    for (index = 0; index < sizeof(signals) / sizeof(signals[0]); ++index) {
        if (sigaction(signals[index], &action, NULL) != 0) return 4;
    }
    if (setpgid(0, 0) != 0) return 5;
    execv(argv[1], argv + 1);
    perror("execv");
    return 127;
}
