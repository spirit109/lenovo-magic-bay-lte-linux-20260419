#include <assert.h>
#include <stdio.h>
#include "../backend/mbim_settings.h"
int main(void) {
    const uint8_t expected_sar[16]={0x68,0x22,0x3d,0x04,0x9f,0x6c,0x4e,0x0f,0x82,0x2d,0x28,0x44,0x1f,0xb7,0x23,0x40};
    assert(memcmp(mbim_settings_sar,expected_sar,16)==0);
    puts("PASS MS SAR identifier matches upstream; unknown vendor services are not relabeled as SAR");
    uint8_t value[32]={0};uint32_t mode;
    for(uint32_t i=0;i<4;i++){mbim_ro_put(value,i);assert(mbim_settings_rat(value,4,&mode)&&mode==i);}
    mbim_ro_put(value,4);assert(!mbim_settings_rat(value,4,&mode));
    assert(!mbim_settings_rat(value,3,&mode));
    puts("PASS four documented RAT modes accepted; unknown/truncated modes rejected");
    memset(value,0,sizeof(value));assert(mbim_settings_sar_valid(value,16));
    mbim_ro_put(value,1);mbim_ro_put(value+4,1);mbim_ro_put(value+8,1);mbim_ro_put(value+12,1);
    mbim_ro_put(value+16,24);mbim_ro_put(value+20,8);mbim_ro_put(value+24,0);mbim_ro_put(value+28,5);
    assert(mbim_settings_sar_valid(value,32));
    puts("PASS SAR status and bounded antenna reference decoded without interpreting index as transmit power");
    mbim_ro_put(value+16,4);assert(!mbim_settings_sar_valid(value,32));
    mbim_ro_put(value+16,24);mbim_ro_put(value+20,12);assert(!mbim_settings_sar_valid(value,32));
    mbim_ro_put(value+20,8);mbim_ro_put(value+4,2);assert(!mbim_settings_sar_valid(value,32));
    assert(!mbim_settings_sar_valid(value,15));
    puts("PASS overlapping references, overruns, unknown state and incomplete frames remain unknown");
    puts("ALL 4 SETTINGS DECODER TESTS PASSED; no USB opened or network operations");
    return 0;
}
