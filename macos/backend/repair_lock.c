/* macOS adapter: hold the existing root controller's lock across replacement. */
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
static void forward_signal(int signal_number) {
    if (child_pid > 0) kill(-(pid_t)child_pid, signal_number);
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    int mutation = strcmp(argv[1], "install") == 0 || strcmp(argv[1], "restore") == 0;
    if (!mutation && strcmp(argv[1], "--check") && strcmp(argv[1], "--self-test")) return 64;
    if (mutation && geteuid() != 0) { fputs("administrator_required\n", stderr); return 77; }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), path, sizeof(path)) <= 0) return 78;
    char *slash = strrchr(path, '/');
    if (!slash) return 78;
    size_t prefix = (size_t)(slash - path + 1);
    if (prefix + strlen("repair-backend.sh") + 1 > sizeof(path)) return 78;
    strcpy(path + prefix, "repair-backend.sh");
    int lock = -1;
    if (mutation) {
        lock = open("/var/run/magic-bay-lte-v2/control.lock", O_RDWR | O_NOFOLLOW);
        struct stat info;
        if (lock < 0 || fstat(lock, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_uid != 0 || (info.st_mode & 0022) || flock(lock, LOCK_EX | LOCK_NB) != 0) {
            fputs("联网控制操作正在进行，或控制锁不可验证，请稍后重试。\n", stderr);
            if (lock >= 0) close(lock);
            return 75;
        }
    }
    signal(SIGINT, forward_signal);
    signal(SIGTERM, forward_signal);
    signal(SIGHUP, forward_signal);
    pid_t child = fork();
    if (child == 0) {
        if (setpgid(0, 0) != 0) _exit(78);
        char *arguments[] = {"/bin/sh", path, argv[1], NULL};
        execv(arguments[0], arguments);
        _exit(78);
    }
    if (child < 0) { if (lock >= 0) close(lock); return 78; }
    (void)setpgid(child, child);
    child_pid = child;
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (lock >= 0) close(lock);
    if (waited < 0) return 78;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
