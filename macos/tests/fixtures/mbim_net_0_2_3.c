#include <errno.h>
#include <libusb.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define LENOVO_VENDOR_ID 0x17ef
#define MAGIC_BAY_LTE_PRODUCT_ID 0x7240

#define USB_CDC_SEND_ENCAPSULATED_COMMAND 0x00
#define USB_CDC_GET_ENCAPSULATED_RESPONSE 0x01

#define MBIM_OPEN_MSG 0x00000001u
#define MBIM_OPEN_DONE 0x80000001u
#define MBIM_CLOSE_MSG 0x00000002u
#define MBIM_CLOSE_DONE 0x80000002u
#define MBIM_COMMAND_MSG 0x00000003u
#define MBIM_COMMAND_DONE 0x80000003u
#define MBIM_INDICATE_STATUS_MSG 0x80000007u

#define MBIM_STATUS_SUCCESS 0x00000000u
#define MBIM_COMMAND_TYPE_QUERY 0u
#define MBIM_COMMAND_TYPE_SET 1u
#define MBIM_CID_DEVICE_CAPS 1u
#define MBIM_CID_SUBSCRIBER_READY_STATUS 2u
#define MBIM_CID_RADIO_STATE 3u
#define MBIM_CID_REGISTER_STATE 9u
#define MBIM_CID_PACKET_SERVICE 10u
#define MBIM_CID_SIGNAL_STATE 11u
#define MBIM_CID_CONNECT 12u
#define MBIM_CID_IP_CONFIGURATION 15u

#define MBIM_ACTIVATION_COMMAND_DEACTIVATE 0u
#define MBIM_ACTIVATION_COMMAND_ACTIVATE 1u
#define MBIM_COMPRESSION_NONE 0u
#define MBIM_AUTH_PROTOCOL_NONE 0u
#define MBIM_CONTEXT_IP_TYPE_DEFAULT 0u
#define MBIM_CONTEXT_IP_TYPE_IPV4 1u
#define MBIM_PACKET_SERVICE_ACTION_ATTACH 0u

#define ACTION_PROBE 0
#define ACTION_STATUS 1
#define ACTION_CONNECT_TEST 2
#define ACTION_ACTIVATE 3
#define ACTION_DEACTIVATE 4
#define ACTION_HOLD 5

#define ACTION_RUN_NET 6

#define NCM_NTH16_SIGNATURE 0x484d434eu
#define NCM_NDP16_IPS_SESSION0_SIGNATURE 0x00535049u
#define NCM_NTH16_LENGTH 12u
#define NCM_NDP16_ONE_DPE_LENGTH 16u
#define MBIM_NET_MAX_NTB_SIZE 16384
#define MBIM_NET_MAX_PACKET_SIZE 2048
#define MBIM_NET_DEFAULT_MTU 1500
#define MBIM_NET_DNS_SERVICE_ID "7E2F4BC0-4241-4C54-8B49-4D42494D5632"

static const uint8_t MBIM_UUID_BASIC_CONNECT[16] = {
    0xa2, 0x89, 0xcc, 0x33, 0xbc, 0xbb, 0x8b, 0x4f,
    0xb6, 0xb0, 0x13, 0x3e, 0xc2, 0xaa, 0xe6, 0xdf,
};

static const uint8_t MBIM_UUID_CONTEXT_TYPE_INTERNET[16] = {
    0x7e, 0x5e, 0x2a, 0x7e, 0x4e, 0x6f, 0x72, 0x72,
    0x73, 0x6b, 0x65, 0x6e, 0x7e, 0x5e, 0x2a, 0x7e,
};

static volatile sig_atomic_t stop_requested = 0;

struct ipv4_config {
    int have_address;
    uint8_t address[4];
    uint32_t prefix;
    int have_gateway;
    uint8_t gateway[4];
    uint32_t dns_count;
    uint8_t dns[4][4];
    uint32_t mtu;
};

struct data_endpoints {
    int interface_number;
    uint8_t bulk_in;
    uint8_t bulk_out;
    uint16_t bulk_out_max_packet;
};

struct ncm_transport {
    uint32_t in_max;
    uint32_t out_max;
    uint16_t out_divisor;
    uint16_t out_remainder;
    uint16_t out_alignment;
    uint16_t max_packet;
};

struct net_context {
    libusb_device_handle *handle;
    uint8_t bulk_in;
    uint8_t bulk_out;
    int utun_fd;
    struct ncm_transport transport;
    uint16_t tx_sequence;
    uint64_t rx_packets;
    uint64_t tx_packets;
    uint64_t rx_bytes;
    uint64_t tx_bytes;
};

struct default_route_snapshot {
    int present;
    char gateway[64];
    char interface_name[IFNAMSIZ];
};

struct takeover_state {
    int enabled;
    int restore_on_exit;
    int configure_dns;
    int route_changed;
    int dns_configured;
    char owned_interface[IFNAMSIZ];
    char owned_gateway[INET_ADDRSTRLEN];
    struct default_route_snapshot previous_default;
};

static void handle_stop_signal(int signum) {
    (void)signum;
    stop_requested = 1;
}

static void put_u32le(uint8_t *buf, uint32_t value) {
    buf[0] = (uint8_t)(value & 0xffu);
    buf[1] = (uint8_t)((value >> 8) & 0xffu);
    buf[2] = (uint8_t)((value >> 16) & 0xffu);
    buf[3] = (uint8_t)((value >> 24) & 0xffu);
}

static void put_u16le(uint8_t *buf, uint16_t value) {
    buf[0] = (uint8_t)(value & 0xffu);
    buf[1] = (uint8_t)((value >> 8) & 0xffu);
}

static uint16_t get_u16le(const uint8_t *buf) {
    return (uint16_t)(((uint16_t)buf[0]) | ((uint16_t)buf[1] << 8));
}

static uint32_t get_u32le(const uint8_t *buf) {
    return ((uint32_t)buf[0]) |
           ((uint32_t)buf[1] << 8) |
           ((uint32_t)buf[2] << 16) |
           ((uint32_t)buf[3] << 24);
}

static uint64_t get_u64le(const uint8_t *buf) {
    return ((uint64_t)get_u32le(buf)) | ((uint64_t)get_u32le(buf + 4) << 32);
}

static uint32_t align4(uint32_t value) {
    return (value + 3u) & ~3u;
}

static uint32_t append_utf16le_ascii_string(uint8_t *buf, uint32_t capacity, uint32_t offset, const char *value) {
    if (!value || !value[0]) {
        return 0;
    }

    uint32_t bytes = (uint32_t)strlen(value) * 2u;
    if (offset > capacity || bytes > capacity - offset) {
        return 0;
    }

    for (uint32_t i = 0; value[i]; i++) {
        buf[offset + (i * 2u)] = (uint8_t)value[i];
        buf[offset + (i * 2u) + 1u] = 0;
    }

    uint32_t padded = align4(bytes);
    if (padded > bytes && offset + padded <= capacity) {
        memset(buf + offset + bytes, 0, padded - bytes);
    }
    return bytes;
}

static const char *activation_state_name(uint32_t value) {
    switch (value) {
    case 0:
        return "Unknown";
    case 1:
        return "Activated";
    case 2:
        return "Activating";
    case 3:
        return "Deactivated";
    case 4:
        return "Deactivating";
    default:
        return "Unrecognized";
    }
}

static const char *ip_type_name(uint32_t value) {
    switch (value) {
    case 0:
        return "Default";
    case 1:
        return "IPv4";
    case 2:
        return "IPv6";
    case 3:
        return "IPv4v6";
    default:
        return "Unrecognized";
    }
}

static const char *status_error_name(uint32_t value) {
    switch (value) {
    case 0:
        return "Success";
    case 14:
        return "NotInitialized";
    case 16:
        return "ContextNotActivated";
    case 18:
        return "InvalidAccessString";
    case 19:
        return "InvalidUserNamePassword";
    case 20:
        return "RadioPowerOff";
    case 21:
        return "InvalidParameters";
    default:
        return "StatusError";
    }
}

static int parse_ip_type_arg(const char *value, uint32_t *ip_type) {
    if (strcmp(value, "default") == 0 || strcmp(value, "0") == 0) {
        *ip_type = 0;
        return 0;
    }
    if (strcmp(value, "ipv4") == 0 || strcmp(value, "1") == 0) {
        *ip_type = 1;
        return 0;
    }
    if (strcmp(value, "ipv6") == 0 || strcmp(value, "2") == 0) {
        *ip_type = 2;
        return 0;
    }
    if (strcmp(value, "ipv4v6") == 0 || strcmp(value, "3") == 0) {
        *ip_type = 3;
        return 0;
    }
    if (strcmp(value, "both") == 0 || strcmp(value, "4") == 0) {
        *ip_type = 4;
        return 0;
    }
    return -1;
}

static int set_action(int *action, int new_action) {
    if (*action != ACTION_PROBE) {
        return -1;
    }
    *action = new_action;
    return 0;
}

static void print_ipv4_value(const uint8_t *addr) {
    printf("%u.%u.%u.%u", addr[0], addr[1], addr[2], addr[3]);
}

static void print_ipv6_value(const uint8_t *addr) {
    for (int i = 0; i < 16; i += 2) {
        if (i > 0) {
            putchar(':');
        }
        printf("%02x%02x", addr[i], addr[i + 1]);
    }
}

static int read_ref_offset(const uint8_t *base, uint32_t base_len, uint32_t field_offset, uint32_t item_size, const uint8_t **ptr) {
    *ptr = NULL;
    if (field_offset > base_len || 4u > base_len - field_offset) {
        return -1;
    }
    uint32_t offset = get_u32le(base + field_offset);
    if (offset == 0) {
        return 0;
    }
    if (offset > base_len || item_size > base_len - offset) {
        return -1;
    }
    *ptr = base + offset;
    return 0;
}

static void print_utf16le_field(const char *label, const uint8_t *base, uint32_t base_len, uint32_t offset, uint32_t size) {
    printf("%s=", label);
    if (size == 0) {
        printf("(empty)\n");
        return;
    }
    if (offset > base_len || size > base_len - offset) {
        printf("(invalid offset=%u size=%u)\n", offset, size);
        return;
    }
    for (uint32_t i = 0; i + 1 < size; i += 2) {
        uint16_t ch = (uint16_t)base[offset + i] | ((uint16_t)base[offset + i + 1] << 8);
        if (ch == 0) {
            continue;
        }
        if (ch >= 32 && ch <= 126) {
            putchar((char)ch);
        } else {
            putchar('?');
        }
    }
    putchar('\n');
}

static void dump_hex(const char *label, const uint8_t *buf, int len, int limit) {
    int shown = len < limit ? len : limit;
    printf("%s (%d bytes", label, len);
    if (shown < len) {
        printf(", first %d", shown);
    }
    printf("):");
    for (int i = 0; i < shown; i++) {
        if (i % 16 == 0) {
            printf("\n  ");
        }
        printf("%02x ", buf[i]);
    }
    printf("\n");
}

