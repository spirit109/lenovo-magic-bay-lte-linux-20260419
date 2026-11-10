/* Offline maintenance helper: fixed, advertised QUERYs only. Does not modify
 * the installed app. Caller verifies no active MBIM owner before --query. */
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include "mbim_settings.h"

static volatile sig_atomic_t stopped;
static int is_stopped(void *ctx) { (void)ctx; return stopped; }
static void cancel(int value) { (void)value; stopped = 1; }
#ifndef _WIN32
static void deadline(int value) { (void)value; _exit(124); }
#endif

static void inspect_setting(struct mbim_ro_context *ctx, const uint8_t *services, uint32_t bytes,
        const char *name, const uint8_t uuid[16], uint32_t cid, int sar) {
    printf(",\"%s\":{\"advertised\":", name);
    if (!mbim_services_valid(services, bytes)) { printf("null,\"available\":false,\"reason\":\"service_inventory_unknown\"}"); return; }
    if (!mbim_service_supports(services, bytes, uuid, cid)) { printf("false,\"available\":false,\"reason\":\"not_advertised\"}"); return; }
    uint8_t info[1024]; uint32_t length, status;
    int rc = mbim_ro_query_service(ctx, uuid, cid, info, sizeof(info), &length, &status, 1500);
    printf("true,\"rc\":%d,\"mbim_status\":", rc);
    if (status == UINT32_MAX) printf("null"); else printf("%u", status);
    uint32_t mode = 0;
    int valid = rc == 0 && (sar ? mbim_settings_sar_valid(info, length) : mbim_settings_rat(info, length, &mode));
    printf(",\"available\":%s", valid ? "true" : "false");
    if (valid && !sar) {
        const char *names[] = {"automatic", "2g_only", "3g_only", "4g_only"};
        printf(",\"mode\":%u,\"mode_name\":\"%s\"", mode, names[mode]);
    } else if (valid) {
        printf(",\"control_mode\":%u,\"backoff_state\":%u,\"wifi_integration\":%u,\"antenna_config_count\":%u",
            mbim_ro_u32(info), mbim_ro_u32(info + 4), mbim_ro_u32(info + 8), mbim_ro_u32(info + 12));
    }
    printf("}"); fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--query")) { fprintf(stderr,"usage: magic-bay-device-info --query (idle modem only)\n"); return 64; }
    signal(SIGTERM,cancel); signal(SIGINT,cancel);
#ifndef _WIN32
    signal(SIGALRM,deadline); alarm(20);
#endif
    libusb_context *usb = NULL; libusb_device **list = NULL; libusb_device *selected = NULL;
    libusb_device_handle *handle = NULL; struct libusb_config_descriptor *config = NULL;
    int rc = libusb_init(&usb), control = -1, claimed = 0; uint8_t interrupt = 0; unsigned matches = 0;
    if (rc < 0) return 1;
    ssize_t total = libusb_get_device_list(usb,&list);
    for (ssize_t i=0;i<total;i++) {
        struct libusb_device_descriptor desc;
        if (!libusb_get_device_descriptor(list[i],&desc) && desc.idVendor==0x17ef && desc.idProduct==0x7240) { selected=list[i];matches++; }
    }
    printf("{\"schema\":1,\"mode\":\"settings_read_only\",\"matching_devices\":%u,\"set_commands\":0,\"data_interface_changes\":0",matches);
    if (matches != 1) { rc=LIBUSB_ERROR_NOT_FOUND; goto done; }
    rc=libusb_get_active_config_descriptor(selected,&config); if(rc<0)goto done;
    for(unsigned i=0;i<config->bNumInterfaces;i++)for(int j=0;j<config->interface[i].num_altsetting;j++) {
        const struct libusb_interface_descriptor *alt=&config->interface[i].altsetting[j];
        if(alt->bInterfaceClass!=2 || alt->bInterfaceSubClass!=14 || alt->bAlternateSetting!=0)continue;
        for(unsigned k=0;k<alt->bNumEndpoints;k++)if((alt->endpoint[k].bmAttributes&3)==3 && (alt->endpoint[k].bEndpointAddress&0x80)) {
            control=alt->bInterfaceNumber;interrupt=alt->endpoint[k].bEndpointAddress;
        }
    }
    if(control<0){rc=LIBUSB_ERROR_NOT_FOUND;goto done;}
    rc=libusb_open(selected,&handle);if(rc<0)goto done;
    rc=libusb_claim_interface(handle,control);if(rc<0)goto done;claimed=1;
    uint32_t tx=0,length=0,status=UINT32_MAX;uint8_t services[4096];
    struct mbim_ro_context ctx={handle,control,interrupt,&tx,is_stopped,NULL};
    rc=mbim_ro_session(&ctx,1,1500);if(rc<0)goto done;
    int inventory_rc=mbim_ro_query(&ctx,16,services,sizeof(services),&length,&status,1500);
    printf(",\"service_inventory_rc\":%d",inventory_rc);
    if(inventory_rc!=0)length=0;
    inspect_setting(&ctx,services,length,"rat_preference",mbim_ro_atds,4,0);
    inspect_setting(&ctx,services,length,"sar_config",mbim_settings_sar,1,1);
    ctx.cancelled=NULL;
    printf(",\"control_close_rc\":%d",mbim_ro_session(&ctx,0,600));
done:
    printf(",\"result\":%d}\n",rc);fflush(stdout);
    if(claimed)libusb_release_interface(handle,control);
    if(handle)libusb_close(handle);
    if(config)libusb_free_config_descriptor(config);
    if(list)libusb_free_device_list(list,1);
    libusb_exit(usb);return rc<0?1:0;
}
