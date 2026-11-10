/* Explicit, bounded device inspection. Descriptor mode never opens a handle.
 * --query claims only the MBIM control interface; it never claims data, changes
 * alternate settings, detaches a driver, resets USB, activates LTE, or writes NV.
 * The installed controller must additionally hold its normal operation lock. */
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include "mbim_capabilities.h"

static volatile sig_atomic_t cancelled;
static void cancel_handler(int value) { (void)value; cancelled = 1; }
#ifndef _WIN32
static void deadline_handler(int value) { (void)value; _exit(124); }
#endif
static int query_cancelled(void *context) { (void)context; return cancelled; }

static void version_string(const uint8_t *info, uint32_t size, uint32_t offset, uint32_t bytes) {
    if (bytes > 256 || bytes % 2 || offset > size || bytes > size - offset) { printf("null"); return; }
    putchar('"');
    for (uint32_t i = 0; i < bytes; i += 2) {
        unsigned c = info[offset + i] | (unsigned)info[offset + i + 1] << 8;
        if (!c) break;
        if (c >= 32 && c <= 126 && c != '"' && c != '\\') putchar((int)c);
        else printf("\\u%04x", c);
    }
    putchar('"');
}

static void device_caps(const uint8_t *info, uint32_t bytes) {
    if (bytes < 64) { printf("null"); return; }
    printf("{\"device_type\":%u,\"cellular_class\":%u,\"data_class\":%u,\"sms_caps\":%u,"
           "\"control_caps\":%u,\"max_sessions\":%u,\"firmware\":",
           mbim_ro_u32(info), mbim_ro_u32(info + 4), mbim_ro_u32(info + 16),
           mbim_ro_u32(info + 20), mbim_ro_u32(info + 24), mbim_ro_u32(info + 28));
    version_string(info, bytes, mbim_ro_u32(info + 48), mbim_ro_u32(info + 52));
    printf(",\"hardware\":");
    version_string(info, bytes, mbim_ro_u32(info + 56), mbim_ro_u32(info + 60));
    printf("}");
}

static void device_services(const uint8_t *info, uint32_t bytes) {
    if (!mbim_services_valid(info, bytes)) { printf("null"); return; }
    uint32_t count = mbim_ro_u32(info);
    printf("{\"max_dss_sessions\":%u,\"services\":[", mbim_ro_u32(info + 4));
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *service = info + mbim_ro_u32(info + 8 + i * 8);
        if (i) putchar(',');
        printf("{\"uuid_bytes\":\"");
        for (unsigned j = 0; j < 16; j++) printf("%02x", service[j]);
        printf("\",\"dss_payload\":%u,\"max_dss_instances\":%u,\"cids\":[",
               mbim_ro_u32(service + 16), mbim_ro_u32(service + 20));
        uint32_t cids = mbim_ro_u32(service + 24);
        for (uint32_t j = 0; j < cids; j++) printf("%s%u", j ? "," : "", mbim_ro_u32(service + 28 + j * 4));
        printf("]}");
    }
    printf("]}");
}

static void radio_metric(const char *name, uint32_t raw, unsigned maximum, double base, double step) {
    struct mbim_radio_value value = mbim_radio_scaled(raw, maximum, base, step);
    printf(",\"%s\":", name);
    if (!value.known) printf("null");
    else printf("{\"value\":%.1f,\"relation\":\"%s\"}", value.value,
                value.limit < 0 ? "at_most" : value.limit > 0 ? "at_least" : "exact");
}