static void print_config(
    const struct libusb_config_descriptor *cfg,
    int *mbim_control_if,
    int *mbim_data_if,
    uint8_t *mbim_interrupt_ep,
    struct data_endpoints *data_eps) {
    printf("configuration %u: interfaces=%u, attributes=0x%02x, max_power=%umA\n",
           cfg->bConfigurationValue, cfg->bNumInterfaces, cfg->bmAttributes,
           cfg->MaxPower * 2u);

    for (int i = 0; i < cfg->bNumInterfaces; i++) {
        const struct libusb_interface *iface = &cfg->interface[i];
        for (int j = 0; j < iface->num_altsetting; j++) {
            const struct libusb_interface_descriptor *alt = &iface->altsetting[j];
            printf("  interface=%u alt=%u class=0x%02x subclass=0x%02x protocol=0x%02x endpoints=%u",
                   alt->bInterfaceNumber, alt->bAlternateSetting, alt->bInterfaceClass,
                   alt->bInterfaceSubClass, alt->bInterfaceProtocol, alt->bNumEndpoints);
            if (alt->iInterface) {
                printf(" iInterface=%u", alt->iInterface);
            }
            printf("\n");
            if (alt->bInterfaceClass == 0x02 && alt->bInterfaceSubClass == 0x0e && *mbim_control_if < 0) {
                *mbim_control_if = alt->bInterfaceNumber;
            }
            if (alt->bInterfaceClass == 0x0a && alt->bAlternateSetting == 1 && *mbim_data_if < 0) {
                *mbim_data_if = alt->bInterfaceNumber;
                if (data_eps) {
                    data_eps->interface_number = alt->bInterfaceNumber;
                }
            }
            for (int k = 0; k < alt->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[k];
                printf("    endpoint=0x%02x attrs=0x%02x max_packet=%u interval=%u\n",
                       ep->bEndpointAddress, ep->bmAttributes,
                       ep->wMaxPacketSize, ep->bInterval);
                if (alt->bInterfaceClass == 0x02 &&
                    alt->bInterfaceSubClass == 0x0e &&
                    (ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) == LIBUSB_TRANSFER_TYPE_INTERRUPT &&
                    (ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                    *mbim_interrupt_ep = ep->bEndpointAddress;
                }
                if (data_eps &&
                    alt->bInterfaceClass == 0x0a &&
                    alt->bAlternateSetting == 1 &&
                    (ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) == LIBUSB_TRANSFER_TYPE_BULK) {
                    if ((ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                        data_eps->bulk_in = ep->bEndpointAddress;
                    } else {
                        data_eps->bulk_out = ep->bEndpointAddress;
                        data_eps->bulk_out_max_packet = ep->wMaxPacketSize & 0x07ffu;
                    }
                }
            }
            if (alt->extra_length > 0) {
                dump_hex("    extra descriptors", alt->extra, alt->extra_length, 96);
            }
        }
    }
}

static int send_mbim_message(libusb_device_handle *handle, int iface, const uint8_t *msg, uint16_t len) {
    int transferred = libusb_control_transfer(
        handle,
        LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
        USB_CDC_SEND_ENCAPSULATED_COMMAND,
        0,
        (uint16_t)iface,
        (unsigned char *)msg,
        len,
        3000);
    if (transferred < 0) {
        fprintf(stderr, "SEND_ENCAPSULATED_COMMAND failed: %s\n", libusb_error_name(transferred));
        return transferred;
    }
    if (transferred != len) {
        fprintf(stderr, "short SEND_ENCAPSULATED_COMMAND: %d/%u\n", transferred, len);
        return LIBUSB_ERROR_IO;
    }
    return 0;
}

static void wait_for_response_notification(libusb_device_handle *handle, uint8_t interrupt_ep) {
    uint8_t note[64] = {0};
    int transferred = 0;

    if (!interrupt_ep) {
        printf("no MBIM interrupt endpoint found; polling response directly\n");
        return;
    }

    for (int attempt = 0; attempt < 10; attempt++) {
        int rc = libusb_interrupt_transfer(handle, interrupt_ep, note, sizeof(note), &transferred, 500);
        if (rc == 0 && transferred > 0) {
            dump_hex("MBIM interrupt notification", note, transferred, 64);
            return;
        }
        if (rc != LIBUSB_ERROR_TIMEOUT) {
            fprintf(stderr, "interrupt read failed: %s\n", libusb_error_name(rc));
            return;
        }
    }
    printf("no interrupt notification before response polling\n");
}

static int read_mbim_response(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint8_t *buf,
    uint16_t len,
    uint32_t expected_type,
    uint32_t expected_txid) {
    wait_for_response_notification(handle, interrupt_ep);

    for (int attempt = 0; attempt < 40; attempt++) {
        int received = libusb_control_transfer(
            handle,
            LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE,
            USB_CDC_GET_ENCAPSULATED_RESPONSE,
            0,
            (uint16_t)iface,
            buf,
            len,
            3000);
        if (received > 0) {
            if (received >= 12) {
                uint32_t type = get_u32le(&buf[0]);
                uint32_t txid = get_u32le(&buf[8]);
                if ((expected_type == 0 || type == expected_type) &&
                    (expected_txid == 0 || txid == expected_txid)) {
                    return received;
                }
                if (type == MBIM_INDICATE_STATUS_MSG) {
                    dump_hex("MBIM unsolicited indication", buf, received, 96);
                } else {
                    dump_hex("MBIM non-matching response", buf, received, 96);
                }
                continue;
            }
            return received;
        }
        if (received < 0 && received != LIBUSB_ERROR_PIPE && received != LIBUSB_ERROR_TIMEOUT) {
            fprintf(stderr, "GET_ENCAPSULATED_RESPONSE failed: %s\n", libusb_error_name(received));
            return received;
        }
        usleep(100 * 1000);
    }
    return LIBUSB_ERROR_TIMEOUT;
}

static int mbim_open(libusb_device_handle *handle, int iface, uint8_t interrupt_ep, uint32_t *txid) {
    uint8_t msg[16] = {0};
    uint8_t rsp[4096] = {0};

    put_u32le(&msg[0], MBIM_OPEN_MSG);
    put_u32le(&msg[4], sizeof(msg));
    put_u32le(&msg[8], ++(*txid));
    put_u32le(&msg[12], 4096);

    printf("sending MBIM_OPEN on interface %d\n", iface);
    int rc = send_mbim_message(handle, iface, msg, sizeof(msg));
    if (rc < 0) {
        return rc;
    }

    int len = read_mbim_response(handle, iface, interrupt_ep, rsp, sizeof(rsp), MBIM_OPEN_DONE, *txid);
    if (len < 0) {
        fprintf(stderr, "MBIM_OPEN response failed: %s\n", libusb_error_name(len));
        return len;
    }
    dump_hex("MBIM_OPEN response", rsp, len, 64);

    if (len < 16 || get_u32le(&rsp[0]) != MBIM_OPEN_DONE || get_u32le(&rsp[8]) != *txid) {
        fprintf(stderr, "unexpected MBIM_OPEN response\n");
        return LIBUSB_ERROR_IO;
    }
    uint32_t status = get_u32le(&rsp[12]);
    printf("MBIM_OPEN status=0x%08x%s\n", status, status == MBIM_STATUS_SUCCESS ? " (success)" : "");
    return status == MBIM_STATUS_SUCCESS ? 0 : LIBUSB_ERROR_OTHER;
}

static int mbim_query_device_caps(libusb_device_handle *handle, int iface, uint8_t interrupt_ep, uint32_t *txid) {
    uint8_t msg[48] = {0};
    uint8_t rsp[4096] = {0};

    put_u32le(&msg[0], MBIM_COMMAND_MSG);
    put_u32le(&msg[4], sizeof(msg));
    put_u32le(&msg[8], ++(*txid));
    put_u32le(&msg[12], 1); /* total fragments */
    put_u32le(&msg[16], 0); /* current fragment */
    memcpy(&msg[20], MBIM_UUID_BASIC_CONNECT, sizeof(MBIM_UUID_BASIC_CONNECT));
    put_u32le(&msg[36], MBIM_CID_DEVICE_CAPS);
    put_u32le(&msg[40], 0); /* query */
    put_u32le(&msg[44], 0); /* no information buffer */

    printf("querying MBIM_DEVICE_CAPS\n");
    int rc = send_mbim_message(handle, iface, msg, sizeof(msg));
    if (rc < 0) {
        return rc;
    }

    int len = read_mbim_response(handle, iface, interrupt_ep, rsp, sizeof(rsp), MBIM_COMMAND_DONE, *txid);
    if (len < 0) {
        fprintf(stderr, "MBIM_DEVICE_CAPS response failed: %s\n", libusb_error_name(len));
        return len;
    }
    if (len < 48 || get_u32le(&rsp[0]) != MBIM_COMMAND_DONE || get_u32le(&rsp[8]) != *txid) {
        fprintf(stderr, "unexpected MBIM_DEVICE_CAPS response\n");
        return LIBUSB_ERROR_IO;
    }
    uint32_t cid = get_u32le(&rsp[36]);
    uint32_t status = get_u32le(&rsp[40]);
    uint32_t info_len = get_u32le(&rsp[44]);
    printf("MBIM_DEVICE_CAPS cid=%u status=0x%08x%s info_len=%u\n",
           cid, status, status == MBIM_STATUS_SUCCESS ? " (success)" : "", info_len);
    if (status == MBIM_STATUS_SUCCESS && info_len >= 64 && len >= 48 + (int)info_len) {
        const uint8_t *info = &rsp[48];
        printf("  device_type=%u cellular_class=0x%08x voice_class=0x%08x sim_class=0x%08x\n",
               get_u32le(info), get_u32le(info + 4), get_u32le(info + 8), get_u32le(info + 12));
        printf("  data_class=0x%08x sms_caps=0x%08x control_caps=0x%08x max_sessions=%u\n",
               get_u32le(info + 16), get_u32le(info + 20), get_u32le(info + 24), get_u32le(info + 28));
        print_utf16le_field("  device_id", info, info_len, get_u32le(info + 40), get_u32le(info + 44));
        print_utf16le_field("  firmware", info, info_len, get_u32le(info + 48), get_u32le(info + 52));
        print_utf16le_field("  hardware", info, info_len, get_u32le(info + 56), get_u32le(info + 60));
    }
    return status == MBIM_STATUS_SUCCESS ? 0 : LIBUSB_ERROR_OTHER;
}

static int mbim_command_cid(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t cid,
    uint32_t command_type,
    const uint8_t *info_in,
    uint32_t info_in_len,
    uint8_t *info_out,
    uint32_t info_out_capacity,
    uint32_t *info_out_len) {
    uint8_t msg[4096] = {0};
    uint8_t rsp[4096] = {0};
    uint32_t msg_len = 48u + info_in_len;

    if (msg_len > sizeof(msg)) {
        return LIBUSB_ERROR_OVERFLOW;
    }

    put_u32le(&msg[0], MBIM_COMMAND_MSG);
    put_u32le(&msg[4], msg_len);
    put_u32le(&msg[8], ++(*txid));
    put_u32le(&msg[12], 1);
    put_u32le(&msg[16], 0);
    memcpy(&msg[20], MBIM_UUID_BASIC_CONNECT, sizeof(MBIM_UUID_BASIC_CONNECT));
    put_u32le(&msg[36], cid);
    put_u32le(&msg[40], command_type);
    put_u32le(&msg[44], info_in_len);
    if (info_in_len > 0) {
        memcpy(&msg[48], info_in, info_in_len);
    }

    int rc = send_mbim_message(handle, iface, msg, (uint16_t)msg_len);
    if (rc < 0) {
        return rc;
    }

    int len = read_mbim_response(handle, iface, interrupt_ep, rsp, sizeof(rsp), MBIM_COMMAND_DONE, *txid);
    if (len < 0) {
        return len;
    }
    if (len < 48 || get_u32le(&rsp[0]) != MBIM_COMMAND_DONE || get_u32le(&rsp[8]) != *txid) {
        return LIBUSB_ERROR_IO;
    }

    uint32_t rsp_cid = get_u32le(&rsp[36]);
    uint32_t status = get_u32le(&rsp[40]);
    uint32_t info_len = get_u32le(&rsp[44]);
    printf("MBIM cid=%u command_type=%u status=0x%08x (%s) info_len=%u\n",
           rsp_cid, command_type, status, status_error_name(status), info_len);

    if (status != MBIM_STATUS_SUCCESS) {
        return LIBUSB_ERROR_OTHER;
    }
    if (info_len > 0 && (len < 48 || info_len > (uint32_t)(len - 48))) {
        return LIBUSB_ERROR_IO;
    }
    if (info_len > info_out_capacity) {
        return LIBUSB_ERROR_OVERFLOW;
    }
    if (info_len > 0 && info_out) {
        memcpy(info_out, &rsp[48], info_len);
    }
    if (info_out_len) {
        *info_out_len = info_len;
    }
    return 0;
}

static int mbim_query_cid(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t cid,
    uint8_t *info,
    uint32_t info_capacity,
    uint32_t *info_len_out) {
    uint32_t empty = 0;
    if (info_len_out) {
        *info_len_out = 0;
    }
    return mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        cid,
        MBIM_COMMAND_TYPE_QUERY,
        NULL,
        empty,
        info,
        info_capacity,
        info_len_out);
}

static void print_basic_status(libusb_device_handle *handle, int iface, uint8_t interrupt_ep, uint32_t *txid) {
    uint8_t info[512] = {0};
    uint32_t info_len = 0;

    printf("querying MBIM_SUBSCRIBER_READY_STATUS\n");
    if (mbim_query_cid(handle, iface, interrupt_ep, txid, MBIM_CID_SUBSCRIBER_READY_STATUS, info, sizeof(info), &info_len) == 0 && info_len >= 4) {
        printf("  ready_state=%u\n", get_u32le(info));
    }

    printf("querying MBIM_RADIO_STATE\n");
    if (mbim_query_cid(handle, iface, interrupt_ep, txid, MBIM_CID_RADIO_STATE, info, sizeof(info), &info_len) == 0 && info_len >= 8) {
        printf("  hw_radio_state=%u sw_radio_state=%u\n", get_u32le(info), get_u32le(info + 4));
    }

    printf("querying MBIM_REGISTER_STATE\n");
    if (mbim_query_cid(handle, iface, interrupt_ep, txid, MBIM_CID_REGISTER_STATE, info, sizeof(info), &info_len) == 0 && info_len >= 48) {
        printf("  nw_error=%u register_state=%u register_mode=%u available_data_classes=0x%08x current_cellular_class=0x%08x registration_flag=0x%08x\n",
               get_u32le(info), get_u32le(info + 4), get_u32le(info + 8),
               get_u32le(info + 12), get_u32le(info + 16), get_u32le(info + 44));
        print_utf16le_field("  provider_id", info, info_len, get_u32le(info + 20), get_u32le(info + 24));
        print_utf16le_field("  provider_name", info, info_len, get_u32le(info + 28), get_u32le(info + 32));
    }

    printf("querying MBIM_PACKET_SERVICE\n");
    if (mbim_query_cid(handle, iface, interrupt_ep, txid, MBIM_CID_PACKET_SERVICE, info, sizeof(info), &info_len) == 0 && info_len >= 24) {
        printf("  nw_error=%u packet_service_state=%u highest_data_class=0x%08x uplink_bps=%llu downlink_bps=%llu\n",
               get_u32le(info), get_u32le(info + 4), get_u32le(info + 8),
               (unsigned long long)get_u64le(info + 12), (unsigned long long)get_u64le(info + 20));
    }

    printf("querying MBIM_SIGNAL_STATE\n");
    if (mbim_query_cid(handle, iface, interrupt_ep, txid, MBIM_CID_SIGNAL_STATE, info, sizeof(info), &info_len) == 0 && info_len >= 8) {
        printf("  rssi=%u error_rate=%u\n", get_u32le(info), get_u32le(info + 4));
    }
}

static uint32_t build_connect_info(uint8_t *info, uint32_t capacity, uint32_t activation_command, const char *apn, uint32_t ip_type) {
    const uint32_t fixed_len = 60;
    uint32_t variable_offset = fixed_len;

    if (capacity < fixed_len) {
        return 0;
    }
    memset(info, 0, capacity);

    put_u32le(info + 0, 0); /* session id */
    put_u32le(info + 4, activation_command);

    if (activation_command == MBIM_ACTIVATION_COMMAND_ACTIVATE && apn && apn[0]) {
        uint32_t apn_bytes = append_utf16le_ascii_string(info, capacity, variable_offset, apn);
        if (apn_bytes == 0) {
            return 0;
        }
        put_u32le(info + 8, variable_offset);
        put_u32le(info + 12, apn_bytes);
        variable_offset += align4(apn_bytes);
    }

    put_u32le(info + 32, MBIM_COMPRESSION_NONE);
    put_u32le(info + 36, MBIM_AUTH_PROTOCOL_NONE);
    put_u32le(info + 40, ip_type);
    memcpy(info + 44, MBIM_UUID_CONTEXT_TYPE_INTERNET, sizeof(MBIM_UUID_CONTEXT_TYPE_INTERNET));

    return variable_offset;
}

static void print_connect_info(const char *label, const uint8_t *info, uint32_t info_len) {
    printf("%s\n", label);
    if (info_len < 36) {
        printf("  connect info too short: %u\n", info_len);
        return;
    }

    uint32_t activation = get_u32le(info + 4);
    uint32_t ip_type = get_u32le(info + 12);
    printf("  session_id=%u activation_state=%u (%s) voice_call_state=%u ip_type=%u (%s) nw_error=%u\n",
           get_u32le(info), activation, activation_state_name(activation),
           get_u32le(info + 8), ip_type, ip_type_name(ip_type), get_u32le(info + 32));
    if (memcmp(info + 16, MBIM_UUID_CONTEXT_TYPE_INTERNET, sizeof(MBIM_UUID_CONTEXT_TYPE_INTERNET)) == 0) {
        printf("  context_type=Internet\n");
    } else {
        dump_hex("  context_type", info + 16, 16, 16);
    }
}

static int mbim_connect_set(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t activation_command,
    const char *apn,
    uint32_t ip_type,
    uint32_t *activation_state_out) {
    uint8_t req[256] = {0};
    uint8_t info[512] = {0};
    uint32_t info_len = 0;
    uint32_t req_len = build_connect_info(req, sizeof(req), activation_command, apn, ip_type);

    if (req_len == 0) {
        fprintf(stderr, "failed to build MBIM_CONNECT request\n");
        return LIBUSB_ERROR_OVERFLOW;
    }

    printf("sending MBIM_CONNECT %s session_id=0 ip_type=%u (%s)",
           activation_command == MBIM_ACTIVATION_COMMAND_ACTIVATE ? "activate" : "deactivate",
           ip_type,
           ip_type_name(ip_type));
    if (activation_command == MBIM_ACTIVATION_COMMAND_ACTIVATE && apn && apn[0]) {
        printf(" apn=%s", apn);
    }
    printf("\n");

    int rc = mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_CID_CONNECT,
        MBIM_COMMAND_TYPE_SET,
        req,
        req_len,
        info,
        sizeof(info),
        &info_len);
    if (rc == 0) {
        print_connect_info("MBIM_CONNECT set response", info, info_len);
        if (activation_state_out && info_len >= 8) {
            *activation_state_out = get_u32le(info + 4);
        }
    }
    return rc;
}

