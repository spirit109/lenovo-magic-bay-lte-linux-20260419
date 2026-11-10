/* Bounded synthetic DNS traffic through USB only. Never calls run_net(),
   creates utun, installs a component, or configures a host route or DNS. */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
static FILE *trial_report;
static int private_printf(const char *format, ...) {
    const char *allowed[] = {"  status=", "MBIM_OPEN status=", "MBIM_CLOSE status=",
        "  ready_state=", "  nw_error=", "  rssi=", "  session_id=", "  hardware_radio_state=",
        "  software_radio_state=", "  hw_radio_state=", "MBIM cid=", "MBIM_NET ncm="};
    int permitted = 0;
    for (unsigned i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++)
        if (strncmp(format, allowed[i], strlen(allowed[i])) == 0) permitted = 1;
    if (!permitted || !trial_report) return 0;
    va_list args;
    va_start(args, format);
    int result = vfprintf(trial_report, format, args);
    va_end(args);
    return result;
}
#define printf private_printf
#define main unused_backend_entrypoint
#include "mbim_net.c"
#undef main
#undef printf
#include <time.h>

static unsigned be16(const uint8_t *p) { return ((unsigned)p[0] << 8) | p[1]; }
static void set_be16(uint8_t *p, unsigned value) { p[0] = value >> 8; p[1] = value; }
static double monotonic_time(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1000000000.0;
}

static int dns_packet(uint8_t *packet, int length, unsigned id,
                      const uint8_t source[4], const uint8_t target[4]) {
    if (length < 72 || length > 1500) return -1;
    memset(packet, 0, (size_t)length);
    packet[0] = 0x45;
    set_be16(packet + 2, (unsigned)length);
    set_be16(packet + 4, id);
    packet[8] = 64;
    packet[9] = 17;
    memcpy(packet + 12, source, 4);
    memcpy(packet + 16, target, 4);
    unsigned checksum = 0;
    for (int i = 0; i < 20; i += 2) checksum += be16(packet + i);
    while (checksum >> 16) checksum = (checksum & 0xffffu) + (checksum >> 16);
    set_be16(packet + 10, (~checksum) & 0xffffu);
    set_be16(packet + 20, 53000);
    set_be16(packet + 22, 53);
    set_be16(packet + 24, (unsigned)length - 20u);
    /* IPv4 permits a zero UDP checksum. DNS includes a valid EDNS padding
       option, so every test length is a well-formed public example.com query. */
    uint8_t *dns = packet + 28;
    int dns_length = length - 28;
    set_be16(dns, id);
    dns[2] = 1;
    dns[5] = 1;
    dns[11] = 1;
    const uint8_t question[] = {7,'e','x','a','m','p','l','e',3,'c','o','m',0,0,1,0,1};
    memcpy(dns + 12, question, sizeof(question));
    int opt = 12 + (int)sizeof(question);
    set_be16(dns + opt + 1, 41);
    set_be16(dns + opt + 3, 1232);
    int padding = dns_length - opt - 15;
    if (padding < 0) return -1;
    set_be16(dns + opt + 9, (unsigned)padding + 4u);
    set_be16(dns + opt + 11, 12);
    set_be16(dns + opt + 13, (unsigned)padding);
    return length;
}

