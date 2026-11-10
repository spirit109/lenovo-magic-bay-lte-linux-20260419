/* Run only synthetic USB failures, including a cleanup call that never returns. */
#include <assert.h>
#include <libusb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int scenario;
static int mock_init(libusb_context **ctx) { *ctx = (void *)2; return 0; }
static libusb_device_handle *mock_open(libusb_context *ctx, uint16_t vid, uint16_t pid) {
    (void)ctx; (void)vid; (void)pid; return (void *)3;
}
static libusb_device *mock_device(libusb_device_handle *handle) { (void)handle; return (void *)4; }
static libusb_device *mock_ref(libusb_device *device) { return device; }
static void mock_unref(libusb_device *device) { (void)device; }
static int mock_descriptor(libusb_device *device, struct libusb_device_descriptor *desc) {
    (void)device; memset(desc, 0, sizeof(*desc)); desc->idVendor = 0x17ef; desc->idProduct = 0x7240; return 0;
}
static int mock_config(libusb_device *device, struct libusb_config_descriptor **config) {
    (void)device; (void)config;
    if (scenario == 3) { sleep(10); return LIBUSB_ERROR_IO; }
    if (scenario == 2) usleep(400000);
    return scenario == 0 ? LIBUSB_ERROR_NO_DEVICE : LIBUSB_ERROR_IO;
}
static ssize_t mock_list(libusb_context *ctx, libusb_device ***list) {
    (void)ctx;
    if (scenario == 2) return LIBUSB_ERROR_IO;
    *list = calloc(2, sizeof(**list)); assert(*list);
    /* The reinserted device has the same VID/PID, but a different session. */
    (*list)[0] = scenario == 3 ? (void *)5 : (void *)4;
    return 1;
}
static void mock_free_list(libusb_device **list, int unref) { (void)unref; free(list); }
static void mock_close(libusb_device_handle *handle) {
    (void)handle;
    if (scenario != 4) for (;;) pause();
}
static void mock_exit(libusb_context *ctx) { (void)ctx; }
static int forbid_system(const char *cmd) { (void)cmd; abort(); }
static FILE *forbid_popen(const char *cmd, const char *mode) { (void)cmd; (void)mode; abort(); }

#define MBIM_NET_DETACH_GRACE_SECONDS 0.2
#define MBIM_NET_STOP_GRACE_SECONDS 0.2
#define MBIM_NET_WATCH_INTERVAL_US 10000
#define libusb_init mock_init
#define libusb_open_device_with_vid_pid mock_open
#define libusb_get_device mock_device
#define libusb_ref_device mock_ref
#define libusb_unref_device mock_unref
#define libusb_get_device_descriptor mock_descriptor
#define libusb_get_active_config_descriptor mock_config
#define libusb_get_device_list mock_list
#define libusb_free_device_list mock_free_list
#define libusb_close mock_close
#define libusb_exit mock_exit
#define system forbid_system
#define popen forbid_popen
#define main synthetic_backend_entrypoint
#ifdef BEFORE_HOTPLUG_FIX
#include "fixtures/mbim_net_0_2_3.c"
#else
#include "../backend/mbim_net.c"
#endif
#undef main

int main(void) {
    const char *names[] = {"NO_DEVICE during startup", "driver close stalls", "inventory unknown is not unplugging",
                           "fast reinsertion invalidates the old device session", "ordinary failed startup exits normally"};
    for (scenario = 0; scenario < 5; scenario++) {
        fflush(NULL);
        struct timespec started, finished;
        clock_gettime(CLOCK_MONOTONIC, &started);
        pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            /* A broken implementation can time out only this synthetic child. */
            signal(SIGALRM, SIG_DFL); alarm(3);
            char *args[] = {"synthetic-no-real-usb", NULL};
            _exit(synthetic_backend_entrypoint(1, args));
        }
        int status = 0; assert(waitpid(child, &status, 0) == child);
        clock_gettime(CLOCK_MONOTONIC, &finished);
        double elapsed = (double)(finished.tv_sec - started.tv_sec) + (double)(finished.tv_nsec - started.tv_nsec) / 1e9;
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 1) {
            fprintf(stderr, "FAIL %s: stale process required external termination (status=%d)\n", names[scenario], status);
            return 1;
        }
        if (scenario == 2 && elapsed < 0.4) {
            fputs("FAIL unknown enumeration ended the owner before any real USB failure\n", stderr);
            return 1;
        }
        printf("PASS %s; own process exits without external termination\n", names[scenario]);
    }
    puts("ALL 5 HOTPLUG REGRESSIONS PASSED; USB mocked, network commands forbidden");
    return 0;
}
