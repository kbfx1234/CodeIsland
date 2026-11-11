// A stand-in ancestor for BridgeGoldenTests (Tests/CodeIslandCoreTests/
// BridgeGoldenHarness.swift), which copies it to the paths a fixture names
// so that codeisland-bridge reads the process tree the fixture describes.
// Built with the package, so the golden comparison needs no compiler of its
// own. Never shipped.
//
// It logs its pid and path (GOLDEN_STUB_PIDS), leaves the controlling
// terminal (so the bridge finds no tty), runs everything after its first `--`
// as a child and exits with the child's status.
#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *log = getenv("GOLDEN_STUB_PIDS");
    if (log) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        proc_pidpath(getpid(), path, sizeof path);
        FILE *f = fopen(log, "a");
        if (f) { fprintf(f, "%d\t%s\n", getpid(), path); fclose(f); }
    }
    setsid();
    int i = 1;
    while (i < argc && strcmp(argv[i], "--") != 0) i++;
    if (i + 1 >= argc) return 127;
    pid_t child = fork();
    if (child < 0) return 127;
    if (child == 0) { execv(argv[i + 1], &argv[i + 1]); _exit(127); }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 127; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