static int mbim_query_connect(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t *activation_state_out) {
    uint8_t req[4] = {0};
    uint8_t info[512] = {0};
    uint32_t info_len = 0;

    put_u32le(req, 0);
    printf("querying MBIM_CONNECT state\n");
    int rc = mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_CID_CONNECT,
        MBIM_COMMAND_TYPE_QUERY,
        req,
        sizeof(req),
        info,
        sizeof(info),
        &info_len);
    if (rc == 0) {
        print_connect_info("MBIM_CONNECT query response", info, info_len);
        if (activation_state_out && info_len >= 8) {
            *activation_state_out = get_u32le(info + 4);
        }
    }
    return rc;
}

static void print_ip_configuration(const uint8_t *info, uint32_t info_len) {
    printf("MBIM_IP_CONFIGURATION parsed\n");
    if (info_len < 60) {
        printf("  ip configuration info too short: %u\n", info_len);
        dump_hex("  raw ip configuration", info, (int)info_len, 160);
        return;
    }

    uint32_t ipv4_count = get_u32le(info + 12);
    uint32_t ipv4_offset = get_u32le(info + 16);
    uint32_t ipv6_count = get_u32le(info + 20);
    uint32_t ipv6_offset = get_u32le(info + 24);
    uint32_t ipv4_dns_count = get_u32le(info + 36);
    uint32_t ipv4_dns_offset = get_u32le(info + 40);
    uint32_t ipv6_dns_count = get_u32le(info + 44);
    uint32_t ipv6_dns_offset = get_u32le(info + 48);

    printf("  session_id=%u ipv4_flags=0x%08x ipv6_flags=0x%08x ipv4_mtu=%u ipv6_mtu=%u\n",
           get_u32le(info), get_u32le(info + 4), get_u32le(info + 8),
           get_u32le(info + 52), get_u32le(info + 56));

    if (ipv4_count > 0 && ipv4_offset > 0 && ipv4_offset <= info_len && ipv4_count <= (info_len - ipv4_offset) / 8u) {
        for (uint32_t i = 0; i < ipv4_count; i++) {
            const uint8_t *entry = info + ipv4_offset + (i * 8u);
            printf("  ipv4_address[%u]=", i);
            print_ipv4_value(entry + 4);
            printf("/%u\n", get_u32le(entry));
        }
    } else {
        printf("  ipv4_address_count=%u\n", ipv4_count);
    }

    if (ipv6_count > 0 && ipv6_offset > 0 && ipv6_offset <= info_len && ipv6_count <= (info_len - ipv6_offset) / 20u) {
        for (uint32_t i = 0; i < ipv6_count; i++) {
            const uint8_t *entry = info + ipv6_offset + (i * 20u);
            printf("  ipv6_address[%u]=", i);
            print_ipv6_value(entry + 4);
            printf("/%u\n", get_u32le(entry));
        }
    } else {
        printf("  ipv6_address_count=%u\n", ipv6_count);
    }

    const uint8_t *gateway = NULL;
    if (read_ref_offset(info, info_len, 28, 4, &gateway) == 0 && gateway) {
        printf("  ipv4_gateway=");
        print_ipv4_value(gateway);
        putchar('\n');
    }
    if (read_ref_offset(info, info_len, 32, 16, &gateway) == 0 && gateway) {
        printf("  ipv6_gateway=");
        print_ipv6_value(gateway);
        putchar('\n');
    }

    if (ipv4_dns_count > 0 && ipv4_dns_offset > 0 && ipv4_dns_offset <= info_len && ipv4_dns_count <= (info_len - ipv4_dns_offset) / 4u) {
        for (uint32_t i = 0; i < ipv4_dns_count; i++) {
            printf("  ipv4_dns[%u]=", i);
            print_ipv4_value(info + ipv4_dns_offset + (i * 4u));
            putchar('\n');
        }
    } else {
        printf("  ipv4_dns_count=%u\n", ipv4_dns_count);
    }

    if (ipv6_dns_count > 0 && ipv6_dns_offset > 0 && ipv6_dns_offset <= info_len && ipv6_dns_count <= (info_len - ipv6_dns_offset) / 16u) {
        for (uint32_t i = 0; i < ipv6_dns_count; i++) {
            printf("  ipv6_dns[%u]=", i);
            print_ipv6_value(info + ipv6_dns_offset + (i * 16u));
            putchar('\n');
        }
    } else {
        printf("  ipv6_dns_count=%u\n", ipv6_dns_count);
    }
}

