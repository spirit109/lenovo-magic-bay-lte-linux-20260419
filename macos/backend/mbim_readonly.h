#ifndef MAGIC_BAY_MBIM_READONLY_H
#define MAGIC_BAY_MBIM_READONLY_H

/* Portable MBIM read-only transport. No interface claims, SET commands,
 * resets, data-interface changes, modem activation or host-network writes. */
#include <libusb.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

static const uint8_t mbim_ro_basic_connect[16] = {
    0xa2,0x89,0xcc,0x33,0xbc,0xbb,0x8b,0x4f,0xb6,0xb0,0x13,0x3e,0xc2,0xaa,0xe6,0xdf
};

struct mbim_ro_context {
    libusb_device_handle *handle;
    int interface_number;
    uint8_t interrupt_endpoint;
    uint32_t *transaction;
    int (*cancelled)(void *);
    void *cancel_context;
};

static inline uint32_t mbim_ro_u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline void mbim_ro_put(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static inline double mbim_ro_clock(void) {
#ifdef _WIN32
    LARGE_INTEGER frequency, ticks;
    QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&ticks);
    return (double)ticks.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
#endif
}
static inline void mbim_ro_sleep_ms(unsigned milliseconds) {
#ifdef _WIN32
    Sleep(milliseconds);
#else
    struct timespec duration = {(time_t)(milliseconds / 1000), (long)(milliseconds % 1000) * 1000000L};
    (void)nanosleep(&duration, NULL);
#endif
}
static inline int mbim_ro_cancelled(const struct mbim_ro_context *ctx) {
    return ctx->cancelled && ctx->cancelled(ctx->cancel_context);
}

static inline int mbim_ro_exchange(struct mbim_ro_context *ctx, uint8_t *command,
        uint16_t command_size, uint32_t expected_type, uint32_t transaction,
        uint8_t *reply, uint16_t reply_capacity, unsigned budget_ms) {
    if (!ctx || !ctx->handle || !command || !reply || command_size < 12 || reply_capacity < 16 ||
        !budget_ms || budget_ms > 5000) return LIBUSB_ERROR_INVALID_PARAM;
    uint32_t type = mbim_ro_u32(command);
    /* This primitive cannot be used to send an arbitrary MBIM write. */
    if (!((type == 1 && command_size == 16 && expected_type == 0x80000001u) ||
          (type == 2 && command_size == 12 && expected_type == 0x80000002u) ||
          (type == 3 && command_size == 48 && expected_type == 0x80000003u &&
           mbim_ro_u32(command + 40) == 0 && mbim_ro_u32(command + 44) == 0)))
        return LIBUSB_ERROR_INVALID_PARAM;
    if (mbim_ro_cancelled(ctx)) return LIBUSB_ERROR_INTERRUPTED;
    double deadline = mbim_ro_clock() + budget_ms / 1000.0;
    unsigned send_budget = budget_ms < 150 ? budget_ms : 150;
    int rc = libusb_control_transfer(ctx->handle, 0x21, 0, 0,
        (uint16_t)ctx->interface_number, command, command_size, send_budget);
    if (rc < 0) return rc;
    if (rc != command_size) return LIBUSB_ERROR_IO;
    if (ctx->interrupt_endpoint && mbim_ro_clock() + 0.010 < deadline) {
        uint8_t notification[64]; int count = 0;
        (void)libusb_interrupt_transfer(ctx->handle, ctx->interrupt_endpoint,
            notification, sizeof(notification), &count, 10);
    }
    while (mbim_ro_clock() < deadline) {
        if (mbim_ro_cancelled(ctx)) return LIBUSB_ERROR_INTERRUPTED;
        double left = (deadline - mbim_ro_clock()) * 1000.0;
        if (left < 1) break;
        unsigned timeout = left < 150 ? (unsigned)left : 150;
        rc = libusb_control_transfer(ctx->handle, 0xa1, 1, 0,
            (uint16_t)ctx->interface_number, reply, reply_capacity, timeout);
        if (rc >= 12 && mbim_ro_u32(reply) == expected_type && mbim_ro_u32(reply + 8) == transaction) {
            if (mbim_ro_u32(reply + 4) != (uint32_t)rc) return LIBUSB_ERROR_IO;
            return rc;
        }
        if (rc < 0 && rc != LIBUSB_ERROR_TIMEOUT && rc != LIBUSB_ERROR_PIPE) return rc;
        /* Unrelated indications are discarded without logging their payload. */
        if (mbim_ro_clock() + 0.010 < deadline) mbim_ro_sleep_ms(10);
    }
    return LIBUSB_ERROR_TIMEOUT;
}

