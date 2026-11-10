/* Opt-in bounded telemetry. Included only by an explicitly diagnostic build.
 * The existing MBIM owner serializes QUERYs in its main thread. No new handle,
 * OPEN, SET, reset, interface claim, connection or route operation is used. */
#ifndef MBIM_DIAG_QUERY_MS
#define MBIM_DIAG_QUERY_MS 1200
#endif

struct diagnostic_schedule {
    double started, last_data, last_query;
    unsigned next_query, failures[4];
    int capabilities_checked, atds_supported;
};

static void diagnostic_init(struct diagnostic_counters *stats) {
#define INIT_DIAG(key) atomic_init(&stats->key, 0)
    INIT_DIAG(rx_packets); INIT_DIAG(tx_packets); INIT_DIAG(rx_bytes); INIT_DIAG(tx_bytes);
    INIT_DIAG(rx_timeouts); INIT_DIAG(rx_errors); INIT_DIAG(tx_errors); INIT_DIAG(parse_drops);
    INIT_DIAG(last_rx_ms); INIT_DIAG(last_tx_ms);
#undef INIT_DIAG
}

static int diagnostic_query(libusb_device_handle *handle, int iface, uint8_t interrupt_ep,
                            uint32_t *txid, uint32_t cid, uint8_t *info, uint32_t *length) {
    struct mbim_ro_context ctx = {handle, iface, interrupt_ep, txid, backend_read_cancelled, NULL};
    uint32_t status;
    return mbim_ro_query(&ctx, cid, info, 512, length, &status, MBIM_DIAG_QUERY_MS);
}

static void diagnostic_metric(const char *name, uint32_t raw, unsigned maximum, double base, double step) {
    struct mbim_radio_value value = mbim_radio_scaled(raw, maximum, base, step);
    printf(",\"%s\":", name);
    if (!value.known) printf("null");
    else printf("%.1f,\"%s_limit\":%d", value.value, name, value.limit);
}

static long long diagnostic_age(uint64_t now_ms, uint64_t packet_ms) {
    return packet_ms ? (now_ms >= packet_ms ? (long long)(now_ms - packet_ms) : 0) : -1;
}

static void diagnostic_data(struct net_context *ctx) {
    uint64_t now_ms = (uint64_t)(monotonic_seconds() * 1000.0);
#define LOAD_DIAG(key) ((unsigned long long)atomic_load_explicit(&ctx->diag.key, memory_order_relaxed))
    unsigned long long rx = LOAD_DIAG(last_rx_ms), tx = LOAD_DIAG(last_tx_ms);
    printf("MBIM_DIAG {\"ts\":%lld,\"pid\":%ld,\"kind\":\"data\",\"ok\":true,"
           "\"rx_packets\":%llu,\"tx_packets\":%llu,\"rx_bytes\":%llu,\"tx_bytes\":%llu,"
           "\"rx_timeouts\":%llu,\"rx_errors\":%llu,\"tx_errors\":%llu,\"parse_drops\":%llu,"
           "\"last_rx_ms\":%lld,\"last_tx_ms\":%lld}\n",
           (long long)time(NULL), (long)getpid(), LOAD_DIAG(rx_packets), LOAD_DIAG(tx_packets),
           LOAD_DIAG(rx_bytes), LOAD_DIAG(tx_bytes), LOAD_DIAG(rx_timeouts), LOAD_DIAG(rx_errors),
           LOAD_DIAG(tx_errors), LOAD_DIAG(parse_drops), diagnostic_age(now_ms, rx),
           diagnostic_age(now_ms, tx));
#undef LOAD_DIAG
    fflush(stdout);
}

static void diagnostic_tick(struct diagnostic_schedule *state, struct net_context *ctx,
                             libusb_device_handle *handle, int iface, uint8_t interrupt_ep, uint32_t *txid) {
    double now = monotonic_seconds();
    if (stop_requested || now - state->started >= 14400) return;
    if (!state->capabilities_checked) {
        state->capabilities_checked = 1;
        uint8_t services[4096]; uint32_t length, status;
        struct mbim_ro_context query = {handle, iface, interrupt_ep, txid, backend_read_cancelled, NULL};
        if (mbim_ro_query(&query, 16, services, sizeof(services), &length, &status, MBIM_DIAG_QUERY_MS) == 0)
            state->atds_supported = mbim_service_supports(services, length, mbim_ro_atds, 1);
    }
    if (now - state->last_data >= 5) {
        diagnostic_data(ctx);
        state->last_data = now;
    }
    if (now - state->last_query < 5) return;
    state->last_query = now;
    unsigned index = state->next_query++ % (state->atds_supported ? 4 : 3);
    if (state->failures[index] >= 3) return;
    const uint32_t cids[] = {MBIM_CID_SIGNAL_STATE, MBIM_CID_REGISTER_STATE, MBIM_CID_PACKET_SERVICE, 1};
    const char *kinds[] = {"signal", "registration", "packet", "signal_ext"};
    uint8_t info[512] = {0};
    uint32_t length = 0;
    int rc;
    if (index == 3) {
        struct mbim_ro_context query = {handle, iface, interrupt_ep, txid, backend_read_cancelled, NULL};
        uint32_t status;
        rc = mbim_ro_query_service(&query, mbim_ro_atds, 1, info, sizeof(info), &length, &status, MBIM_DIAG_QUERY_MS);
    } else rc = diagnostic_query(handle, iface, interrupt_ep, txid, cids[index], info, &length);
    uint32_t minimum = index == 0 ? 8 : index == 1 ? 48 : 28;
    if (rc == 0 && length < minimum) rc = LIBUSB_ERROR_IO;
    if (rc < 0) state->failures[index]++;
    else state->failures[index] = 0;
    printf("MBIM_DIAG {\"ts\":%lld,\"pid\":%ld,\"kind\":\"%s\",\"cid\":%u,\"ok\":%s,\"rc\":%d",
           (long long)time(NULL), (long)getpid(), kinds[index], cids[index], rc == 0 ? "true" : "false", rc);
    if (rc == 0 && index == 0) printf(",\"rssi\":%u,\"error_rate\":%u", get_u32le(info), get_u32le(info + 4));
    if (rc == 0 && index == 1) printf(",\"nw_error\":%u,\"register_state\":%u", get_u32le(info), get_u32le(info + 4));
    if (rc == 0 && index == 2) printf(",\"nw_error\":%u,\"packet_service_state\":%u", get_u32le(info), get_u32le(info + 4));
    if (rc == 0 && index == 3) {
        printf(",\"rssi\":%u,\"error_rate\":%u,\"rsrq\":%u,\"rsrp\":%u,\"rssnr\":%u",
               get_u32le(info), get_u32le(info + 4), get_u32le(info + 16), get_u32le(info + 20), get_u32le(info + 24));
        diagnostic_metric("rsrp_dbm", get_u32le(info + 20), 97, -140, 1);
        diagnostic_metric("rsrq_db", get_u32le(info + 16), 34, -19.5, 0.5);
        diagnostic_metric("rssnr_db", get_u32le(info + 24), 35, -5, 1);
    }
    puts("}");
    fflush(stdout);
}
