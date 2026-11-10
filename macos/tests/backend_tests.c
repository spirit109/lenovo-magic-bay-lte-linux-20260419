#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libusb.h>

static uint8_t partial_ntb[256];
static int partial_ntb_length;
static int usb_mock_calls;
static int test_bulk_transfer(libusb_device_handle *handle, unsigned char endpoint,
                              unsigned char *data, int length, int *transferred,
                              unsigned int timeout) {
    (void)handle;
    (void)timeout;
    assert(endpoint == 0x81);
    if (usb_mock_calls++ == 0) {
        assert(length >= partial_ntb_length);
        memcpy(data, partial_ntb, (size_t)partial_ntb_length);
        *transferred = partial_ntb_length;
        return LIBUSB_ERROR_TIMEOUT;
    }
    *transferred = 0;
    return LIBUSB_ERROR_NO_DEVICE;
}

static const char *test_route_interface = "utun6";
static int command_count;
static char last_command[1024];
static int test_system(const char *command) {
    command_count++;
    snprintf(last_command, sizeof(last_command), "%s", command);
    return 0;
}
static FILE *test_popen(const char *command, const char *mode) {
    assert(strcmp(mode, "r") == 0);
    assert(strstr(command, "route -n get default"));
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    dprintf(descriptors[1], "gateway: 10.0.0.1\ninterface: %s\n", test_route_interface);
    close(descriptors[1]);
    return fdopen(descriptors[0], "r");
}
static int test_pclose(FILE *stream) { return fclose(stream); }

#define system test_system
#define popen test_popen
#define pclose test_pclose
#define libusb_bulk_transfer test_bulk_transfer
#define main backend_entrypoint_not_executed
#include "../backend/mbim_net.c"
#undef main
#undef system
#undef popen
#undef pclose
#undef libusb_bulk_transfer

