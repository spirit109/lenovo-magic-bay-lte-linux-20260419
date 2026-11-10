/* Synthetic shutdown/USB errors only. Any real USB open or network command aborts. */
#include <assert.h>
#include <errno.h>
#include <libusb.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

static int scenario, closed_messages, bulk_calls;
static int fake_select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t) {
    (void)n; (void)r; (void)w; (void)e; (void)t;
    if (scenario == 0) raise(SIGTERM); /* Normal stop races with the ready utun read. */
    if (scenario == 3) { errno = EIO; return -1; }
    return 1;
}
static ssize_t fake_read(int fd, void *buffer, size_t size) {
    (void)fd;
    if (scenario == 2) { errno = EIO; return -1; }
    if (scenario >= 4) {
        unsigned char packet[24] = {0, 0, 0, 2, 0x45, 0, 0, 20};
        assert(size >= sizeof(packet));
        memcpy(buffer, packet, sizeof(packet));
        return sizeof(packet);
    }
    return 0;
}
static int fake_bulk(libusb_device_handle *h, unsigned char ep, unsigned char *data,
                     int length, int *transferred, unsigned timeout) {
    (void)h; (void)data; (void)timeout;
    assert(ep == 0x01 || ep == 0x81);
    bulk_calls++;
    *transferred = scenario == 6 || scenario == 7 ? length - 1 : 0;
    return scenario == 6 ? 0 : LIBUSB_ERROR_IO;
}
static int capture_fprintf(FILE *stream, const char *format, ...) {
    if (stream == stderr && strstr(format, "interface stream closed")) closed_messages++;
    return 0;
}
static int forbid_system(const char *s) { (void)s; abort(); }
static FILE *forbid_popen(const char *s, const char *m) { (void)s; (void)m; abort(); }
static int forbid_init(libusb_context **c) { (void)c; abort(); }
static libusb_device_handle *forbid_open(libusb_context *c, uint16_t v, uint16_t p) {
    (void)c; (void)v; (void)p; abort();
}

#define select fake_select
#define read fake_read
#define fprintf capture_fprintf
#define system forbid_system
#define popen forbid_popen
#define libusb_init forbid_init
#define libusb_open_device_with_vid_pid forbid_open
#define libusb_bulk_transfer fake_bulk
#define main never_run_real_backend
#include "../backend/mbim_net.c"
#undef main
#undef fprintf

static void reset_case(int next) {
    scenario = next;
    bulk_calls = 0;
    stop_requested = transport_unavailable = device_removed = 0;
    first_stop_reason = STOP_REASON_NONE;
    first_stop_signal = stop_summary_printed = 0;
}

int main(void) {
    struct net_context ctx = {0};
    ctx.utun_fd = 4;
    ctx.bulk_in = 0x81;
    ctx.bulk_out = 0x01;
    signal(SIGTERM, handle_stop_signal);
    reset_case(0);
    utun_to_usb_thread(&ctx);
    if (closed_messages != 0) {
        fputs("FAIL normal stop is incorrectly logged as an interface failure\n", stderr);
        return 1;
    }
    assert(first_stop_reason == STOP_REASON_SIGNAL && first_stop_signal == SIGTERM);
    puts("PASS normal stop racing with a closed utun does not invent a fault");
    reset_case(1);
    utun_to_usb_thread(&ctx);
    assert(closed_messages == 1 && stop_requested);
    assert(first_stop_reason == STOP_REASON_UTUN_EOF);
    puts("PASS an unexpected utun EOF remains a real failure");
    for (int n = 2; n <= 3; n++) {
        reset_case(n);
        utun_to_usb_thread(&ctx);
        assert(stop_requested && first_stop_reason == (n == 2 ? STOP_REASON_UTUN_READ : STOP_REASON_UTUN_SELECT));
    }
    puts("PASS genuine utun read/select failures keep their original causes");
    reset_case(4);
    utun_to_usb_thread(&ctx);
    assert(first_stop_reason == STOP_REASON_USB_OUT && bulk_calls == 1 && stop_requested);
    puts("PASS a zero-byte USB IO failure stops without replaying the packet");
    reset_case(7);
    utun_to_usb_thread(&ctx);
    assert(first_stop_reason == STOP_REASON_USB_OUT && bulk_calls == 1 && stop_requested);
    puts("PASS a partial USB IO failure is never retried as a complete packet");
    reset_case(6);
    utun_to_usb_thread(&ctx);
    assert(first_stop_reason == STOP_REASON_USB_SHORT_WRITE && bulk_calls == 1 && stop_requested);
    puts("PASS a short successful USB write remains a distinct fatal failure");
    reset_case(5);
    usb_to_utun_thread(&ctx);
    assert(first_stop_reason == STOP_REASON_USB_IN && bulk_calls == 1 && stop_requested);
    puts("PASS a receive-side USB failure records the input direction");
    handle_stop_signal(SIGTERM);
    note_usb_error(LIBUSB_ERROR_NO_DEVICE);
    assert(first_stop_reason == STOP_REASON_USB_IN && first_stop_signal == 0);
    puts("PASS later stop signals and cleanup errors do not replace the first cause");
    char *args[] = {"synthetic-backend", "--build-info"};
    assert(never_run_real_backend(2, args) == 0);
    puts("PASS build metadata returns before forbidden USB initialization or opens");
    puts("ALL 9 STOP-REASON REGRESSIONS PASSED; USB and network actions forbidden");
    return 0;
}