static void ipv4_to_string(const uint8_t addr[4], char *buf, size_t len) {
    snprintf(buf, len, "%u.%u.%u.%u", addr[0], addr[1], addr[2], addr[3]);
}

static uint32_t prefix_to_netmask(uint32_t prefix) {
    if (prefix == 0) {
        return 0;
    }
    if (prefix >= 32) {
        return 0xffffffffu;
    }
    return htonl(0xffffffffu << (32u - prefix));
}

static void print_route_hints(const char *utun_ifname, const struct ipv4_config *cfg) {
    char address[INET_ADDRSTRLEN] = {0};
    char gateway[INET_ADDRSTRLEN] = {0};
    char netmask[INET_ADDRSTRLEN] = {0};
    struct in_addr mask_addr;

    if (!cfg->have_address || !cfg->have_gateway) {
        printf("route_hints unavailable: IPv4 address or gateway missing\n");
        return;
    }

    ipv4_to_string(cfg->address, address, sizeof(address));
    ipv4_to_string(cfg->gateway, gateway, sizeof(gateway));
    mask_addr.s_addr = prefix_to_netmask(cfg->prefix);
    inet_ntop(AF_INET, &mask_addr, netmask, sizeof(netmask));

    printf("utun_config_hint=\"sudo ifconfig %s inet %s %s netmask %s mtu %u up\"\n",
           utun_ifname,
           address,
           gateway,
           netmask,
           cfg->mtu ? cfg->mtu : MBIM_NET_DEFAULT_MTU);
    printf("single_host_test_hint=\"sudo route -n add -host 1.1.1.1 %s\"\n", gateway);
    printf("single_host_cleanup_hint=\"sudo route -n delete -host 1.1.1.1\"\n");
    printf("default_route_hint=\"sudo route -n change default %s\"  # disruptive; only use after confirming takeover\n",
           gateway);
    for (uint32_t i = 0; i < cfg->dns_count; i++) {
        char dns[INET_ADDRSTRLEN] = {0};
        ipv4_to_string(cfg->dns[i], dns, sizeof(dns));
        printf("dns_hint[%u]=%s\n", i, dns);
    }
}

static int command_status_ok(int status) {
    return status != -1 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int run_system_command(const char *cmd) {
    printf("running: %s\n", cmd);
    int status = system(cmd);
    if (!command_status_ok(status)) {
        fprintf(stderr, "command failed: %s\n", cmd);
        return -1;
    }
    return 0;
}

static int write_pid_file(const char *path, pid_t pid) {
    if (!path || !path[0]) {
        return 0;
    }

    FILE *fp = fopen(path, "w");
    if (!fp) {
        fprintf(stderr, "failed to write pid file %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(fp, "%ld\n", (long)pid);
    fclose(fp);
    return 0;
}

static int daemonize_process(const char *pid_file, const char *log_file) {
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "fork failed: %s\n", strerror(errno));
        return -1;
    }
    if (pid > 0) {
        if (write_pid_file(pid_file, pid) < 0) {
            return -1;
        }
        printf("%ld\n", (long)pid);
        return 1;
    }

    if (setsid() < 0) {
        fprintf(stderr, "setsid failed: %s\n", strerror(errno));
        _exit(1);
    }
    signal(SIGHUP, SIG_IGN);

    int null_fd = open("/dev/null", O_RDONLY);
    if (null_fd >= 0) {
        dup2(null_fd, STDIN_FILENO);
        if (null_fd > STDERR_FILENO) {
            close(null_fd);
        }
    }

    int log_fd = -1;
    if (log_file && log_file[0]) {
        log_fd = open(log_file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log_fd < 0) {
            fprintf(stderr, "failed to open log file %s: %s\n", log_file, strerror(errno));
            _exit(1);
        }
    } else {
        log_fd = open("/dev/null", O_WRONLY);
    }

    if (log_fd >= 0) {
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        if (log_fd > STDERR_FILENO) {
            close(log_fd);
        }
    }

    return 0;
}

static void read_default_route(struct default_route_snapshot *snapshot) {
    memset(snapshot, 0, sizeof(*snapshot));

    FILE *fp = popen("/sbin/route -n get default 2>/dev/null", "r");
    if (!fp) {
        return;
    }

    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char value[128] = {0};
        if (sscanf(line, " gateway: %127s", value) == 1) {
            snprintf(snapshot->gateway, sizeof(snapshot->gateway), "%s", value);
        } else if (sscanf(line, " interface: %127s", value) == 1) {
            snprintf(snapshot->interface_name, sizeof(snapshot->interface_name), "%s", value);
        }
    }

    int status = pclose(fp);
    if (command_status_ok(status) && snapshot->gateway[0]) {
        snapshot->present = 1;
        return;
    }

    /* Scoped VPN defaults are not the system default. Do not recover a guessed
       gateway from netstat or interpolate nested shell/awk positional variables. */
    memset(snapshot, 0, sizeof(*snapshot));
}

static int default_route_uses_interface(const char *interface_name) {
    if (!interface_name || !interface_name[0]) {
        return 0;
    }

    FILE *fp = popen("/sbin/route -n get default 2>/dev/null", "r");
    if (!fp) {
        return 0;
    }

    char line[256];
    char route_interface[IFNAMSIZ] = {0};
    while (fgets(line, sizeof(line), fp)) {
        char value[128] = {0};
        if (sscanf(line, " interface: %127s", value) == 1) {
            snprintf(route_interface, sizeof(route_interface), "%s", value);
        }
    }
    int status = pclose(fp);
    return command_status_ok(status) && strcmp(route_interface, interface_name) == 0;
}

static void restore_or_remove_takeover_route(const struct takeover_state *takeover, const char *gateway) {
    struct default_route_snapshot current;
    read_default_route(&current);
    if (!current.present || !gateway || strcmp(current.gateway, gateway) != 0) {
        printf("MBIM_NET rollback skipped: default gateway ownership changed\n");
        return;
    }
    char cmd[512];
    if (takeover->previous_default.present && takeover->previous_default.gateway[0]) {
        snprintf(cmd, sizeof(cmd), "/sbin/route -n change default %s", takeover->previous_default.gateway);
    } else if (gateway && gateway[0]) {
        snprintf(cmd, sizeof(cmd), "/sbin/route -n delete default %s", gateway);
    } else { return; }
    (void)run_system_command(cmd);
}

static int set_magic_dns(const char *utun_ifname, const struct ipv4_config *cfg) {
    if (cfg->dns_count == 0) {
        printf("MBIM_NET takeover DNS skipped: modem did not provide IPv4 DNS servers\n");
        return 0;
    }

    char address[INET_ADDRSTRLEN] = {0};
    char gateway[INET_ADDRSTRLEN] = {0};
    char netmask[INET_ADDRSTRLEN] = {0};
    struct in_addr mask_addr;
    ipv4_to_string(cfg->address, address, sizeof(address));
    ipv4_to_string(cfg->gateway, gateway, sizeof(gateway));
    mask_addr.s_addr = prefix_to_netmask(cfg->prefix);
    inet_ntop(AF_INET, &mask_addr, netmask, sizeof(netmask));

    FILE *fp = popen("/usr/sbin/scutil", "w");
    if (!fp) {
        fprintf(stderr, "failed to start scutil for DNS configuration: %s\n", strerror(errno));
        return -1;
    }

    fprintf(fp, "d.init\n");
    fprintf(fp, "d.add InterfaceName %s\n", utun_ifname);
    fprintf(fp, "d.add ConfirmedServiceID %s\n", MBIM_NET_DNS_SERVICE_ID);
    fprintf(fp, "d.add ServerAddresses *");
    for (uint32_t i = 0; i < cfg->dns_count; i++) {
        char dns[INET_ADDRSTRLEN] = {0};
        ipv4_to_string(cfg->dns[i], dns, sizeof(dns));
        fprintf(fp, " %s", dns);
    }
    fprintf(fp, "\n");
    fprintf(fp, "d.add SupplementalMatchDomains * \"\"\n");
    fprintf(fp, "set State:/Network/Service/%s/DNS\n", MBIM_NET_DNS_SERVICE_ID);

    fprintf(fp, "d.init\n");
    fprintf(fp, "d.add InterfaceName %s\n", utun_ifname);
    fprintf(fp, "d.add Addresses * %s\n", address);
    fprintf(fp, "d.add SubnetMasks * %s\n", netmask);
    fprintf(fp, "d.add Router %s\n", gateway);
    fprintf(fp, "set State:/Network/Service/%s/IPv4\n", MBIM_NET_DNS_SERVICE_ID);
    fprintf(fp, "quit\n");

    int status = pclose(fp);
    if (!command_status_ok(status)) {
        fprintf(stderr, "scutil DNS configuration failed\n");
        return -1;
    }
    printf("MBIM_NET takeover DNS configured via dynamic store service %s\n", MBIM_NET_DNS_SERVICE_ID);
    return 0;
}

static void clear_magic_dns(void) {
    FILE *fp = popen("/usr/sbin/scutil", "w");
    if (!fp) {
        fprintf(stderr, "failed to start scutil for DNS cleanup: %s\n", strerror(errno));
        return;
    }
    fprintf(fp, "remove State:/Network/Service/%s/DNS\n", MBIM_NET_DNS_SERVICE_ID);
    fprintf(fp, "remove State:/Network/Service/%s/IPv4\n", MBIM_NET_DNS_SERVICE_ID);
    fprintf(fp, "quit\n");
    int status = pclose(fp);
    if (!command_status_ok(status)) {
        fprintf(stderr, "warning: scutil DNS cleanup returned a non-zero status\n");
    } else {
        printf("MBIM_NET takeover DNS cleared\n");
    }
}

