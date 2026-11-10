/* Synthetic USB only. Assert protocol/ownership/privacy boundaries. */
#include <assert.h>
#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int mode, calls, opens, claims, queries, response_reads, cancelled_test;
static unsigned ready_attempts, registration_attempts;
static uint32_t transaction, cid, type;
static unsigned char requested_service[16];
static uint32_t value32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void set32(unsigned char *p, uint32_t v) { for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static int fake_control(libusb_device_handle *handle, uint8_t direction, uint8_t request,
        uint16_t value, uint16_t interface, unsigned char *data, uint16_t length, unsigned timeout) {
    (void)handle; (void)value;
    assert(interface == 7 && timeout > 0 && timeout <= 150); calls++;
    if (request == 0) {
        assert(direction == 0x21); type = value32(data); transaction = value32(data + 8); response_reads = 0;
        if (type == 3) {
            assert(length == 48 && value32(data + 40) == 0 && value32(data + 44) == 0);
            cid = value32(data + 36); queries++;
            memcpy(requested_service, data + 20, 16);
            if (cid == 2) ready_attempts++;
            if (cid == 9) registration_attempts++;
        } else assert((type == 1 && length == 16) || (type == 2 && length == 12));
        return length;
    }
    assert(direction == 0xa1 && request == 1);
    if (mode == 1) { usleep(10000); return LIBUSB_ERROR_TIMEOUT; }
    if (mode == 2) return LIBUSB_ERROR_NO_DEVICE;
    assert(length >= 64); memset(data, 0, 64);
    set32(data, type | 0x80000000u); set32(data + 8, transaction);
    if (type != 3) { set32(data + 4, 16); return 16; }
    set32(data + 4, 56); set32(data + 12, 1);
    memcpy(data + 20, requested_service, 16); set32(data + 36, cid); set32(data + 44, 8);
    set32(data + 48, 1); set32(data + 52, 99);
    if (cid == 3) set32(data + 52, 1);
    if (cid == 9) { set32(data + 48, 0); set32(data + 52, 3); }
    if (mode == 3) set32(data + 40, 14);
    if (mode == 4) set32(data + 44, 4000);
    if (mode == 5 && response_reads++ == 0) set32(data, 0x80000007u);
    if (mode == 6) data[20] ^= 1;
    if (mode == 7) set32(data + 12, 2);
    if (mode == 8 && cid == 2 && ready_attempts <= 2) set32(data + 40, 14);
    if (mode == 8 && cid == 9 && registration_attempts == 1) set32(data + 52, 2);
    if (mode == 9 && cid == 2) set32(data + 48, 2);
    if (mode == 10 && cid == 2) set32(data + 48, 0);
    if (mode == 11 && cid == 2) set32(data + 44, 0);
    if (mode == 12 && cid == 9) set32(data + 52, 6);
    return 56;
}
static int fake_interrupt(libusb_device_handle *h, unsigned char ep, unsigned char *p,
        int length, int *count, unsigned timeout) {
    (void)h; (void)p; (void)length; assert(ep == 0x83 && timeout == 10); *count = 0; return LIBUSB_ERROR_TIMEOUT;
}
static int fake_init(libusb_context **ctx) { *ctx = (void *)1; return 0; }
static ssize_t fake_list(libusb_context *ctx, libusb_device ***list) {
    (void)ctx; static libusb_device *devices[] = {(void *)2, NULL}; *list = devices; return 1;
}
static int fake_descriptor(libusb_device *dev, struct libusb_device_descriptor *out) {
    (void)dev; memset(out, 0, sizeof(*out)); out->idVendor = 0x17ef; out->idProduct = 0x7240; return 0;
}
static int fake_config(libusb_device *dev, struct libusb_config_descriptor **out) {
    (void)dev;
    static const struct libusb_endpoint_descriptor endpoint = {.bEndpointAddress=0x83, .bmAttributes=3, .wMaxPacketSize=64};
    static const struct libusb_interface_descriptor alt = {.bInterfaceNumber=7, .bInterfaceClass=2, .bInterfaceSubClass=14, .bNumEndpoints=1, .endpoint=&endpoint};
    static const struct libusb_interface iface = {.altsetting=&alt, .num_altsetting=1};
    static struct libusb_config_descriptor config = {.bNumInterfaces=1, .interface=&iface};
    *out = &config; return 0;
}
static int fake_speed(libusb_device *dev) { (void)dev; return LIBUSB_SPEED_HIGH; }
static int fake_open(libusb_device *dev, libusb_device_handle **handle) { (void)dev; opens++; *handle=(void *)3; return 0; }
static int fake_claim(libusb_device_handle *h, int iface) { (void)h; assert(iface==7); claims++; return 0; }
static int fake_release(libusb_device_handle *h, int iface) { (void)h; assert(iface==7); return 0; }
static void fake_close(libusb_device_handle *h) { (void)h; }
static void fake_free_config(struct libusb_config_descriptor *c) { (void)c; }
static void fake_free_list(libusb_device **list, int unref) { (void)list; (void)unref; }
static void fake_exit(libusb_context *ctx) { (void)ctx; }
static int fake_cancelled(void *ctx) { (void)ctx; return cancelled_test; }

#define libusb_control_transfer fake_control
#define libusb_interrupt_transfer fake_interrupt
#define libusb_init fake_init
#define libusb_get_device_list fake_list
#define libusb_get_device_descriptor fake_descriptor
#define libusb_get_active_config_descriptor fake_config
#define libusb_get_device_speed fake_speed
#define libusb_open fake_open
#define libusb_claim_interface fake_claim
#define libusb_release_interface fake_release
#define libusb_close fake_close
#define libusb_free_config_descriptor fake_free_config
#define libusb_free_device_list fake_free_list
#define libusb_exit fake_exit
#define main inspection_main
#include "../backend/device_info.c"
#undef main
#define MBIM_STARTUP_RETRY_MS 1
#include "../backend/mbim_startup.h"

int main(void) {
    uint32_t tx=0, length, status; uint8_t info[512], reply[64], set[48]={0};
    struct mbim_ro_context context={(void *)1,7,0x83,&tx,fake_cancelled,NULL};
    assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==0 && length==8 && status==0);
    puts("PASS bounded transport issues QUERY only on the provided handle");
    mode=3; assert(mbim_ro_query(&context,2,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_OTHER && status==14 && length==0);
    puts("PASS NotInitialized remains distinct from USB transport errors");
    mode=4; assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_OVERFLOW);
    mode=6; assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_IO);
    mode=7; assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_IO);
    puts("PASS malformed lengths, service IDs and fragments are rejected");
    mode=5; assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==0 && response_reads==2);
    puts("PASS unrelated indications are ignored without emitting payloads");
    mode=1; double began=mbim_ro_clock();
    assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,60)==LIBUSB_ERROR_TIMEOUT && mbim_ro_clock()-began<0.25);
    puts("PASS missing responses obey the total query budget");
    mode=0; cancelled_test=1; int before=calls; uint32_t previous_tx=tx;
    assert(mbim_ro_query(&context,11,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_INTERRUPTED && calls==before && tx==previous_tx);
    cancelled_test=0; mbim_ro_put(set,3); mbim_ro_put(set+40,1);
    assert(mbim_ro_exchange(&context,set,sizeof(set),0x80000003u,1,reply,sizeof(reply),200)==LIBUSB_ERROR_INVALID_PARAM && calls==before);
    puts("PASS cancellation and SET rejection make zero USB calls");
    before=opens; char *descriptor_args[]={"device-info","--descriptors",NULL};
    assert(inspection_main(2,descriptor_args)==0 && opens==before && claims==0);
    puts("PASS descriptor-only inspection never opens or claims USB");
    char *query_args[]={"device-info","--query",NULL};
    before=queries; assert(inspection_main(2,query_args)==0 && opens==1 && claims==1 && queries-before==7);
    puts("PASS explicit inspection claims only control and queries the allowlisted CIDs");
    mode=8; ready_attempts=registration_attempts=0;
    struct mbim_startup_result ready=mbim_wait_initialized(&context,200);
    assert(ready.rc==0 && ready.ready_state==1 && ready.register_state==3 && ready_attempts>=3);
    puts("PASS transient initialization and searching wait until ready using QUERYs only");
    mode=9; before=queries; ready=mbim_wait_initialized(&context,200);
    assert(ready.rc<0 && strcmp(ready.reason,"sim_not_inserted")==0 && queries==before+1);
    mode=12; ready=mbim_wait_initialized(&context,200);
    assert(ready.rc<0 && strcmp(ready.reason,"registration_denied")==0);
    puts("PASS absent SIM and denied registration fail without activation");
    mode=10; began=mbim_ro_clock(); ready=mbim_wait_initialized(&context,40);
    assert(ready.rc==LIBUSB_ERROR_TIMEOUT && strcmp(ready.reason,"initialization_timeout")==0 && mbim_ro_clock()-began<0.2);
    puts("PASS persistent unready state has a bounded exit");
    mode=11; ready=mbim_wait_initialized(&context,200);
    assert(ready.rc==LIBUSB_ERROR_IO && strcmp(ready.reason,"invalid_ready_response")==0);
    mode=2; ready=mbim_wait_initialized(&context,200); assert(ready.rc==LIBUSB_ERROR_NO_DEVICE);
    puts("PASS malformed readiness and removed hardware cannot authorize activation");
    mode=0; assert(mbim_ro_query_service(&context,mbim_ro_atds,1,info,sizeof(info),&length,&status,200)==0);
    assert(memcmp(requested_service,mbim_ro_atds,16)==0);
    mode=6; assert(mbim_ro_query_service(&context,mbim_ro_atds,1,info,sizeof(info),&length,&status,200)==LIBUSB_ERROR_IO);
    puts("PASS extension replies are bound to their exact advertised service");
    uint8_t services[48]={0}; set32(services,1); set32(services+8,16); set32(services+12,32);
    memcpy(services+16,mbim_ro_atds,16); set32(services+40,1); set32(services+44,1);
    assert(mbim_service_supports(services,sizeof(services),mbim_ro_atds,1));
    assert(!mbim_service_supports(services,sizeof(services),mbim_ro_firmware_id,1));
    set32(services+8,4); assert(!mbim_services_valid(services,sizeof(services)));
    set32(services+8,16); set32(services+40,2); assert(!mbim_services_valid(services,sizeof(services)));
    puts("PASS incomplete and overlapping service references cannot authorize extension queries");
    assert(!mbim_radio_scaled(255,97,-140,1).known);
    assert(mbim_radio_scaled(0,97,-140,1).limit==-1);
    assert(mbim_radio_scaled(97,97,-140,1).limit==1);
    assert(mbim_radio_scaled(50,97,-140,1).value==-90);
    puts("PASS unknown signal values and bounded endpoints are not presented as exact readings");
    puts("ALL 15 READ-ONLY INSPECTION TESTS PASSED; USB mocked, no network or device mutations");
    return 0;
}
