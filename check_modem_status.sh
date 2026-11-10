#!/usr/bin/env bash
# Read-only Linux status summary. Review output before sharing it publicly.
set -u
set -o pipefail
export LC_ALL=C

echo '== USB: Lenovo Magic Bay LTE (17ef:7240) =='
if command -v lsusb >/dev/null 2>&1; then
    if lsusb | grep -i '17ef:7240' >/dev/null; then
        echo 'Found USB ID 17ef:7240.'
    else
        echo 'Device not found in lsusb output.'
    fi
else
    echo 'lsusb unavailable; install usbutils.'
fi

echo
echo '== ModemManager =='
if command -v mmcli >/dev/null 2>&1; then
    if ! modem_list=$(mmcli -L 2>/dev/null); then
        echo 'ModemManager unavailable or inaccessible.'
        modem_list=''
    fi
    indices=$(printf '%s\n' "$modem_list" | sed -nE 's|.*/org/freedesktop/ModemManager1/Modem/([0-9]+).*|\1|p')
    # The extracted values contain digits and newlines only.
    set -- $indices
    printf 'Modem indices:'
    printf ' %s' "$@"
    printf '\n'
    if [ "$#" -eq 1 ]; then
        echo '== Single modem: selected status fields (verify it is the Magic Bay) =='
        mmcli -m "$1" --output-keyvalue 2>/dev/null | awk '
            /^[[:space:]]*modem\.generic\.(state|state-failed-reason|signal-quality\.value|signal-quality\.recent|access-technologies)[[:space:]]*:/ {print; found=1}
            END {if (!found) exit 1}
        ' || echo 'Selected modem status unavailable.'
    elif [ "$#" -gt 1 ]; then
        echo 'Multiple modems found; select the intended index from mmcli -L.'
    else
        echo 'No modem index found.'
    fi
else
    echo 'mmcli unavailable; install ModemManager.'
fi

echo
echo '== NetworkManager =='
if command -v nmcli >/dev/null 2>&1; then
    nmcli radio all || true
    nmcli -f DEVICE,TYPE,STATE device status || true
else
    echo 'nmcli unavailable; install NetworkManager.'
fi

echo
echo '== Default-route interfaces (addresses omitted) =='
if command -v ip >/dev/null 2>&1; then
    ip -o route show default 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "dev") print $(i+1)}' || true
else
    echo 'ip command unavailable; install iproute2.'
fi

echo 'Review output before sharing; detailed modem commands may reveal device or SIM identifiers.'