static int configure_network_takeover(const char *utun_ifname, const struct ipv4_config *cfg, struct takeover_state *takeover) {
    if (!takeover->enabled) {
        return 0;
    }
    if (!cfg->have_address || !cfg->have_gateway) {
        fprintf(stderr, "MBIM_NET takeover failed: missing IPv4 address or gateway\n");
        return -1;
    }

    char address[INET_ADDRSTRLEN] = {0};
    char gateway[INET_ADDRSTRLEN] = {0};
    char netmask[INET_ADDRSTRLEN] = {0};
    struct in_addr mask_addr;
    ipv4_to_string(cfg->address, address, sizeof(address));
    ipv4_to_string(cfg->gateway, gateway, sizeof(gateway));
    mask_addr.s_addr = prefix_to_netmask(cfg->prefix);
    inet_ntop(AF_INET, &mask_addr, netmask, sizeof(netmask));

    read_default_route(&takeover->previous_default);
    struct in_addr previous_gateway;
    if (takeover->previous_default.present &&
        inet_pton(AF_INET, takeover->previous_default.gateway, &previous_gateway) != 1) {
        fprintf(stderr, "unsupported previous default route: refusing takeover without a restorable IPv4 gateway\n");
        return -1;
    }
    if (takeover->previous_default.present) {
        printf("MBIM_NET previous default route gateway=%s interface=%s\n",
               takeover->previous_default.gateway,
               takeover->previous_default.interface_name[0] ? takeover->previous_default.interface_name : "-");
    } else {
        printf("MBIM_NET previous default route not found\n");
    }

    char cmd[512];
    snprintf(cmd, sizeof(cmd), "/sbin/ifconfig %s inet %s %s netmask %s mtu %u up",
             utun_ifname,
             address,
             gateway,
             netmask,
             cfg->mtu ? cfg->mtu : MBIM_NET_DEFAULT_MTU);
    if (run_system_command(cmd) < 0) {
        return -1;
    }

    snprintf(cmd, sizeof(cmd), "/sbin/route -n %s default %s",
             takeover->previous_default.present ? "change" : "add",
             gateway);
    if (run_system_command(cmd) < 0) {
        return -1;
    }
    takeover->route_changed = 1;
    snprintf(takeover->owned_interface, sizeof(takeover->owned_interface), "%s", utun_ifname);
    snprintf(takeover->owned_gateway, sizeof(takeover->owned_gateway), "%s", gateway);

    if (!default_route_uses_interface(utun_ifname)) {
        fprintf(stderr, "MBIM_NET takeover failed: default route is not using %s after route change\n", utun_ifname);
        restore_or_remove_takeover_route(takeover, gateway);
        takeover->route_changed = 0;
        return -1;
    }

    if (takeover->configure_dns) {
        if (set_magic_dns(utun_ifname, cfg) < 0) {
            fprintf(stderr, "warning: DNS takeover failed; IP routing may still work\n");
        } else {
            takeover->dns_configured = 1;
        }
    }

    printf("MBIM_NET takeover active=1 default_gateway=%s interface=%s restore_on_exit=%u dns=%u\n",
           gateway,
           utun_ifname,
           takeover->restore_on_exit ? 1u : 0u,
           takeover->dns_configured ? 1u : 0u);
    return 0;
}

static void restore_network_takeover(struct takeover_state *takeover) {
    if (!takeover->enabled || !takeover->restore_on_exit) {
        return;
    }

    if (takeover->dns_configured || takeover->configure_dns) {
        clear_magic_dns();
        takeover->dns_configured = 0;
    }

    if (takeover->route_changed) {
        if (!default_route_uses_interface(takeover->owned_interface)) {
            printf("MBIM_NET route restore skipped: current route is owned by another interface\n");
            takeover->route_changed = 0;
            return;
        }
        char cmd[512];
        if (takeover->previous_default.present && takeover->previous_default.gateway[0]) {
            snprintf(cmd, sizeof(cmd), "/sbin/route -n change default %s", takeover->previous_default.gateway);
        } else {
            snprintf(cmd, sizeof(cmd), "/sbin/route -n delete default %s", takeover->owned_gateway);
        }
        if (run_system_command(cmd) < 0) {
            fprintf(stderr, "warning: failed to restore previous default route\n");
        } else {
            printf("MBIM_NET takeover restored default route\n");
        }
        takeover->route_changed = 0;
    }
}

static int parse_ip_configuration(const uint8_t *info, uint32_t info_len, struct ipv4_config *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    cfg->mtu = MBIM_NET_DEFAULT_MTU;

    if (info_len < 60) {
        return -1;
    }

    uint32_t ipv4_count = get_u32le(info + 12);
    uint32_t ipv4_offset = get_u32le(info + 16);
    uint32_t ipv4_dns_count = get_u32le(info + 36);
    uint32_t ipv4_dns_offset = get_u32le(info + 40);
    uint32_t ipv4_mtu = get_u32le(info + 52);

    if (ipv4_mtu > 0) {
        cfg->mtu = ipv4_mtu;
    }

    if (ipv4_count > 0 && ipv4_offset > 0 && ipv4_offset <= info_len && ipv4_count <= (info_len - ipv4_offset) / 8u) {
        const uint8_t *entry = info + ipv4_offset;
        cfg->prefix = get_u32le(entry);
        memcpy(cfg->address, entry + 4, 4);
        cfg->have_address = 1;
    }

    const uint8_t *gateway = NULL;
    if (read_ref_offset(info, info_len, 28, 4, &gateway) == 0 && gateway) {
        memcpy(cfg->gateway, gateway, 4);
        cfg->have_gateway = 1;
    }

    if (ipv4_dns_count > 0 &&
        ipv4_dns_offset > 0 &&
        ipv4_dns_offset <= info_len &&
        ipv4_dns_count <= (info_len - ipv4_dns_offset) / 4u) {
        uint32_t count = ipv4_dns_count > 4 ? 4 : ipv4_dns_count;
        cfg->dns_count = count;
        for (uint32_t i = 0; i < count; i++) {
            memcpy(cfg->dns[i], info + ipv4_dns_offset + (i * 4u), 4);
        }
    }

    return cfg->have_address ? 0 : -1;
}

static int mbim_fetch_ip_configuration(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    struct ipv4_config *cfg) {
    uint8_t req[4] = {0};
    uint8_t info[2048] = {0};
    uint32_t info_len = 0;

    put_u32le(req, 0);
    printf("querying MBIM_IP_CONFIGURATION for data path\n");
    int rc = mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_CID_IP_CONFIGURATION,
        MBIM_COMMAND_TYPE_QUERY,
        req,
        sizeof(req),
        info,
        sizeof(info),
        &info_len);
    if (rc < 0) {
        return rc;
    }
    print_ip_configuration(info, info_len);
    if (parse_ip_configuration(info, info_len, cfg) < 0) {
        fprintf(stderr, "failed to parse IPv4 configuration for data path\n");
        return LIBUSB_ERROR_OTHER;
    }
    return 0;
}

static int mbim_query_ip_configuration(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid) {
    uint8_t req[4] = {0};
    uint8_t info[2048] = {0};
    uint32_t info_len = 0;

    put_u32le(req, 0);
    printf("querying MBIM_IP_CONFIGURATION\n");
    int rc = mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_CID_IP_CONFIGURATION,
        MBIM_COMMAND_TYPE_QUERY,
        req,
        sizeof(req),
        info,
        sizeof(info),
        &info_len);
    if (rc == 0) {
        print_ip_configuration(info, info_len);
    }
    return rc;
}

static int mbim_packet_service_attach(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid) {
    uint8_t req[4] = {0};
    uint8_t info[512] = {0};
    uint32_t info_len = 0;

    put_u32le(req, MBIM_PACKET_SERVICE_ACTION_ATTACH);
    printf("sending MBIM_PACKET_SERVICE attach\n");
    int rc = mbim_command_cid(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_CID_PACKET_SERVICE,
        MBIM_COMMAND_TYPE_SET,
        req,
        sizeof(req),
        info,
        sizeof(info),
        &info_len);
    if (rc == 0 && info_len >= 24) {
        printf("  nw_error=%u packet_service_state=%u highest_data_class=0x%08x uplink_bps=%llu downlink_bps=%llu\n",
               get_u32le(info), get_u32le(info + 4), get_u32le(info + 8),
               (unsigned long long)get_u64le(info + 12), (unsigned long long)get_u64le(info + 20));
    }
    return rc;
}

static int run_deactivate(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t ip_type);

static int open_utun(char ifname[IFNAMSIZ]) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        fprintf(stderr, "socket(PF_SYSTEM, SYSPROTO_CONTROL) failed: %s\n", strerror(errno));
        return -1;
    }

    struct ctl_info ctl;
    memset(&ctl, 0, sizeof(ctl));
    snprintf(ctl.ctl_name, sizeof(ctl.ctl_name), "%s", UTUN_CONTROL_NAME);
    if (ioctl(fd, CTLIOCGINFO, &ctl) < 0) {
        fprintf(stderr, "CTLIOCGINFO(%s) failed: %s\n", UTUN_CONTROL_NAME, strerror(errno));
        close(fd);
        return -1;
    }

    struct sockaddr_ctl addr;
    memset(&addr, 0, sizeof(addr));
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    addr.sc_id = ctl.ctl_id;
    addr.sc_unit = 0;

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "connect(%s) failed: %s\n", UTUN_CONTROL_NAME, strerror(errno));
        if (errno == EPERM) {
            fprintf(stderr, "macOS denied utun creation for this process; run mbim-net as a privileged helper or via sudo for data-plane testing\n");
        }
        close(fd);
        return -1;
    }

    socklen_t ifname_len = IFNAMSIZ;
    memset(ifname, 0, IFNAMSIZ);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &ifname_len) < 0) {
        fprintf(stderr, "getsockopt(UTUN_OPT_IFNAME) failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    return fd;
}

static int write_all(int fd, const uint8_t *buf, size_t len) {
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        written += (size_t)n;
    }
    return 0;
}

static int write_ip_packet_to_utun(int utun_fd, const uint8_t *packet, uint16_t packet_len) {
    if (packet_len < 1) {
        return -1;
    }

    uint8_t version = (uint8_t)(packet[0] >> 4);
    uint32_t family = 0;
    if (version == 4) {
        family = htonl(AF_INET);
    } else if (version == 6) {
        family = htonl(AF_INET6);
    } else {
        return -1;
    }

    uint8_t framed[4 + MBIM_NET_MAX_PACKET_SIZE];
    if (packet_len > MBIM_NET_MAX_PACKET_SIZE) {
        return -1;
    }
    memcpy(framed, &family, sizeof(family));
    memcpy(framed + 4, packet, packet_len);
    return write_all(utun_fd, framed, (size_t)packet_len + 4u);
}

static int is_ips_session0_signature(const uint8_t *sig) {
    return sig[0] == 'I' && sig[1] == 'P' && sig[2] == 'S' && (sig[3] == 0 || sig[3] == '0');
}

