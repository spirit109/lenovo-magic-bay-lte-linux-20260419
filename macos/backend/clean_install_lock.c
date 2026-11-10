#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
static volatile sig_atomic_t child_pid;
static void forward_signal(int value) { if (child_pid > 0) kill(-(pid_t)child_pid, value); }
int main(int argc, char **argv) {
    int check = argc == 4 && strcmp(argv[3], "--check") == 0;
    if (argc != 3 && !check) return 64;
    if (!check && geteuid() != 0) { fputs("administrator_required\n", stderr); return 77; }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), path, sizeof(path)) <= 0) return 78;
    char *slash = strrchr(path, '/');
    if (!slash || (size_t)(slash - path) + strlen("/clean-install-helper") + 1 > sizeof(path)) return 78;
    strcpy(slash + 1, "clean-install-helper");
    int lock = -1;
    if (!check) {
        lock = open("/var/run/magic-bay-lte-v2/control.lock", O_RDWR | O_NOFOLLOW);
        struct stat info;
        if (lock < 0 || fstat(lock, &info) || !S_ISREG(info.st_mode) || info.st_uid ||
            (info.st_mode & 0022) || flock(lock, LOCK_EX | LOCK_NB)) {
            fputs("联网控制锁不可用，未清理任何组件。\n", stderr);
            if (lock >= 0) close(lock);
            return 75;
        }
    }
    signal(SIGINT, forward_signal); signal(SIGTERM, forward_signal); signal(SIGHUP, forward_signal);
    pid_t child = fork();
    if (child == 0) {
        if (setpgid(0, 0)) _exit(78);
        char *arguments[] = {"/bin/sh", path, argv[1], argv[2], check ? "--check" : NULL, NULL};
        execv(arguments[0], arguments); _exit(78);
    }
    if (child < 0) { if (lock >= 0) close(lock); return 78; }
    (void)setpgid(child, child); child_pid = child;
    int status = 0; pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (lock >= 0) close(lock);
    return waited < 0 ? 78 : WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