static void extended_queries(struct mbim_ro_context *ctx, int has_signal, int has_firmware) {
    uint8_t info[512]; uint32_t length, status;
    if (has_signal && !cancelled) {
        int rc = mbim_ro_query_service(ctx, mbim_ro_atds, 1, info, sizeof(info), &length, &status, 1200);
        printf(",\"atds_signal\":{\"rc\":%d,\"available\":%s", rc, rc == 0 && length >= 28 ? "true" : "false");
        if (rc == 0 && length >= 28) {
            printf(",\"rssi\":%u,\"error_rate\":%u,\"rsrq\":%u,\"rsrp\":%u,\"rssnr\":%u",
                   mbim_ro_u32(info), mbim_ro_u32(info + 4), mbim_ro_u32(info + 16), mbim_ro_u32(info + 20), mbim_ro_u32(info + 24));
            radio_metric("rssi_dbm", mbim_ro_u32(info), 31, -113, 2);
            radio_metric("rsrp_dbm", mbim_ro_u32(info + 20), 97, -140, 1);
            radio_metric("rsrq_db", mbim_ro_u32(info + 16), 34, -19.5, 0.5);
            radio_metric("rssnr_db", mbim_ro_u32(info + 24), 35, -5, 1);
        }
        putchar('}');
    }
    if (has_firmware && !cancelled) {
        int rc = mbim_ro_query_service(ctx, mbim_ro_firmware_id, 1, info, sizeof(info), &length, &status, 1200);
        printf(",\"firmware_package_id\":{\"rc\":%d,\"uuid_bytes\":", rc);
        if (rc == 0 && length == 16) {
            putchar('"'); for (unsigned i = 0; i < 16; i++) printf("%02x", info[i]); putchar('"');
        } else printf("null");
        putchar('}');
    }
}

static int query_device(libusb_device *device, int control, uint8_t interrupt) {
    libusb_device_handle *handle = NULL;
    int rc = libusb_open(device, &handle);
    printf("{\"open_result\":%d", rc);
    if (rc < 0) { printf("}"); return rc; }
    rc = libusb_claim_interface(handle, control);
    printf(",\"exclusive_control_claim\":%d", rc);
    if (rc < 0) { libusb_close(handle); printf("}"); return rc; }
    uint32_t transaction = 0;
    struct mbim_ro_context ctx = {handle, control, interrupt, &transaction, query_cancelled, NULL};
    rc = mbim_ro_session(&ctx, 1, 1500);
    printf(",\"mbim_open_result\":%d", rc);
    if (rc == 0) {
        int has_signal = 0, has_firmware = 0;
        const uint32_t cids[] = {1, 2, 3, 9, 10, 11, 16};
        printf(",\"queries\":[");
        for (unsigned i = 0; i < sizeof(cids) / sizeof(cids[0]) && !cancelled; i++) {
            uint8_t info[4096]; uint32_t length, status;
            int result = mbim_ro_query(&ctx, cids[i], info, sizeof(info), &length, &status, 1200);
            printf("%s{\"cid\":%u,\"rc\":%d,\"mbim_status\":", i ? "," : "", cids[i], result);
            if (status == UINT32_MAX) printf("null"); else printf("%u", status);
            printf(",\"value\":");
            if (result < 0) printf("null");
            else if (cids[i] == 1) device_caps(info, length);
            else if (cids[i] == 16) {
                device_services(info, length);
                has_signal = mbim_service_supports(info, length, mbim_ro_atds, 1);
                has_firmware = mbim_service_supports(info, length, mbim_ro_firmware_id, 1);
            }
            else if (cids[i] == 2 && length >= 4) printf("{\"ready_state\":%u}", mbim_ro_u32(info));
            else if (cids[i] == 3 && length >= 8) printf("{\"hardware_radio\":%u,\"software_radio\":%u}", mbim_ro_u32(info), mbim_ro_u32(info + 4));
            else if (cids[i] == 9 && length >= 20) printf("{\"nw_error\":%u,\"register_state\":%u,\"available_data_classes\":%u}", mbim_ro_u32(info), mbim_ro_u32(info + 4), mbim_ro_u32(info + 12));
            else if (cids[i] == 10 && length >= 28) printf("{\"nw_error\":%u,\"packet_service_state\":%u,\"highest_data_class\":%u}", mbim_ro_u32(info), mbim_ro_u32(info + 4), mbim_ro_u32(info + 8));
            else if (cids[i] == 11 && length >= 8) printf("{\"rssi\":%u,\"error_rate\":%u}", mbim_ro_u32(info), mbim_ro_u32(info + 4));
            else printf("null");
            putchar('}'); fflush(stdout);
            if (result == LIBUSB_ERROR_NO_DEVICE) break;
        }
        printf("]");
        extended_queries(&ctx, has_signal, has_firmware);
        ctx.cancelled = NULL; /* Close only this explicitly opened control session. */
        printf(",\"mbim_close_result\":%d", mbim_ro_session(&ctx, 0, 600));
    }
    printf(",\"control_release_result\":%d", libusb_release_interface(handle, control));
    libusb_close(handle);
    printf("}");
    return rc;
}

