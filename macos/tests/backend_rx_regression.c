/* Same local timeout input against shipped source and candidate source. */
#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static unsigned char returned_ntb[256];
static int returned_length, calls;
static int mock_bulk(libusb_device_handle *handle, unsigned char endpoint,
                     unsigned char *data, int length, int *transferred, unsigned int timeout) {
    (void)handle; (void)endpoint; (void)timeout;
    if (calls++ == 0 && length >= returned_length) {
        memcpy(data, returned_ntb, (size_t)returned_length);
        *transferred = returned_length;
        return LIBUSB_ERROR_TIMEOUT;
    }
    *transferred = 0;
    return LIBUSB_ERROR_NO_DEVICE;
}
#define libusb_bulk_transfer mock_bulk
#define main backend_main_never_executed
#ifdef BEFORE_FIX
#include "fixtures/mbim_net_0_2_2.c"
#else
#include "../backend/mbim_net.c"
#endif
#undef main
#undef libusb_bulk_transfer
int main(void) {
    struct net_context context = {0};
    uint8_t packet[20] = {0x45, 0, 0, 20};
    int descriptors[2];
    if (pipe(descriptors) != 0) return 2;
    context.utun_fd = descriptors[1];
    returned_length = build_ncm_ntb_from_packet(&context, packet, sizeof(packet), returned_ntb, sizeof(returned_ntb));
    if (returned_length <= 0) return 2;
    usb_to_utun_thread(&context);
    close(descriptors[0]); close(descriptors[1]);
    printf("rx_complete_ntb_on_timeout packets_delivered=%llu expected=1 USB_mocked=1\n",
           (unsigned long long)context.rx_packets);
    return context.rx_packets == 1 ? 0 : 1;
}