static void dns_responses(const uint8_t *ntb, int length, unsigned base,
                          unsigned count, uint8_t *seen) {
    if (length < 12 || get_u32le(ntb) != NCM_NTH16_SIGNATURE) return;
    unsigned block = get_u16le(ntb + 8);
    if (block < 12 || block > (unsigned)length) return;
    unsigned ndp = get_u16le(ntb + 10);
    for (int chain = 0; chain < 8 && ndp; chain++) {
        if (ndp + 8 > block) return;
        unsigned size = get_u16le(ntb + ndp + 4);
        if (size < 16 || ndp + size > block) return;
        if (is_ips_session0_signature(ntb + ndp)) {
            for (unsigned off = ndp + 8; off + 4 <= ndp + size; off += 4) {
                unsigned pos = get_u16le(ntb + off), len = get_u16le(ntb + off + 2);
                if (!pos && !len) break;
                if (len < 40 || pos + len > block) continue;
                const uint8_t *ip = ntb + pos;
                unsigned ihl = (ip[0] & 15u) * 4u;
                if ((ip[0] >> 4) != 4 || ihl < 20 || ihl + 20 > len || ip[9] != 17) continue;
                if (be16(ip + ihl) != 53 || be16(ip + ihl + 2) != 53000) continue;
                unsigned id = be16(ip + ihl + 8);
                if (id >= base && id - base < count && (ip[ihl + 10] & 0x80u))
                    seen[id - base] = 1;
            }
        }
        ndp = get_u16le(ntb + ndp + 6);
    }
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "--legacy") && strcmp(argv[1], "--corrected") &&
                      strcmp(argv[1], "--corrected-long"))) return 2;
    int legacy = strcmp(argv[1], "--legacy") == 0;
    unsigned packet_count = strcmp(argv[1], "--corrected-long") == 0 ? 320u : 32u;
    FILE *report = fdopen(dup(STDOUT_FILENO), "w");
    int quiet = open("/dev/null", O_WRONLY);
    if (!report || quiet < 0) return 1;
    trial_report = report;
    setvbuf(report, NULL, _IOLBF, 0);
    dup2(quiet, STDOUT_FILENO);
    dup2(quiet, STDERR_FILENO);
    signal(SIGINT, handle_stop_signal);
    signal(SIGTERM, handle_stop_signal);
    signal(SIGALRM, handle_stop_signal);
    alarm(packet_count + 90u);
    double deadline = monotonic_time() + packet_count + 80u;
    libusb_context *usb = NULL;
    libusb_device_handle *handle = NULL;
    struct libusb_config_descriptor *config = NULL;
    struct data_endpoints endpoints = {0};
    endpoints.interface_number = -1;
    struct ncm_transport transport = {0};
    int control = -1, data = -1, control_claimed = 0, data_claimed = 0, activated = 0;
    uint8_t notification = 0;
    uint32_t txid = 0, activation = 0;
    const char *stage = "init";
    int result = 1, rc = libusb_init(&usb);
    fprintf(report, "trial=%s host_routes=unchanged host_dns=unchanged synthetic_queries=example.com\n",
            legacy ? "legacy-framing" : "corrected-framing");
    if (rc < 0) goto cleanup;
    stage = "open";
    handle = libusb_open_device_with_vid_pid(usb, LENOVO_VENDOR_ID, MAGIC_BAY_LTE_PRODUCT_ID);
    if (!handle) { fprintf(report, "stage=open error=device_not_accessible\n"); goto cleanup; }
    stage = "descriptor";
    rc = libusb_get_active_config_descriptor(libusb_get_device(handle), &config);
    if (rc < 0) goto cleanup;
    print_config(config, &control, &data, &notification, &endpoints);
    if (control < 0 || data < 0 || !notification || !endpoints.bulk_in || !endpoints.bulk_out) goto cleanup;
    stage = "claim_control";
    rc = libusb_claim_interface(handle, control);
    if (rc < 0) goto cleanup;
    control_claimed = 1;
    stage = "claim_data";
    rc = libusb_claim_interface(handle, data);
    if (rc < 0) goto cleanup;
    data_claimed = 1;
    stage = "alt_zero";
    rc = libusb_set_interface_alt_setting(handle, data, 0);
    if (rc < 0) goto cleanup;
    stage = "ncm_configuration";
    rc = configure_ncm_transport(handle, control, endpoints.bulk_out_max_packet, &transport);
    if (rc < 0) goto cleanup;
    stage = "alt_one";
    rc = libusb_set_interface_alt_setting(handle, data, 1);
    if (rc < 0) goto cleanup;
    stage = "mbim_open";
    rc = mbim_open(handle, control, notification, &txid);
    if (rc < 0) goto cleanup;
    stage = "status_initialization";
    (void)mbim_query_device_caps(handle, control, notification, &txid);
    print_basic_status(handle, control, notification, &txid);
    stage = "packet_attach";
    rc = mbim_packet_service_attach(handle, control, notification, &txid);
    if (rc < 0) goto cleanup;
    stage = "activate";
    rc = mbim_connect_set(handle, control, notification, &txid,
                          MBIM_ACTIVATION_COMMAND_ACTIVATE, "3gnet", MBIM_CONTEXT_IP_TYPE_IPV4, &activation);
    if (rc < 0) goto cleanup;
    activated = 1;
    for (int i = 0; i < 8 && activation != 1 && !stop_requested; i++) {
        sleep(1);
        rc = mbim_query_connect(handle, control, notification, &txid, &activation);
        if (rc < 0) goto cleanup;
    }
    if (activation != 1 || stop_requested) goto cleanup;
    struct ipv4_config ip_config = {0};
    stage = "ip_configuration";
    rc = mbim_fetch_ip_configuration(handle, control, notification, &txid, &ip_config);
    if (rc < 0) goto cleanup;
    const uint8_t dns[4] = {223, 5, 5, 5};
    struct net_context net = {0};
    net.transport = transport;
    uint8_t packet[1500], outgoing[MBIM_NET_MAX_NTB_SIZE], incoming[MBIM_NET_MAX_NTB_SIZE], seen[320] = {0};
    const int lengths[] = {96, 484, 996, 1500};
    unsigned sent = 0, errors = 0;
    const unsigned base = legacy ? 0x6200u : 0x6300u;
    fprintf(report, "stage=activated max_packet=%u out_max=%u\n", transport.max_packet, transport.out_max);
    stage = "data";
    for (unsigned i = 0; i < packet_count && !stop_requested && monotonic_time() < deadline; i++) {
        int packet_length = lengths[(i / 8) % 4];
        if (dns_packet(packet, packet_length, base + i, ip_config.address, dns) < 0) break;
        int ntb_length = build_ncm_ntb_from_packet(&net, packet, (uint16_t)packet_length,
                                                   outgoing, sizeof(outgoing));
        if (ntb_length < 0) break;
        if (legacy && ntb_length % transport.max_packet == 1) {
            ntb_length--;
            put_u16le(outgoing + 8, (uint16_t)ntb_length);
        }
        int transferred = 0;
        rc = libusb_bulk_transfer(handle, endpoints.bulk_out, outgoing, ntb_length, &transferred, 3000);
        if (rc < 0 || transferred != ntb_length) {
            errors++;
            fprintf(report, "stage=tx query=%u ip_length=%d ntb_length=%d bytes=%d error=%s\n",
                    i, packet_length, ntb_length, transferred, libusb_error_name(rc));
            break;
        }
        sent++;
        double until = monotonic_time() + 0.85;
        while (!stop_requested && monotonic_time() < until) {
            transferred = 0;
            rc = libusb_bulk_transfer(handle, endpoints.bulk_in, incoming, sizeof(incoming), &transferred, 200);
            if (rc < 0 && rc != LIBUSB_ERROR_TIMEOUT) { errors++; break; }
            if (transferred > 0) dns_responses(incoming, transferred, base, packet_count, seen);
        }
        if (errors) { fprintf(report, "stage=rx error=%s\n", libusb_error_name(rc)); break; }
        if ((i + 1) % 8 == 0) {
            unsigned replies = 0;
            for (unsigned j = i - 7; j <= i; j++) replies += seen[j];
            fprintf(report, "ip_length=%d sent=8 replies_seen=%u ntb_last=%d\n", packet_length, replies, ntb_length);
        }
    }
    unsigned replies = 0;
    for (unsigned i = 0; i < packet_count; i++) replies += seen[i];
    fprintf(report, "trial_result sent=%u responses=%u usb_errors=%u interrupted=%d\n",
            sent, replies, errors, stop_requested != 0);
    result = errors || stop_requested || sent != packet_count ? 1 : 0;
cleanup:
    if (rc < 0 && result != 0) fprintf(report, "failed_stage=%s last_usb_error=%s\n", stage, libusb_error_name(rc));
    if (activated && handle) {
        int down = run_deactivate(handle, control, notification, &txid, MBIM_CONTEXT_IP_TYPE_IPV4);
        fprintf(report, "deactivate=%s\n", down < 0 ? libusb_error_name(down) : "ok");
    }
    if (handle && control_claimed) mbim_close(handle, control, notification, &txid);
    if (data_claimed) libusb_release_interface(handle, data);
    if (control_claimed) libusb_release_interface(handle, control);
    if (config) libusb_free_config_descriptor(config);
    if (handle) libusb_close(handle);
    if (usb) libusb_exit(usb);
    alarm(0);
    close(quiet);
    fprintf(report, "trial_finished result=%d host_network_writes=0\n", result);
    fclose(report);
    return result;
}