int main(int argc, char **argv) {
    int query = argc == 2 && strcmp(argv[1], "--query") == 0;
    if (argc != 2 || (!query && strcmp(argv[1], "--descriptors") != 0)) {
        fprintf(stderr, "usage: device-info --descriptors | --query\n"); return 64;
    }
    signal(SIGTERM, cancel_handler); signal(SIGINT, cancel_handler);
#ifndef _WIN32
    signal(SIGALRM, deadline_handler); alarm(20);
#endif
    libusb_context *context = NULL; libusb_device **devices = NULL;
    int rc = libusb_init(&context);
    if (rc < 0) return 1;
    ssize_t count = libusb_get_device_list(context, &devices);
    libusb_device *selected = NULL; struct libusb_device_descriptor descriptor = {0}; unsigned matches = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor candidate;
        if (libusb_get_device_descriptor(devices[i], &candidate) == 0 && candidate.idVendor == 0x17ef && candidate.idProduct == 0x7240) {
            selected = devices[i]; descriptor = candidate; matches++;
        }
    }
#ifdef _WIN32
    unsigned long process_id = GetCurrentProcessId();
#else
    unsigned long process_id = (unsigned long)getpid();
#endif
    printf("{\"schema\":1,\"process_id\":%lu,\"observed_unix\":%lld,\"enumeration_result\":%lld,\"matching_devices\":%u,\"query_mode\":%s,\"data_interface_claims\":0,\"set_commands\":0,\"host_network_writes\":0",
           process_id, (long long)time(NULL), (long long)count, matches, query ? "true" : "false");
    if (matches == 1) {
        printf(",\"usb\":{\"vendor_id\":%u,\"product_id\":%u,\"bcd_usb\":%u,\"bcd_device\":%u,\"libusb_speed\":%d,\"interfaces\":[",
               descriptor.idVendor, descriptor.idProduct, descriptor.bcdUSB, descriptor.bcdDevice, libusb_get_device_speed(selected));
        struct libusb_config_descriptor *config = NULL; int control = -1; uint8_t interrupt = 0; unsigned emitted = 0;
        rc = libusb_get_active_config_descriptor(selected, &config);
        if (rc == 0) {
            for (unsigned i = 0; i < config->bNumInterfaces; i++) {
                for (int j = 0; j < config->interface[i].num_altsetting; j++) {
                    const struct libusb_interface_descriptor *alt = &config->interface[i].altsetting[j];
                    printf("%s{\"number\":%u,\"alternate\":%u,\"class\":%u,\"subclass\":%u,\"protocol\":%u,\"endpoints\":[",
                           emitted++ ? "," : "", alt->bInterfaceNumber, alt->bAlternateSetting, alt->bInterfaceClass, alt->bInterfaceSubClass, alt->bInterfaceProtocol);
                    for (unsigned k = 0; k < alt->bNumEndpoints; k++) {
                        const struct libusb_endpoint_descriptor *ep = &alt->endpoint[k];
                        printf("%s{\"address\":%u,\"attributes\":%u,\"max_packet\":%u}", k ? "," : "", ep->bEndpointAddress, ep->bmAttributes, ep->wMaxPacketSize);
                        if (alt->bInterfaceClass == 2 && alt->bInterfaceSubClass == 14 && alt->bAlternateSetting == 0 &&
                            (ep->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_INTERRUPT && (ep->bEndpointAddress & LIBUSB_ENDPOINT_IN)) {
                            control = alt->bInterfaceNumber; interrupt = ep->bEndpointAddress;
                        }
                    }
                    printf("]}");
                }
            }
        }
        printf("],\"configuration_result\":%d}", rc);
        if (query && control >= 0 && !cancelled) { printf(",\"mbim\":"); rc = query_device(selected, control, interrupt); }
        else if (query) { printf(",\"query_error\":\"no_safe_mbim_control_alternate\""); rc = LIBUSB_ERROR_NOT_FOUND; }
        if (config) libusb_free_config_descriptor(config);
    } else rc = LIBUSB_ERROR_NOT_FOUND;
    printf("}\n"); fflush(stdout);
    if (devices) libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return rc < 0 ? 1 : 0;
}
