#ifndef MAGIC_BAY_MBIM_CAPABILITIES_H
#define MAGIC_BAY_MBIM_CAPABILITIES_H
#include "mbim_readonly.h"

/* Protocol identifiers/layouts verified against libmbim's public ATDS and
 * MS Firmware ID schemas. These identify services, not individual devices. */
static const uint8_t mbim_ro_atds[16] = {
    0x59,0x67,0xbd,0xcc,0x7f,0xd2,0x49,0xa2,0x9f,0x5c,0xb2,0xe7,0x0e,0x52,0x7d,0xb3
};
static const uint8_t mbim_ro_firmware_id[16] = {
    0xe9,0xf7,0xde,0xa2,0xfe,0xaf,0x40,0x09,0x93,0xce,0x90,0xa3,0x69,0x41,0x03,0xb6
};

static inline int mbim_services_valid(const uint8_t *info, uint32_t bytes) {
    if (!info || bytes < 8) return 0;
    uint32_t count = mbim_ro_u32(info);
    if (count > 64 || count > (bytes - 8) / 8) return 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t offset = mbim_ro_u32(info + 8 + i * 8), size = mbim_ro_u32(info + 12 + i * 8);
        if (size < 28 || offset < 8 + count * 8 || offset % 4 || offset > bytes || size > bytes - offset ||
            mbim_ro_u32(info + offset + 24) > 128 || mbim_ro_u32(info + offset + 24) > (size - 28) / 4) return 0;
    }
    return 1;
}
static inline int mbim_service_supports(const uint8_t *info, uint32_t bytes, const uint8_t uuid[16], uint32_t cid) {
    if (!mbim_services_valid(info, bytes)) return 0;
    for (uint32_t i = 0; i < mbim_ro_u32(info); i++) {
        const uint8_t *service = info + mbim_ro_u32(info + 8 + i * 8);
        if (memcmp(service, uuid, 16)) continue;
        for (uint32_t j = 0; j < mbim_ro_u32(service + 24); j++)
            if (mbim_ro_u32(service + 28 + j * 4) == cid) return 1;
    }
    return 0;
}

struct mbim_radio_value { int known; double value; int limit; }; /* -1 <=, 0 exact, +1 >= */
static inline struct mbim_radio_value mbim_radio_scaled(uint32_t raw, uint32_t maximum, double base, double step) {
    struct mbim_radio_value value = {0, 0, 0};
    if (raw > maximum) return value;
    value.known = 1; value.value = base + step * raw;
    value.limit = raw == 0 ? -1 : raw == maximum ? 1 : 0;
    return value;
}
#endif
