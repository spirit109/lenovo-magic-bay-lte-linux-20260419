#ifndef MAGIC_BAY_MBIM_SETTINGS_H
#define MAGIC_BAY_MBIM_SETTINGS_H
#include "mbim_capabilities.h"

/* MS SAR Config: documented QUERY with no input payload. No SET interface. */
static const uint8_t mbim_settings_sar[16] = {
    0x68,0x22,0x3d,0x04,0x9f,0x6c,0x4e,0x0f,0x82,0x2d,0x28,0x44,0x1f,0xb7,0x23,0x40
};
static inline int mbim_settings_rat(const uint8_t *info, uint32_t bytes, uint32_t *mode) {
    if (!info || bytes != 4 || mbim_ro_u32(info) > 3) return 0;
    *mode = mbim_ro_u32(info); return 1;
}
static inline int mbim_settings_sar_valid(const uint8_t *info, uint32_t bytes) {
    if (!info || bytes < 16 || mbim_ro_u32(info) > 1 || mbim_ro_u32(info + 4) > 1 ||
        mbim_ro_u32(info + 8) > 1) return 0;
    uint32_t count = mbim_ro_u32(info + 12);
    if (count > 64 || count > (bytes - 16) / 8) return 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t offset = mbim_ro_u32(info + 16 + i * 8), size = mbim_ro_u32(info + 20 + i * 8);
        if (offset < 16 + count * 8 || offset % 4 || size != 8 || offset > bytes || size > bytes - offset) return 0;
    }
    return 1;
}
#endif
