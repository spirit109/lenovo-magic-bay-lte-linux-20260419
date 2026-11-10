/* All USB responses synthetic; networking, new USB opens and SETs forbidden. */
#include <assert.h>
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int mode, calls, reads;
static unsigned transaction, requested_cid;
static unsigned char requested_service[16];
static unsigned u32(const unsigned char *p) {
    return (unsigned)p[0] | (unsigned)p[1] << 8 | (unsigned)p[2] << 16 | (unsigned)p[3] << 24;
}
static void put(unsigned char *p, unsigned n) {
    for (unsigned i = 0; i < 4; i++) p[i] = (unsigned char)(n >> (8 * i));
}
static int mock_diagnostic_control(libusb_device_handle *handle, uint8_t type, uint8_t request,
                   uint16_t value, uint16_t index, unsigned char *data,
                   uint16_t length, unsigned timeout) {
    (void)handle; (void)type; (void)value;
    assert(index == 7 && timeout > 0 && timeout <= 150);
    calls++;
    if (request == 0) {
        assert(length == 48 && u32(data) == 3 && u32(data + 40) == 0);
        assert(u32(data + 44) == 0); /* QUERY only, no input payload. */
        transaction = u32(data + 8); requested_cid = u32(data + 36); reads = 0;
        memcpy(requested_service, data + 20, 16);
        if (mode == 1) return LIBUSB_ERROR_NO_DEVICE;
        return length;
    }
    assert(request == 1 && length >= 96);
    if (mode == 2) { usleep(20000); return LIBUSB_ERROR_TIMEOUT; }
    memset(data, 0, 96);
    put(data, 0x80000003u); put(data + 8, transaction);
    put(data + 12, 1);
    memcpy(data + 20, requested_service, 16); put(data + 36, requested_cid);
    unsigned bytes = requested_cid == 11 ? 8 : requested_cid == 9 ? 48 : 28;
    put(data + 4, 48 + bytes); put(data + 44, mode == 3 ? 4000 : bytes);
    put(data + 48, 30); put(data + 52, 99);
    if (requested_service[0] == 0x59) { put(data + 64, 21); put(data + 68, 42); put(data + 72, 13); }
    if (mode == 4 && reads++ == 0) put(data, 0x80000007u); /* Unrelated indication. */
    if (mode == 5) data[20] ^= 1; /* Wrong service must never become radio evidence. */
    return 48 + bytes;
}
static int mock_diagnostic_interrupt(libusb_device_handle *handle, unsigned char endpoint,
                     unsigned char *data, int length, int *count, unsigned timeout) {
    (void)handle; (void)data; (void)length;
    assert(endpoint == 0x83 && timeout == 10); *count = 0;
    return LIBUSB_ERROR_TIMEOUT;
}
static int forbidden_system(const char *s) { (void)s; abort(); }
static FILE *forbidden_popen(const char *s, const char *m) { (void)s; (void)m; abort(); }
static libusb_device_handle *forbidden_open(libusb_context *c, uint16_t v, uint16_t p) {
    (void)c; (void)v; (void)p; abort();
}

#define MBIM_NET_DIAGNOSTICS 1
#define MBIM_DIAG_QUERY_MS 200
#define libusb_control_transfer mock_diagnostic_control
#define libusb_interrupt_transfer mock_diagnostic_interrupt
#define libusb_open_device_with_vid_pid forbidden_open
#define system forbidden_system
#define popen forbidden_popen
#define main never_run_real_backend
#include "../backend/mbim_net.c"
#undef main

int main(void) {
    uint8_t info[512]; uint32_t length, txid = 40;
    mode = 0;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == 0);
    assert(length == 8 && get_u32le(info) == 30 && txid == 41);
    puts("PASS existing handle sends only a matching read-only QUERY");
    mode = 4;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == 0 && reads == 2);
    puts("PASS unrelated indications are ignored without logging payloads");
    mode = 3;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == LIBUSB_ERROR_OVERFLOW);
    mode = 5;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == LIBUSB_ERROR_IO);
    puts("PASS malformed lengths and wrong service cannot become evidence");
    mode = 2;
    double began = monotonic_seconds();
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == LIBUSB_ERROR_TIMEOUT);
    assert(monotonic_seconds() - began < 0.5);
    puts("PASS absent replies respect the bounded query deadline");
    mode = 1; stop_requested = transport_unavailable = device_removed = 0;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == LIBUSB_ERROR_NO_DEVICE);
    assert(!stop_requested && !transport_unavailable && !device_removed);
    puts("PASS telemetry error cannot stop the forwarding owner");
    stop_requested = 1; int before = calls;
    assert(diagnostic_query((void *)1, 7, 0x83, &txid, 11, info, &length) == LIBUSB_ERROR_INTERRUPTED);
    assert(calls == before); stop_requested = 0;
    puts("PASS shutdown forbids new diagnostic control requests");
    struct net_context ctx = {0}; diagnostic_init(&ctx.diag);
    struct diagnostic_schedule schedule = {.started = monotonic_seconds()};
    for (int i = 0; i < 3; i++) {
        schedule.next_query = 0; schedule.last_query = 0;
        diagnostic_tick(&schedule, &ctx, (void *)1, 7, 0x83, &txid);
    }
    assert(schedule.failures[0] == 3 && !stop_requested);
    before = calls; schedule.next_query = 0; schedule.last_query = 0;
    diagnostic_tick(&schedule, &ctx, (void *)1, 7, 0x83, &txid);
    assert(calls == before);
    schedule.started = monotonic_seconds() - 14401; schedule.last_query = 0;
    diagnostic_tick(&schedule, &ctx, (void *)1, 7, 0x83, &txid);
    assert(calls == before);
    puts("PASS repeated failure backs off and four-hour capture window expires");
    mode=0;
    struct diagnostic_schedule extended = {.started=monotonic_seconds(), .capabilities_checked=1, .atds_supported=1, .next_query=3};
    diagnostic_tick(&extended, &ctx, (void *)1, 7, 0x83, &txid);
    assert(requested_cid==1 && memcmp(requested_service,mbim_ro_atds,16)==0 && extended.failures[3]==0 && !stop_requested);
    puts("PASS advertised ATDS telemetry uses the existing owner without SET or a second USB handle");
    assert(diagnostic_age(100, 0) == -1 && diagnostic_age(100, 101) == 0 && diagnostic_age(100, 90) == 10);
    puts("PASS concurrent timestamp sampling cannot underflow packet age");
    fflush(stdout); int saved = dup(STDOUT_FILENO), capture[2]; assert(pipe(capture)==0);
    assert(dup2(capture[1], STDOUT_FILENO) >= 0); close(capture[1]);
    const uint8_t fake[] = {0x53,0,0x49,0,0x4d,0};
    print_utf16le_field("device_id", fake, sizeof(fake), 0, sizeof(fake));
    dump_hex("packet", fake, sizeof(fake), sizeof(fake));
    fflush(stdout); assert(dup2(saved, STDOUT_FILENO) >= 0); close(saved);
    char captured[64]; assert(read(capture[0],captured,sizeof(captured))==0); close(capture[0]);
    puts("PASS diagnostic builds suppress identity and packet hex dumps");
    puts("ALL 10 DIAGNOSTIC SAFETY CHECKS PASSED; no real USB or network controls");
    return 0;
}