int main(void) {
    struct takeover_state state = {0};
    state.enabled = 1;
    state.restore_on_exit = 1;
    state.route_changed = 1;
    snprintf(state.owned_interface, sizeof(state.owned_interface), "utun6");
    snprintf(state.owned_gateway, sizeof(state.owned_gateway), "10.0.0.1");
    state.previous_default.present = 1;
    snprintf(state.previous_default.gateway, sizeof(state.previous_default.gateway), "192.0.2.1");
    restore_network_takeover(&state);
    assert(command_count == 1);
    assert(strcmp(last_command, "/sbin/route -n change default 192.0.2.1") == 0);
    puts("PASS owned route restores previous gateway");

    command_count = 0;
    state.route_changed = 1;
    test_route_interface = "utun4";
    restore_network_takeover(&state);
    assert(command_count == 0);
    puts("PASS another VPN or Wi-Fi route is never overwritten on exit");

    state.route_changed = 1;
    state.previous_default.present = 0;
    test_route_interface = "utun6";
    restore_network_takeover(&state);
    assert(command_count == 1);
    assert(strcmp(last_command, "/sbin/route -n delete default 10.0.0.1") == 0);
    puts("PASS cleanup names the exact owned gateway");

    struct net_context context = {0};
    uint8_t packet[20] = {0x45};
    uint8_t ntb[256];
    int length = build_ncm_ntb_from_packet(&context, packet, sizeof(packet), ntb, sizeof(ntb));
    assert(length > 0);
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    context.utun_fd = descriptors[1];
    assert(parse_ncm_ntb_to_utun(&context, ntb, length) == 1);
    uint8_t received[24];
    assert(read(descriptors[0], received, sizeof(received)) == sizeof(received));
    assert(memcmp(received + 4, packet, sizeof(packet)) == 0);
    close(descriptors[0]);
    close(descriptors[1]);
    puts("PASS NCM packet round trip on local pipe only");
    assert(parse_ncm_ntb_to_utun(&context, ntb, 5) == 0);
    assert(build_ncm_ntb_from_packet(&context, packet, 0, ntb, sizeof(ntb)) < 0);
    puts("PASS malformed and empty packets rejected");

    uint8_t boundary_packet[996] = {0x45};
    uint8_t boundary_ntb[2048];
    const uint16_t boundary_lengths[] = {481, 482, 483, 484, 993, 994, 995, 996};
    for (unsigned i = 0; i < sizeof(boundary_lengths) / sizeof(boundary_lengths[0]); i++) {
        length = build_ncm_ntb_from_packet(&context, boundary_packet, boundary_lengths[i],
                                          boundary_ntb, sizeof(boundary_ntb));
        if (length <= 0 || length % 512 == 0) {
            fprintf(stderr, "FAIL NTB needs a terminating short packet: ip_length=%u ntb_length=%d\n",
                    boundary_lengths[i], length);
            return 1;
        }
        assert(get_u16le(boundary_ntb + 8) == length);
    }
    puts("PASS all eight 512-byte USB boundary cases terminate with a short packet");

    assert(build_ncm_ntb_from_packet(&context, boundary_packet, 484, boundary_ntb, 512) < 0);
    puts("PASS padding cannot overrun the output buffer");

    uint8_t parameters[28] = {0};
    put_u16le(parameters, 28);
    put_u16le(parameters + 2, 1);
    put_u32le(parameters + 4, 16384);
    put_u32le(parameters + 16, 4096);
    put_u16le(parameters + 20, 4);
    put_u16le(parameters + 24, 4);
    struct ncm_transport transport = {0};
    assert(parse_ncm_transport(parameters, 28, 512, &transport) == 0);
    assert(transport.in_max == 16384 && transport.out_max == 4096 && transport.max_packet == 512);
    puts("PASS live Magic Bay transport parameters decode independently of the encoder");

    assert(parse_ncm_transport(parameters, 27, 512, &transport) < 0);
    assert(parse_ncm_transport(parameters, 28, 0, &transport) < 0);
    put_u16le(parameters, 29);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    put_u16le(parameters, 28);
    put_u16le(parameters + 2, 2);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    put_u16le(parameters + 2, 1);
    put_u16le(parameters + 20, 0);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    put_u16le(parameters + 20, 4);
    put_u16le(parameters + 22, 4);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    put_u16le(parameters + 22, 0);
    put_u16le(parameters + 24, 3);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    put_u16le(parameters + 24, 4);
    put_u32le(parameters + 16, 65536);
    assert(parse_ncm_transport(parameters, 28, 512, &transport) < 0);
    puts("PASS malformed and unsupported negotiation is refused");

    context.transport = transport;
    context.transport.out_divisor = 8;
    context.transport.out_remainder = 4;
    context.transport.out_alignment = 16;
    length = build_ncm_ntb_from_packet(&context, boundary_packet, 484,
                                      boundary_ntb, sizeof(boundary_ntb));
    assert(length > 0);
    uint16_t ndp = get_u16le(boundary_ntb + 10);
    uint16_t payload = get_u16le(boundary_ntb + ndp + 8);
    assert(ndp % 16 == 0 && payload % 8 == 4);
    assert(get_u16le(boundary_ntb + ndp + 10) == 484);
    assert(memcmp(boundary_ntb + payload, boundary_packet, 484) == 0);
    puts("PASS negotiated payload remainder and NDP alignment are honored");

    context.transport = transport;
    context.transport.out_max = 512;
    assert(build_ncm_ntb_from_packet(&context, boundary_packet, 484,
                                    boundary_ntb, sizeof(boundary_ntb)) == 512);
    context.transport.out_max = 511;
    assert(build_ncm_ntb_from_packet(&context, boundary_packet, 484,
                                    boundary_ntb, sizeof(boundary_ntb)) < 0);
    memset(&context.transport, 0, sizeof(context.transport));
    puts("PASS full negotiated NTB terminates without padding and cannot exceed its maximum");

    assert(pipe(descriptors) == 0);
    context.utun_fd = descriptors[1];
    context.bulk_in = 0x81;
    context.rx_packets = 0;
    partial_ntb_length = build_ncm_ntb_from_packet(&context, packet, sizeof(packet),
                                                  partial_ntb, sizeof(partial_ntb));
    assert(partial_ntb_length > 0);
    usb_mock_calls = 0;
    stop_requested = 0;
    usb_to_utun_thread(&context);
    assert(context.rx_packets == 1 && usb_mock_calls == 2 && stop_requested == 1);
    assert(read(descriptors[0], received, sizeof(received)) == sizeof(received));
    assert(memcmp(received + 4, packet, sizeof(packet)) == 0);
    close(descriptors[0]);
    close(descriptors[1]);
    puts("PASS complete NTB bytes on receive timeout are delivered, while NO_DEVICE still stops");

    assert(pipe(descriptors) == 0);
    context.utun_fd = descriptors[0];
    close(descriptors[0]);
    close(descriptors[1]);
    stop_requested = 0;
    utun_to_usb_thread(&context);
    assert(stop_requested == 1);
    puts("PASS failed transmit worker requests daemon shutdown");
    assert(pipe(descriptors) == 0);
    context.utun_fd = descriptors[0];
    close(descriptors[1]);
    stop_requested = 0;
    utun_to_usb_thread(&context);
    assert(stop_requested == 1);
    close(descriptors[0]);
    puts("PASS closed interface exits rather than spinning");
    command_count = 0;
    restore_or_remove_takeover_route(&state, "203.0.113.1");
    assert(command_count == 0);
    puts("PASS failed takeover cannot roll back an unrelated gateway");
    puts("ALL 15 BACKEND TESTS PASSED; system and route commands mocked; USB never opened");
    return 0;
}
