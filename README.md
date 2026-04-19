# Lenovo Magic Bay LTE on Ubuntu/Linux

This repo records the exact steps used on `2026-04-19` to bring a Lenovo `MDM9207-MTP` 4G device online on Ubuntu.

## Verified Environment

- OS: Ubuntu 24.04
- Kernel: `6.17.0-19-generic`
- Device USB ID: `17ef:7240`
- Device name: `Lenovo Magic Bay LTE`
- Modem stack: `cdc_mbim` + `ModemManager` + `NetworkManager`
- Carrier detected during test: `CHN-UNICOM`

## What Was Confirmed

- Linux can recognize the device as a standard MBIM modem.
- `ModemManager` can manage it normally.
- The device can register to LTE and attach packet service on Linux.
- The final working APN in this environment was `3gnet`.
- Adding username `uninet` caused NetworkManager to ask for a password and stall.
- Removing username and password allowed the connection to succeed.

## Key Commands Used

Inspect USB device:

```bash
lsusb
usb-devices | sed -n '/Vendor=17ef/,/^$/p'
lsusb -d 17ef:7240 -v
```

Inspect modem state:

```bash
mmcli -L
mmcli -m 3
nmcli device status
nmcli radio all
```

Enable WWAN if it is disabled:

```bash
nmcli radio wwan on
```

Create a working China Unicom connection:

```bash
nmcli connection add type gsm ifname '*' con-name 'China Unicom LTE' apn '3gnet'
nmcli connection modify 'China Unicom LTE' connection.autoconnect yes ipv4.method auto ipv6.method ignore
nmcli connection modify 'China Unicom LTE' gsm.username '' gsm.password '' gsm.password-flags 1
nmcli connection up 'China Unicom LTE'
```

Disconnect:

```bash
nmcli connection down 'China Unicom LTE'
```

## Working Result

After the final fix:

- `nmcli device status` showed `cdc-wdm1` as `connected`
- `wwan0` received an IPv4 address
- default routes existed for both Wi-Fi and 4G
- Wi-Fi remained preferred because its route metric was lower

## Notes and Risks

- The modem reported `lock: sim-pin2` and `enabled locks: fixed-dialing`, but that did not block LTE registration in this session.
- Do not blindly try PIN2 unlock commands. Retry counts are limited.
- If the modem shows `registered` and `attached`, there is usually no need to replug the device.
- If `WWAN` is disabled in NetworkManager, the modem may stay unavailable even though USB detection is fine.

## Reuse Checklist

1. Plug in the device and confirm `lsusb` shows `17ef:7240`.
2. Confirm `ModemManager` sees the modem with `mmcli -L`.
3. Run `nmcli radio wwan on`.
4. Check `mmcli -m <id>` until the modem reaches `registered`.
5. Create or activate the `China Unicom LTE` connection using APN `3gnet`.
6. Verify `wwan0` gets an IP address.

## Helper Script

See [`check_modem_status.sh`](./check_modem_status.sh) for a quick read-only status dump.
