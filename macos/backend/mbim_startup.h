#ifndef MAGIC_BAY_MBIM_STARTUP_H
#define MAGIC_BAY_MBIM_STARTUP_H
#include "mbim_readonly.h"

#ifndef MBIM_STARTUP_RETRY_MS
#define MBIM_STARTUP_RETRY_MS 500
#endif

struct mbim_startup_result {
    int rc;
    uint32_t status, ready_state, register_state;
    const char *reason;
};

static inline int mbim_startup_transient(int rc, uint32_t status) {
    return rc == LIBUSB_ERROR_TIMEOUT || rc == LIBUSB_ERROR_PIPE ||
        (rc == LIBUSB_ERROR_OTHER && (status == 1 || status == 14));
}

/* Within one explicit connection request, wait with QUERYs only. No attach,
 * activation, PIN operation, radio SET, reconnect, or host-network changes. */
static inline struct mbim_startup_result mbim_wait_initialized(struct mbim_ro_context *ctx, unsigned budget_ms) {
    struct mbim_startup_result result = {LIBUSB_ERROR_TIMEOUT, UINT32_MAX, UINT32_MAX,
                                        UINT32_MAX, "initialization_timeout"};
    if (!ctx || !budget_ms || budget_ms > 30000) {
        result.rc = LIBUSB_ERROR_INVALID_PARAM; result.reason = "invalid_initialization_budget"; return result;
    }
    double deadline = mbim_ro_clock() + budget_ms / 1000.0;
    while (mbim_ro_clock() < deadline) {
        uint8_t info[512]; uint32_t length = 0, status = UINT32_MAX;
        if (mbim_ro_cancelled(ctx)) { result.rc = LIBUSB_ERROR_INTERRUPTED; result.reason = "initialization_cancelled"; return result; }
        unsigned remaining = (unsigned)((deadline - mbim_ro_clock()) * 1000.0);
        if (!remaining) break;
        int rc = mbim_ro_query(ctx, 2, info, sizeof(info), &length, &status, remaining < 1200 ? remaining : 1200);
        result.status = status;
        if (rc < 0 && !mbim_startup_transient(rc, status)) {
            result.rc = rc; result.reason = "initialization_query_failed"; return result;
        }
        if (rc == 0) {
            if (length < 4) { result.rc = LIBUSB_ERROR_IO; result.reason = "invalid_ready_response"; return result; }
            result.ready_state = mbim_ro_u32(info);
            if (result.ready_state > 1) {
                result.rc = LIBUSB_ERROR_OTHER;
                result.reason = result.ready_state == 2 ? "sim_not_inserted" :
                    result.ready_state == 6 ? "sim_locked" : "subscriber_not_ready";
                return result;
            }
        }
        if (rc == 0 && result.ready_state == 1) {
            double left = (deadline - mbim_ro_clock()) * 1000.0;
            if (left < 1) break;
            rc = mbim_ro_query(ctx, 3, info, sizeof(info), &length, &status, left < 1200 ? (unsigned)left : 1200);
            result.status = status;
            if (rc == 0 && length >= 8 && (mbim_ro_u32(info) == 0 || mbim_ro_u32(info + 4) == 0)) {
                result.rc = LIBUSB_ERROR_OTHER; result.reason = "radio_off"; return result;
            }
            if (rc < 0 && !mbim_startup_transient(rc, status)) {
                result.rc = rc; result.reason = "initialization_query_failed"; return result;
            }
            if (rc == 0 && (length < 8 || mbim_ro_u32(info) != 1 || mbim_ro_u32(info + 4) != 1)) {
                result.rc = LIBUSB_ERROR_IO; result.reason = "invalid_radio_response"; return result;
            }
            if (rc == 0) {
                left = (deadline - mbim_ro_clock()) * 1000.0;
                if (left < 1) break;
                rc = mbim_ro_query(ctx, 9, info, sizeof(info), &length, &status, left < 1200 ? (unsigned)left : 1200);
                result.status = status;
                if (rc < 0 && !mbim_startup_transient(rc, status)) {
                    result.rc = rc; result.reason = "initialization_query_failed"; return result;
                }
                if (rc == 0) {
                    if (length < 8) { result.rc = LIBUSB_ERROR_IO; result.reason = "invalid_registration_response"; return result; }
                    result.register_state = mbim_ro_u32(info + 4);
                    if (result.register_state >= 3 && result.register_state <= 5) {
                        result.rc = 0; result.reason = "ready"; return result;
                    }
                    if (result.register_state == 6) {
                        result.rc = LIBUSB_ERROR_OTHER; result.reason = "registration_denied"; return result;
                    }
                    if (result.register_state > 6) {
                        result.rc = LIBUSB_ERROR_IO; result.reason = "invalid_registration_state"; return result;
                    }
                }
            }
        }
        double left = (deadline - mbim_ro_clock()) * 1000.0;
        if (left >= 1) mbim_ro_sleep_ms(left < MBIM_STARTUP_RETRY_MS ? (unsigned)left : MBIM_STARTUP_RETRY_MS);
    }
    return result;
}
#endif
