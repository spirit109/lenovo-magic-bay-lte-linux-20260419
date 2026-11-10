/* Read-only CDC-NCM queries: no MBIM activation, utun, route or DNS writes. */
#include <libusb.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned u16(const unsigned char *p) {
    return (unsigned)p[0] | ((unsigned)p[1] << 8);
}

static uint32_t u32(const unsigned char *p) {
    return (uint32_t)u16(p) | ((uint32_t)u16(p + 2) << 16);
}

static int query(libusb_device_handle *handle, int iface, unsigned char request,
                 unsigned char *data, uint16_t length) {
    int rc = libusb_control_transfer(handle,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
        request, 0, (uint16_t)iface, data, length, 3000);
    if (rc < 0) printf("query_request=0x%02x error=%s\n", request, libusb_error_name(rc));
    return rc;
}

int main(void) {
    libusb_context *context = NULL;
    libusb_device **devices = NULL;
    libusb_device *target = NULL;
    libusb_device_handle *handle = NULL;
    struct libusb_config_descriptor *config = NULL;
    int control = -1, count = 0, claimed = 0, result = 1;
    const struct libusb_version *version = libusb_get_version();
    printf("libusb_version=%u.%u.%u\n", version->major, version->minor, version->micro);
    if (libusb_init(&context) < 0) return 1;
    ssize_t total = libusb_get_device_list(context, &devices);
    if (total < 0) goto cleanup;
    for (ssize_t i = 0; i < total; i++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[i], &descriptor) == 0 &&
            descriptor.idVendor == 0x17ef && descriptor.idProduct == 0x7240) {
            target = devices[i];
            count++;
        }
    }
    printf("magic_bay_count=%d\n", count);
    if (count != 1) goto cleanup;
    int rc = libusb_get_active_config_descriptor(target, &config);
    if (rc < 0) goto cleanup;
    for (int i = 0; i < config->bNumInterfaces; i++) {
        const struct libusb_interface *interface = &config->interface[i];
        for (int j = 0; j < interface->num_altsetting; j++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[j];
            if (alt->bInterfaceClass == 2 && alt->bInterfaceSubClass == 0x0e)
                control = alt->bInterfaceNumber;
            if (alt->bInterfaceClass == 0x0a && alt->bAlternateSetting == 1) {
                for (int k = 0; k < alt->bNumEndpoints; k++) {
                    const struct libusb_endpoint_descriptor *ep = &alt->endpoint[k];
                    printf("data_endpoint=0x%02x max_packet=%u\n",
                           ep->bEndpointAddress, ep->wMaxPacketSize & 0x07ffu);
                }
            }
            for (int off = 0; off + 3 <= alt->extra_length;) {
                const unsigned char *extra = alt->extra + off;
                if (extra[0] < 3 || off + extra[0] > alt->extra_length) break;
                if (extra[0] >= 12 && extra[1] == 0x24 && extra[2] == 0x1b)
                    printf("mbim_max_segment=%u\n", u16(extra + 9));
                off += extra[0];
            }
        }
    }
    if (control < 0) goto cleanup;
    rc = libusb_open(target, &handle);
    if (rc < 0) { printf("open_error=%s\n", libusb_error_name(rc)); goto cleanup; }
    rc = libusb_claim_interface(handle, control);
    if (rc < 0) { printf("claim_error=%s\n", libusb_error_name(rc)); goto cleanup; }
    claimed = 1;
    unsigned char parameters[28] = {0};
    rc = query(handle, control, 0x80, parameters, sizeof(parameters));
    if (rc < 28 || u16(parameters) < 28) {
        printf("ntb_parameters_length=%d valid=0\n", rc);
        goto cleanup;
    }
    printf("ntb_formats=0x%x in_max=%u in_divisor=%u in_remainder=%u in_alignment=%u "
           "out_max=%u out_divisor=%u out_remainder=%u out_alignment=%u out_datagrams=%u\n",
           u16(parameters + 2), u32(parameters + 4), u16(parameters + 8),
           u16(parameters + 10), u16(parameters + 12), u32(parameters + 16),
           u16(parameters + 20), u16(parameters + 22), u16(parameters + 24),
           u16(parameters + 26));
    unsigned char format[2] = {0};
    if (query(handle, control, 0x83, format, sizeof(format)) == 2)
        printf("active_ntb_format=%u\n", u16(format));
    unsigned char size[8] = {0};
    rc = query(handle, control, 0x85, size, sizeof(size));
    if (rc >= 4) printf("active_ntb_input_size=%u\n", u32(size));
    result = 0;
cleanup:
    if (claimed) libusb_release_interface(handle, control);
    if (handle) libusb_close(handle);
    if (config) libusb_free_config_descriptor(config);
    if (devices) libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return result;
}