static int parse_ncm_ntb_to_utun(struct net_context *ctx, const uint8_t *buf, int len) {
    if (len < (int)NCM_NTH16_LENGTH) {
        return 0;
    }
    if (get_u32le(buf) != NCM_NTH16_SIGNATURE) {
        dump_hex("unexpected USB data signature", buf, len, 64);
        return -1;
    }

    uint16_t header_len = get_u16le(buf + 4);
    uint16_t block_len = get_u16le(buf + 8);
    uint16_t ndp_index = get_u16le(buf + 10);
    if (header_len < NCM_NTH16_LENGTH || header_len > (uint16_t)len) {
        return -1;
    }
    if (block_len == 0 || block_len > (uint16_t)len) {
        block_len = (uint16_t)len;
    }

    int packets = 0;
    for (int chain = 0; chain < 8 && ndp_index != 0; chain++) {
        if (ndp_index + 8u > block_len) {
            return packets;
        }
        const uint8_t *ndp = buf + ndp_index;
        uint16_t ndp_len = get_u16le(ndp + 4);
        uint16_t next_ndp = get_u16le(ndp + 6);
        if (ndp_len < NCM_NDP16_ONE_DPE_LENGTH || ndp_index + ndp_len > block_len) {
            return packets;
        }

        if (is_ips_session0_signature(ndp)) {
            uint32_t end = (uint32_t)ndp_index + ndp_len;
            for (uint32_t off = (uint32_t)ndp_index + 8u; off + 4u <= end; off += 4u) {
                uint16_t datagram_index = get_u16le(buf + off);
                uint16_t datagram_len = get_u16le(buf + off + 2);
                if (datagram_index == 0 && datagram_len == 0) {
                    break;
                }
                if (datagram_len == 0 || datagram_index + datagram_len > block_len) {
                    continue;
                }
                const uint8_t *packet = buf + datagram_index;
                if (write_ip_packet_to_utun(ctx->utun_fd, packet, datagram_len) == 0) {
                    ctx->rx_packets++;
                    ctx->rx_bytes += datagram_len;
                    packets++;
                }
            }
        }

        ndp_index = next_ndp;
    }
    return packets;
}

static int parse_ncm_transport(const uint8_t *data, int length, uint16_t max_packet,
                               struct ncm_transport *transport) {
    if (length < 28 || get_u16le(data) < 28 || get_u16le(data) > length ||
        !(get_u16le(data + 2) & 1u) || max_packet == 0) return -1;
    struct ncm_transport parsed = {0};
    parsed.in_max = get_u32le(data + 4);
    parsed.out_max = get_u32le(data + 16);
    parsed.out_divisor = get_u16le(data + 20);
    parsed.out_remainder = get_u16le(data + 22);
    parsed.out_alignment = get_u16le(data + 24);
    parsed.max_packet = max_packet;
    if (parsed.in_max < 2048 || parsed.out_max < 48 || parsed.out_max > UINT16_MAX ||
        parsed.out_divisor == 0 || parsed.out_divisor > 4096 ||
        parsed.out_alignment < 4 || parsed.out_alignment > 4096 ||
        (parsed.out_alignment & (parsed.out_alignment - 1u)) != 0 ||
        parsed.out_remainder >= parsed.out_divisor) return -1;
    if (parsed.in_max > MBIM_NET_MAX_NTB_SIZE) parsed.in_max = MBIM_NET_MAX_NTB_SIZE;
    *transport = parsed;
    return 0;
}

static int configure_ncm_transport(libusb_device_handle *handle, int control,
                                   uint16_t max_packet, struct ncm_transport *transport) {
    uint8_t parameters[28] = {0};
    int rc = libusb_control_transfer(handle, 0xa1, 0x80, 0, (uint16_t)control,
                                    parameters, sizeof(parameters), 3000);
    if (rc < 0 || parse_ncm_transport(parameters, rc, max_packet, transport) < 0) {
        fprintf(stderr, "NCM GET_NTB_PARAMETERS failed: %s\n",
                rc < 0 ? libusb_error_name(rc) : "unsupported transport parameters");
        return LIBUSB_ERROR_OTHER;
    }
    if (get_u16le(parameters + 2) & 2u) {
        rc = libusb_control_transfer(handle, 0x21, 0x84, 0, (uint16_t)control, NULL, 0, 3000);
        if (rc < 0) return rc;
    }
    uint8_t input_size[4] = {0};
    rc = libusb_control_transfer(handle, 0xa1, 0x85, 0, (uint16_t)control,
                                input_size, sizeof(input_size), 3000);
    if (rc != 4 || get_u32le(input_size) != transport->in_max) {
        put_u32le(input_size, transport->in_max);
        rc = libusb_control_transfer(handle, 0x21, 0x86, 0, (uint16_t)control,
                                    input_size, sizeof(input_size), 3000);
        if (rc != 4) {
            fprintf(stderr, "NCM SET_NTB_INPUT_SIZE failed: %s\n",
                    rc < 0 ? libusb_error_name(rc) : "short control write");
            return LIBUSB_ERROR_OTHER;
        }
    }
    printf("MBIM_NET ncm=ntb16 in_max=%u out_max=%u divisor=%u remainder=%u alignment=%u max_packet=%u\n",
           transport->in_max, transport->out_max, transport->out_divisor,
           transport->out_remainder, transport->out_alignment, transport->max_packet);
    return 0;
}

static int build_ncm_ntb_from_packet(struct net_context *ctx, const uint8_t *packet, uint16_t packet_len, uint8_t *ntb, int ntb_capacity) {
    if (packet_len == 0 || packet_len > MBIM_NET_MAX_PACKET_SIZE) {
        return -1;
    }

    uint32_t divisor = ctx->transport.out_divisor ? ctx->transport.out_divisor : 4u;
    uint32_t remainder = ctx->transport.out_remainder;
    uint32_t alignment = ctx->transport.out_alignment ? ctx->transport.out_alignment : 4u;
    uint32_t max_packet = ctx->transport.max_packet ? ctx->transport.max_packet : 512u;
    uint32_t max_ntb = ctx->transport.out_max ? ctx->transport.out_max : MBIM_NET_MAX_NTB_SIZE;
    if (remainder >= divisor) return -1;
    uint32_t payload_offset = NCM_NTH16_LENGTH +
        (remainder + divisor - (NCM_NTH16_LENGTH % divisor)) % divisor;
    uint32_t ndp_offset = ((payload_offset + packet_len + alignment - 1u) / alignment) * alignment;
    uint32_t total_len = ndp_offset + NCM_NDP16_ONE_DPE_LENGTH;
    /* A partial NTB must end in a short USB packet. A full negotiated NTB
       is self-terminating; smaller exact-maxpacket transfers need one pad byte. */
    if (total_len < max_ntb && total_len % max_packet == 0) total_len++;
    if (ntb_capacity < 0 || total_len > (uint32_t)ntb_capacity ||
        total_len > max_ntb || total_len > UINT16_MAX) {
        return -1;
    }

    memset(ntb, 0, total_len);
    put_u32le(ntb + 0, NCM_NTH16_SIGNATURE);
    put_u16le(ntb + 4, NCM_NTH16_LENGTH);
    put_u16le(ntb + 6, ++ctx->tx_sequence);
    put_u16le(ntb + 8, (uint16_t)total_len);
    put_u16le(ntb + 10, (uint16_t)ndp_offset);

    memcpy(ntb + payload_offset, packet, packet_len);

    put_u32le(ntb + ndp_offset + 0, NCM_NDP16_IPS_SESSION0_SIGNATURE);
    put_u16le(ntb + ndp_offset + 4, NCM_NDP16_ONE_DPE_LENGTH);
    put_u16le(ntb + ndp_offset + 6, 0);
    put_u16le(ntb + ndp_offset + 8, (uint16_t)payload_offset);
    put_u16le(ntb + ndp_offset + 10, packet_len);
    put_u16le(ntb + ndp_offset + 12, 0);
    put_u16le(ntb + ndp_offset + 14, 0);

    return (int)total_len;
}

static int send_ip_packet_to_usb(struct net_context *ctx, const uint8_t *packet, uint16_t packet_len) {
    uint8_t ntb[MBIM_NET_MAX_NTB_SIZE];
    int ntb_len = build_ncm_ntb_from_packet(ctx, packet, packet_len, ntb, sizeof(ntb));
    if (ntb_len < 0) {
        return -1;
    }

    int transferred = 0;
    int rc = libusb_bulk_transfer(ctx->handle, ctx->bulk_out, ntb, ntb_len, &transferred, 3000);
    if (rc < 0) {
        fprintf(stderr, "USB bulk OUT failed: %s transferred=%d/%d ip_length=%u sequence=%u\n",
                libusb_error_name(rc), transferred, ntb_len, packet_len, ctx->tx_sequence);
        return rc;
    }
    if (transferred != ntb_len) {
        fprintf(stderr, "USB bulk OUT short write: %d/%d\n", transferred, ntb_len);
        return LIBUSB_ERROR_IO;
    }

    ctx->tx_packets++;
    ctx->tx_bytes += packet_len;
    return 0;
}

static void *usb_to_utun_thread(void *arg) {
    struct net_context *ctx = (struct net_context *)arg;
    uint8_t buf[MBIM_NET_MAX_NTB_SIZE];

    while (!stop_requested) {
        int transferred = 0;
        int rc = libusb_bulk_transfer(ctx->handle, ctx->bulk_in, buf, sizeof(buf), &transferred, 1000);
        if (rc < 0 && rc != LIBUSB_ERROR_TIMEOUT) {
            if (!stop_requested) {
                fprintf(stderr, "USB bulk IN failed: %s\n", libusb_error_name(rc));
                stop_requested = 1;
            }
            break;
        }
        if (transferred > 0) {
            (void)parse_ncm_ntb_to_utun(ctx, buf, transferred);
        }
    }
    return NULL;
}

static void *utun_to_usb_thread(void *arg) {
    struct net_context *ctx = (struct net_context *)arg;
    uint8_t buf[4 + MBIM_NET_MAX_PACKET_SIZE];

    while (!stop_requested) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(ctx->utun_fd, &readfds);
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;

        int rc = select(ctx->utun_fd + 1, &readfds, NULL, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "select(utun) failed: %s\n", strerror(errno));
            stop_requested = 1;
            break;
        }
        if (rc == 0 || !FD_ISSET(ctx->utun_fd, &readfds)) {
            continue;
        }

        ssize_t n = read(ctx->utun_fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            fprintf(stderr, "read(utun) failed: %s\n", strerror(errno));
            stop_requested = 1;
            break;
        }
        if (n == 0) {
            fprintf(stderr, "read(utun) failed: interface stream closed\n");
            stop_requested = 1;
            break;
        }
        if (n <= 4) {
            continue;
        }

        uint32_t family = 0;
        memcpy(&family, buf, sizeof(family));
        family = ntohl(family);
        if (family != AF_INET) {
            continue;
        }

        uint16_t packet_len = (uint16_t)(n - 4);
        if (send_ip_packet_to_usb(ctx, buf + 4, packet_len) < 0 && !stop_requested) {
            stop_requested = 1;
            break;
        }
    }
    return NULL;
}