static inline int mbim_ro_reply_service(const uint8_t *reply, int size, uint32_t transaction,
        const uint8_t service[16], uint32_t cid, uint8_t *info, uint32_t capacity, uint32_t *length, uint32_t *status) {
    *length = 0; *status = UINT32_MAX;
    if (size < 48 || mbim_ro_u32(reply) != 0x80000003u || mbim_ro_u32(reply + 8) != transaction)
        return LIBUSB_ERROR_NOT_FOUND;
    if (mbim_ro_u32(reply + 4) != (uint32_t)size || mbim_ro_u32(reply + 12) != 1 ||
        mbim_ro_u32(reply + 16) != 0 || memcmp(reply + 20, service, 16) ||
        mbim_ro_u32(reply + 36) != cid) return LIBUSB_ERROR_IO;
    *status = mbim_ro_u32(reply + 40);
    if (*status != 0) return LIBUSB_ERROR_OTHER;
    uint32_t bytes = mbim_ro_u32(reply + 44);
    if (bytes > (uint32_t)(size - 48) || bytes > capacity) return LIBUSB_ERROR_OVERFLOW;
    if (bytes) memcpy(info, reply + 48, bytes);
    *length = bytes;
    return 0;
}

static inline int mbim_ro_query_service(struct mbim_ro_context *ctx, const uint8_t service[16], uint32_t cid,
        uint8_t *info, uint32_t capacity, uint32_t *length, uint32_t *status, unsigned budget_ms) {
    uint8_t command[48] = {0}, reply[4096];
    if (!ctx || !ctx->transaction || !service || !info || !length || !status) return LIBUSB_ERROR_INVALID_PARAM;
    *length = 0; *status = UINT32_MAX;
    if (mbim_ro_cancelled(ctx)) return LIBUSB_ERROR_INTERRUPTED;
    mbim_ro_put(command, 3); mbim_ro_put(command + 4, sizeof(command));
    mbim_ro_put(command + 8, ++(*ctx->transaction)); mbim_ro_put(command + 12, 1);
    memcpy(command + 20, service, 16); mbim_ro_put(command + 36, cid);
    int rc = mbim_ro_exchange(ctx, command, sizeof(command), 0x80000003u,
        *ctx->transaction, reply, sizeof(reply), budget_ms);
    if (rc < 0) return rc;
    return mbim_ro_reply_service(reply, rc, *ctx->transaction, service, cid, info, capacity, length, status);
}

static inline int mbim_ro_query(struct mbim_ro_context *ctx, uint32_t cid,
        uint8_t *info, uint32_t capacity, uint32_t *length, uint32_t *status, unsigned budget_ms) {
    return mbim_ro_query_service(ctx, mbim_ro_basic_connect, cid, info, capacity, length, status, budget_ms);
}

static inline int mbim_ro_session(struct mbim_ro_context *ctx, int opening, unsigned budget_ms) {
    uint8_t command[16] = {0}, reply[64];
    if (!ctx || !ctx->transaction) return LIBUSB_ERROR_INVALID_PARAM;
    uint16_t bytes = opening ? 16 : 12;
    uint32_t type = opening ? 1 : 2;
    mbim_ro_put(command, type); mbim_ro_put(command + 4, bytes);
    mbim_ro_put(command + 8, ++(*ctx->transaction));
    if (opening) mbim_ro_put(command + 12, 4096);
    int rc = mbim_ro_exchange(ctx, command, bytes, type | 0x80000000u,
        *ctx->transaction, reply, sizeof(reply), budget_ms);
    if (rc < 0) return rc;
    return rc >= 16 && mbim_ro_u32(reply + 12) == 0 ? 0 : LIBUSB_ERROR_OTHER;
}
#endif
