#!/usr/bin/env bash

set -euo pipefail

echo "== date =="
date

echo
echo "== usb =="
lsusb | grep -i '17ef:7240\|Lenovo'

echo
echo "== modem list =="
mmcli -L || true

echo
echo "== radio state =="
nmcli radio all || true

echo
echo "== device status =="
nmcli device status || true

echo
echo "== modem details =="
mmcli -m 3 || true

echo
echo "== wwan addr =="
ip -brief addr show wwan0 || true

echo
echo "== default routes =="
ip route show default || true