static int run_net(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    const struct data_endpoints *data_eps,
    const struct ncm_transport *transport,
    const char *apn,
    uint32_t ip_type,
    int duration_seconds,
    struct takeover_state *takeover) {
    if (!data_eps || data_eps->interface_number < 0 || data_eps->bulk_in == 0 || data_eps->bulk_out == 0) {
        fprintf(stderr, "MBIM data bulk endpoints not found\n");
        return LIBUSB_ERROR_NOT_FOUND;
    }

    stop_requested = 0;
    signal(SIGINT, handle_stop_signal);
    signal(SIGTERM, handle_stop_signal);

    int attach_rc = mbim_packet_service_attach(handle, iface, interrupt_ep, txid);
    if (attach_rc < 0) {
        fprintf(stderr, "MBIM_PACKET_SERVICE attach failed: %s\n", libusb_error_name(attach_rc));
    }

    uint32_t activation_state = 0;
    int rc = mbim_connect_set(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_ACTIVATION_COMMAND_ACTIVATE,
        apn,
        ip_type,
        &activation_state);
    if (rc < 0) {
        fprintf(stderr, "MBIM_CONNECT activate failed: %s\n", libusb_error_name(rc));
        return rc;
    }

    for (int attempt = 0; attempt < 8 && activation_state != 1; attempt++) {
        sleep(1);
        if (mbim_query_connect(handle, iface, interrupt_ep, txid, &activation_state) < 0) {
            break;
        }
    }
    if (activation_state != 1) {
        fprintf(stderr, "MBIM_CONNECT did not reach Activated state\n");
        (void)run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
        return LIBUSB_ERROR_OTHER;
    }

    struct ipv4_config ip_cfg;
    rc = mbim_fetch_ip_configuration(handle, iface, interrupt_ep, txid, &ip_cfg);
    if (rc < 0) {
        (void)run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
        return rc;
    }

    char utun_ifname[IFNAMSIZ] = {0};
    int utun_fd = open_utun(utun_ifname);
    if (utun_fd < 0) {
        (void)run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
        return LIBUSB_ERROR_OTHER;
    }

    struct net_context net_ctx;
    memset(&net_ctx, 0, sizeof(net_ctx));
    net_ctx.handle = handle;
    net_ctx.bulk_in = data_eps->bulk_in;
    net_ctx.bulk_out = data_eps->bulk_out;
    net_ctx.utun_fd = utun_fd;
    net_ctx.transport = *transport;

    printf("MBIM_NET active=1 utun=%s bulk_in=0x%02x bulk_out=0x%02x\n",
           utun_ifname,
           data_eps->bulk_in,
           data_eps->bulk_out);
    if (takeover && takeover->enabled) {
        if (configure_network_takeover(utun_ifname, &ip_cfg, takeover) < 0) {
            close(utun_fd);
            (void)run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
            return LIBUSB_ERROR_OTHER;
        }
    } else {
        printf("MBIM_NET no system route or DNS has been changed\n");
    }
    print_route_hints(utun_ifname, &ip_cfg);
    printf("MBIM_NET forwarding packets; send SIGTERM/SIGINT to stop");
    if (duration_seconds > 0) {
        printf(" or wait %d seconds", duration_seconds);
    }
    printf("\n");

    pthread_t rx_thread;
    pthread_t tx_thread;
    int rx_started = 0;
    int tx_started = 0;
    if (pthread_create(&rx_thread, NULL, usb_to_utun_thread, &net_ctx) == 0) {
        rx_started = 1;
    } else {
        fprintf(stderr, "pthread_create USB->utun failed\n");
        stop_requested = 1;
    }
    if (!stop_requested && pthread_create(&tx_thread, NULL, utun_to_usb_thread, &net_ctx) == 0) {
        tx_started = 1;
    } else if (!stop_requested) {
        fprintf(stderr, "pthread_create utun->USB failed\n");
        stop_requested = 1;
    }

    if (rx_started && tx_started && !stop_requested) {
        printf("MBIM_NET ready=1 pid=%ld\n", (long)getpid());
    }
    int elapsed = 0;
    while (!stop_requested) {
        sleep(1);
        elapsed++;
        if (duration_seconds > 0 && elapsed >= duration_seconds) {
            stop_requested = 1;
        }
    }

    if (rx_started) {
        pthread_join(rx_thread, NULL);
    }
    if (tx_started) {
        pthread_join(tx_thread, NULL);
    }

    printf("MBIM_NET counters rx_packets=%llu rx_bytes=%llu tx_packets=%llu tx_bytes=%llu\n",
           (unsigned long long)net_ctx.rx_packets,
           (unsigned long long)net_ctx.rx_bytes,
           (unsigned long long)net_ctx.tx_packets,
           (unsigned long long)net_ctx.tx_bytes);

    if (takeover) {
        restore_network_takeover(takeover);
    }
    close(utun_fd);
    int down_rc = run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
    if (down_rc < 0) {
        return down_rc;
    }
    printf("MBIM_NET active=0\n");
    return 0;
}

static int run_connect_test(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    const char *apn,
    uint32_t ip_type) {
    uint32_t activation_state = 0;
    int attach_rc = mbim_packet_service_attach(handle, iface, interrupt_ep, txid);
    if (attach_rc < 0) {
        fprintf(stderr, "MBIM_PACKET_SERVICE attach failed: %s\n", libusb_error_name(attach_rc));
    }

    int rc = mbim_connect_set(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_ACTIVATION_COMMAND_ACTIVATE,
        apn,
        ip_type,
        &activation_state);
    if (rc < 0) {
        fprintf(stderr, "MBIM_CONNECT activate failed: %s\n", libusb_error_name(rc));
        (void)mbim_connect_set(handle, iface, interrupt_ep, txid, MBIM_ACTIVATION_COMMAND_DEACTIVATE, NULL, ip_type, NULL);
        return rc;
    }

    for (int attempt = 0; attempt < 8 && activation_state != 1; attempt++) {
        sleep(1);
        if (mbim_query_connect(handle, iface, interrupt_ep, txid, &activation_state) < 0) {
            break;
        }
    }

    int ip_rc = mbim_query_ip_configuration(handle, iface, interrupt_ep, txid);
    if (ip_rc < 0) {
        fprintf(stderr, "MBIM_IP_CONFIGURATION query failed: %s\n", libusb_error_name(ip_rc));
    }

    int down_rc = mbim_connect_set(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_ACTIVATION_COMMAND_DEACTIVATE,
        NULL,
        ip_type,
        NULL);
    if (down_rc < 0) {
        fprintf(stderr, "MBIM_CONNECT deactivate failed: %s\n", libusb_error_name(down_rc));
    }

    return ip_rc < 0 ? ip_rc : rc;
}

static int run_status(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid) {
    uint32_t activation_state = 0;
    int rc = mbim_query_connect(handle, iface, interrupt_ep, txid, &activation_state);
    if (rc < 0) {
        fprintf(stderr, "MBIM_CONNECT status query failed: %s\n", libusb_error_name(rc));
        return rc;
    }

    if (activation_state == 1) {
        int ip_rc = mbim_query_ip_configuration(handle, iface, interrupt_ep, txid);
        if (ip_rc < 0) {
            fprintf(stderr, "MBIM_IP_CONFIGURATION query failed: %s\n", libusb_error_name(ip_rc));
            return ip_rc;
        }
    }
    return rc;
}

static int run_activate(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    const char *apn,
    uint32_t ip_type) {
    uint32_t activation_state = 0;
    int attach_rc = mbim_packet_service_attach(handle, iface, interrupt_ep, txid);
    if (attach_rc < 0) {
        fprintf(stderr, "MBIM_PACKET_SERVICE attach failed: %s\n", libusb_error_name(attach_rc));
    }

    int rc = mbim_connect_set(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_ACTIVATION_COMMAND_ACTIVATE,
        apn,
        ip_type,
        &activation_state);
    if (rc < 0) {
        fprintf(stderr, "MBIM_CONNECT activate failed: %s\n", libusb_error_name(rc));
        return rc;
    }

    for (int attempt = 0; attempt < 8 && activation_state != 1; attempt++) {
        sleep(1);
        if (mbim_query_connect(handle, iface, interrupt_ep, txid, &activation_state) < 0) {
            break;
        }
    }

    if (activation_state != 1) {
        fprintf(stderr, "MBIM_CONNECT did not reach Activated state\n");
        return LIBUSB_ERROR_OTHER;
    }

    int ip_rc = mbim_query_ip_configuration(handle, iface, interrupt_ep, txid);
    if (ip_rc < 0) {
        fprintf(stderr, "MBIM_IP_CONFIGURATION query failed: %s\n", libusb_error_name(ip_rc));
        return ip_rc;
    }
    return rc;
}

static int run_deactivate(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    uint32_t ip_type) {
    int rc = mbim_connect_set(
        handle,
        iface,
        interrupt_ep,
        txid,
        MBIM_ACTIVATION_COMMAND_DEACTIVATE,
        NULL,
        ip_type,
        NULL);
    if (rc < 0) {
        fprintf(stderr, "MBIM_CONNECT deactivate failed: %s\n", libusb_error_name(rc));
        if (rc == LIBUSB_ERROR_TIMEOUT) {
            fprintf(stderr, "MBIM_CONNECT deactivate timed out after command was sent; continuing so status can be verified by a later query\n");
            return 0;
        }
    }
    return rc;
}

static int run_hold(
    libusb_device_handle *handle,
    int iface,
    uint8_t interrupt_ep,
    uint32_t *txid,
    const char *apn,
    uint32_t ip_type) {
    signal(SIGINT, handle_stop_signal);
    signal(SIGTERM, handle_stop_signal);

    int rc = run_activate(handle, iface, interrupt_ep, txid, apn, ip_type);
    if (rc < 0) {
        return rc;
    }

    printf("MBIM_HOLD active=1; send SIGTERM or SIGINT to deactivate\n");
    while (!stop_requested) {
        sleep(1);
    }

    printf("MBIM_HOLD stopping\n");
    int down_rc = run_deactivate(handle, iface, interrupt_ep, txid, ip_type);
    if (down_rc < 0) {
        return down_rc;
    }
    printf("MBIM_HOLD active=0\n");
    return rc;
}

static void mbim_close(libusb_device_handle *handle, int iface, uint8_t interrupt_ep, uint32_t *txid) {
    uint8_t msg[12] = {0};
    uint8_t rsp[4096] = {0};

    put_u32le(&msg[0], MBIM_CLOSE_MSG);
    put_u32le(&msg[4], sizeof(msg));
    put_u32le(&msg[8], ++(*txid));

    printf("sending MBIM_CLOSE\n");
    if (send_mbim_message(handle, iface, msg, sizeof(msg)) < 0) {
        return;
    }
    int len = read_mbim_response(handle, iface, interrupt_ep, rsp, sizeof(rsp), MBIM_CLOSE_DONE, *txid);
    if (len < 0) {
        fprintf(stderr, "MBIM_CLOSE response failed: %s\n", libusb_error_name(len));
        return;
    }
    if (len >= 16) {
        uint32_t status = get_u32le(&rsp[12]);
        printf("MBIM_CLOSE status=0x%08x%s\n", status, status == MBIM_STATUS_SUCCESS ? " (success)" : "");
    }
}

static void print_usage(const char *argv0) {
    printf("usage: %s [--duration=SECONDS] [--takeover-default] [--restore-on-exit] [--no-dns] [--daemonize] [--pid-file=PATH] [--log-file=PATH] [--apn=APN] [--ip-type=ipv4]\n", argv0);
    printf("       %s [--status|--deactivate|--connect-test] [--apn=APN] [--ip-type=default|ipv4|ipv6|ipv4v6|both]\n", argv0);
    printf("  default: activate MBIM session 0 and bridge MBIM/NCM data frames to a macOS utun interface\n");
    printf("  --duration=SECONDS: stop automatically after the given duration; default is run until SIGTERM/SIGINT\n");
    printf("  --takeover-default: configure utun, DNS, and the macOS default route for LTE internet access\n");
    printf("  --restore-on-exit: restore the previous default route and clear temporary DNS on exit\n");
    printf("  --no-dns: skip temporary DNS dynamic-store configuration when using --takeover-default\n");
    printf("  --daemonize: detach after startup and print the child PID\n");
    printf("  --pid-file=PATH: write the daemon child PID to PATH\n");
    printf("  --log-file=PATH: redirect daemon stdout/stderr to PATH\n");
    printf("  --status: inspect status and current MBIM session/IP configuration\n");
    printf("  --activate: activate MBIM session 0 once, query IP configuration, then close control channel\n");
    printf("  --deactivate: deactivate MBIM session 0\n");
    printf("  --hold: activate MBIM session 0, hold it open, and deactivate on SIGTERM/SIGINT\n");
    printf("  --connect-test: activate session 0, query IP configuration, then deactivate\n");
    printf("  mbim-net only changes macOS routes or DNS when --takeover-default is explicitly set\n");
}

int main(int argc, char **argv) {
    libusb_context *ctx = NULL;
    libusb_device_handle *handle = NULL;
    struct libusb_device_descriptor desc;
    struct libusb_config_descriptor *cfg = NULL;
    int mbim_control_if = -1;
    int mbim_data_if = -1;
    uint8_t mbim_interrupt_ep = 0;
    struct data_endpoints data_eps;
    struct ncm_transport transport = {0};
    uint32_t txid = 0;
    int action = ACTION_PROBE;
    const char *apn = "3gnet";
    uint32_t ip_type = MBIM_CONTEXT_IP_TYPE_IPV4;
    int duration_seconds = 0;
    struct takeover_state takeover;
    int daemonize = 0;
    const char *pid_file = NULL;
    const char *log_file = NULL;

    setvbuf(stdout, NULL, _IONBF, 0);
    memset(&data_eps, 0, sizeof(data_eps));
    data_eps.interface_number = -1;
    memset(&takeover, 0, sizeof(takeover));
    takeover.configure_dns = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--connect-test") == 0) {
            if (set_action(&action, ACTION_CONNECT_TEST) < 0) {
                fprintf(stderr, "only one action may be specified\n");
                print_usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--status") == 0) {
            if (set_action(&action, ACTION_STATUS) < 0) {
                fprintf(stderr, "only one action may be specified\n");
                print_usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--activate") == 0) {
            if (set_action(&action, ACTION_ACTIVATE) < 0) {
                fprintf(stderr, "only one action may be specified\n");
                print_usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--deactivate") == 0) {
            if (set_action(&action, ACTION_DEACTIVATE) < 0) {
                fprintf(stderr, "only one action may be specified\n");
                print_usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--hold") == 0) {
            if (set_action(&action, ACTION_HOLD) < 0) {
                fprintf(stderr, "only one action may be specified\n");
                print_usage(argv[0]);
                return 2;
            }
        } else if (strncmp(argv[i], "--apn=", 6) == 0) {
            apn = argv[i] + 6;
        } else if (strncmp(argv[i], "--ip-type=", 10) == 0) {
            if (parse_ip_type_arg(argv[i] + 10, &ip_type) < 0) {
                fprintf(stderr, "unknown ip type: %s\n", argv[i] + 10);
                print_usage(argv[0]);
                return 2;
            }
        } else if (strncmp(argv[i], "--duration=", 11) == 0) {
            char *end = NULL;
            long parsed = strtol(argv[i] + 11, &end, 10);
            if (!end || *end != '\0' || parsed < 1 || parsed > 86400) {
                fprintf(stderr, "invalid duration: %s\n", argv[i] + 11);
                print_usage(argv[0]);
                return 2;
            }
            duration_seconds = (int)parsed;
        } else if (strcmp(argv[i], "--takeover-default") == 0) {
            takeover.enabled = 1;
        } else if (strcmp(argv[i], "--restore-on-exit") == 0) {
            takeover.restore_on_exit = 1;
        } else if (strcmp(argv[i], "--no-dns") == 0) {
            takeover.configure_dns = 0;
        } else if (strcmp(argv[i], "--daemonize") == 0) {
            daemonize = 1;
        } else if (strncmp(argv[i], "--pid-file=", 11) == 0) {
            pid_file = argv[i] + 11;
        } else if (strncmp(argv[i], "--log-file=", 11) == 0) {
            log_file = argv[i] + 11;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            print_usage(argv[0]);
            return 2;
        }
    }
    if (action == ACTION_PROBE) {
        action = ACTION_RUN_NET;
    }
    if (daemonize) {
        int daemon_rc = daemonize_process(pid_file, log_file);
        if (daemon_rc > 0) {
            return 0;
        }
        if (daemon_rc < 0) {
            return 1;
        }
    }

    int rc = libusb_init(&ctx);
    if (rc < 0) {
        fprintf(stderr, "libusb_init failed: %s\n", libusb_error_name(rc));
        return 1;
    }

    handle = libusb_open_device_with_vid_pid(ctx, LENOVO_VENDOR_ID, MAGIC_BAY_LTE_PRODUCT_ID);
    if (!handle) {
        fprintf(stderr, "device 0x%04x:0x%04x not found or not accessible\n",
                LENOVO_VENDOR_ID, MAGIC_BAY_LTE_PRODUCT_ID);
        libusb_exit(ctx);
        return 2;
    }

    libusb_device *dev = libusb_get_device(handle);
    rc = libusb_get_device_descriptor(dev, &desc);
    if (rc < 0) {
        fprintf(stderr, "libusb_get_device_descriptor failed: %s\n", libusb_error_name(rc));
        goto out;
    }

    printf("device vid=0x%04x pid=0x%04x class=0x%02x subclass=0x%02x protocol=0x%02x configs=%u\n",
           desc.idVendor, desc.idProduct, desc.bDeviceClass,
           desc.bDeviceSubClass, desc.bDeviceProtocol, desc.bNumConfigurations);

    rc = libusb_get_active_config_descriptor(dev, &cfg);
    if (rc < 0) {
        fprintf(stderr, "libusb_get_active_config_descriptor failed: %s\n", libusb_error_name(rc));
        goto out;
    }
    print_config(cfg, &mbim_control_if, &mbim_data_if, &mbim_interrupt_ep, &data_eps);

    if (mbim_control_if < 0) {
        fprintf(stderr, "no MBIM control interface found\n");
        rc = LIBUSB_ERROR_NOT_FOUND;
        goto out;
    }

    rc = libusb_claim_interface(handle, mbim_control_if);
    if (rc < 0) {
        fprintf(stderr, "claim interface %d failed: %s; refusing concurrent USB control\n",
                mbim_control_if, libusb_error_name(rc));
        goto out;
    } else {
        printf("claimed interface %d\n", mbim_control_if);
    }

    if (mbim_data_if >= 0) {
        int data_rc = libusb_claim_interface(handle, mbim_data_if);
        if (data_rc < 0) {
            fprintf(stderr, "warning: claim data interface %d failed: %s\n",
                    mbim_data_if, libusb_error_name(data_rc));
            rc = data_rc;
            goto out;
        } else {
            printf("claimed data interface %d\n", mbim_data_if);
            if (action == ACTION_RUN_NET) {
                int idle_rc = libusb_set_interface_alt_setting(handle, mbim_data_if, 0);
                if (idle_rc < 0) { rc = idle_rc; goto out; }
                rc = configure_ncm_transport(handle, mbim_control_if,
                    data_eps.bulk_out_max_packet, &transport);
                if (rc < 0) goto out;
            }
            int alt_rc = libusb_set_interface_alt_setting(handle, mbim_data_if, 1);
            if (alt_rc < 0) {
                fprintf(stderr, "warning: set data interface %d alt 1 failed: %s\n",
                        mbim_data_if, libusb_error_name(alt_rc));
                rc = alt_rc;
                goto out;
            } else {
                printf("set data interface %d to alt 1\n", mbim_data_if);
            }
        }
    }

    if (mbim_open(handle, mbim_control_if, mbim_interrupt_ep, &txid) == 0) {
        (void)mbim_query_device_caps(handle, mbim_control_if, mbim_interrupt_ep, &txid);
        print_basic_status(handle, mbim_control_if, mbim_interrupt_ep, &txid);
        if (action == ACTION_CONNECT_TEST) {
            int test_rc = run_connect_test(handle, mbim_control_if, mbim_interrupt_ep, &txid, apn, ip_type);
            if (test_rc < 0) {
                rc = test_rc;
            }
        } else if (action == ACTION_STATUS) {
            int status_rc = run_status(handle, mbim_control_if, mbim_interrupt_ep, &txid);
            if (status_rc < 0) {
                rc = status_rc;
            }
        } else if (action == ACTION_ACTIVATE) {
            int activate_rc = run_activate(handle, mbim_control_if, mbim_interrupt_ep, &txid, apn, ip_type);
            if (activate_rc < 0) {
                rc = activate_rc;
            }
        } else if (action == ACTION_DEACTIVATE) {
            int deactivate_rc = run_deactivate(handle, mbim_control_if, mbim_interrupt_ep, &txid, ip_type);
            if (deactivate_rc < 0) {
                rc = deactivate_rc;
            }
        } else if (action == ACTION_HOLD) {
            int hold_rc = run_hold(handle, mbim_control_if, mbim_interrupt_ep, &txid, apn, ip_type);
            if (hold_rc < 0) {
                rc = hold_rc;
            }
        } else if (action == ACTION_RUN_NET) {
            int net_rc = run_net(
                handle,
                mbim_control_if,
                mbim_interrupt_ep,
                &txid,
                &data_eps,
                &transport,
                apn,
                ip_type,
                duration_seconds,
                &takeover);
            if (net_rc < 0) {
                rc = net_rc;
            }
        }
        mbim_close(handle, mbim_control_if, mbim_interrupt_ep, &txid);
    } else {
        rc = LIBUSB_ERROR_IO;
    }

    if (mbim_data_if >= 0) {
        libusb_release_interface(handle, mbim_data_if);
    }
    if (rc == 0) {
        libusb_release_interface(handle, mbim_control_if);
    }

out:
    if (cfg) {
        libusb_free_config_descriptor(cfg);
    }
    if (handle) {
        libusb_close(handle);
    }
    libusb_exit(ctx);
    return rc < 0 ? 1 : 0;
}
