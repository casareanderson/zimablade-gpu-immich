#!/usr/bin/env bash
# zima-gpu-check.sh — read-only diagnosis of a GPU fitted to a ZimaBlade.
#
# Runs every check from the guide in one pass. Modifies nothing, needs no root.
# Tested on ZimaOS (ZimaBlade 7700) with an NVIDIA Quadro P600 on a VER009S riser.
#
#   ./zima-gpu-check.sh
#
# The PCIe root port that serves the ZimaBlade's slot is 00:13.0. Override with
# ROOT_PORT=xx:xx.x if your board differs.

set -uo pipefail

ROOT_PORT="${ROOT_PORT:-00:13.0}"

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note()    { printf '   %s\n' "$1"; }

# Several checks below read PCIe capability registers and physical memory
# windows. Both are privileged: an unprivileged lspci silently omits LnkCap /
# SltCap / DevSta, and an unprivileged /proc/iomem reads back as all zeros
# rather than erroring. Detect that up front — the empty output looks exactly
# like a hardware fault otherwise, which is a great way to waste an evening.
PRIV=1
if [ "$(id -u)" -ne 0 ]; then
    PRIV=0
    printf '\n\033[1;33m!! Running unprivileged — sections 01, 02, 03 and 06 need root.\033[0m\n'
    note "Sections 04, 05, 07, 08 and 09 are accurate as-is."
    note ""
    note "On a normal Linux box:  sudo $0"
    note "On ZimaOS (no sudo password), run it through a privileged container:"
    note "  docker run --rm --privileged --pid=host -v /:/host -v \$PWD:/w \\"
    note "    alpine sh -c 'apk add -q pciutils bash && chroot /host /bin/bash' \\"
    note "    < /dev/null   # then: bash /w/$(basename "$0")"
fi

section "01  Slot capabilities (what the slot can carry)"
# Read once into a variable. Piping lspci straight into `grep -q` kills lspci
# with SIGPIPE, and under `set -o pipefail` that makes the whole test fail even
# when the match succeeded — reporting a healthy slot as missing.
PORT_INFO=$(lspci -vvv -s "$ROOT_PORT" 2>/dev/null)
if printf '%s' "$PORT_INFO" | grep -qE "LnkCap"; then
    printf '%s' "$PORT_INFO" | grep -E "LnkCap|SltCap|Slot #" | sed 's/^[[:space:]]*/   /'
    note ""
    note "Width x4 + PowerLimit 25W is the stock ZimaBlade ceiling."
    note "HotPlug- means cold boot is the only way to enumerate a card."
elif [ "$PRIV" -eq 0 ]; then
    note "skipped — capability registers are root-only, and lspci omits them"
    note "silently rather than complaining. Re-run as root."
elif ! command -v lspci >/dev/null 2>&1; then
    note "lspci not installed (package: pciutils)."
else
    note "Root port $ROOT_PORT not found — is this a ZimaBlade?"
    note "Override with: ROOT_PORT=xx:xx.x $0"
fi

section "02  Above-4G decoding (the silent card-killer)"
IOMEM=$(grep "PCI Bus" /proc/iomem 2>/dev/null)
if [ -z "$IOMEM" ]; then
    note "no PCI windows readable."
elif ! printf '%s' "$IOMEM" | grep -qvE "^\s*0+-0+ "; then
    # Unprivileged readers get 00000000-00000000 for every line, not an error.
    note "all windows read 00000000-00000000 — that is /proc/iomem being"
    note "redacted for an unprivileged reader, NOT a hardware problem."
    note "Re-run as root for real addresses."
else
    printf '%s\n' "$IOMEM" | sed 's/^/   /'
    note ""
    note "Every window below 4 GB (addresses under 100000000) means no Above-4G."
    note "A card whose VRAM aperture exceeds the largest window cannot work here."
fi

section "03  Presence detect (is the riser physically seated?)"
# Must come from the SltSta line specifically. SltCtl carries its own PresDet
# flag — that one is the hot-plug *interrupt enable*, not whether a card is
# present, and it reads PresDet- on a perfectly healthy seated card.
PRESDET=$(printf '%s' "$PORT_INFO" | grep "SltSta:" | grep -o "PresDet[+-]" | head -1)
case "$PRESDET" in
    "PresDet+") note "PresDet+  slot and riser board are making contact." ;;
    "PresDet-") note "PresDet-  nothing seated, or the riser is dead." ;;
    *) if [ "$PRIV" -eq 0 ]; then
           note "skipped — SltSta is a root-only register. Re-run as root."
       else
           note "not reported by this root port."
       fi ;;
esac
note ""
note "Proves only that a board is in the slot — says nothing about the"
note "USB 3 cable, the x16 board or the card itself."

section "04  Link training (presence is not a link)"
for dev in /sys/bus/pci/devices/0000:"$ROOT_PORT" /sys/bus/pci/devices/0000:01:00.0; do
    [ -d "$dev" ] || continue
    cur=$(cat "$dev/current_link_width" 2>/dev/null || echo "n/a")
    max=$(cat "$dev/max_link_width"     2>/dev/null || echo "n/a")
    spd=$(cat "$dev/current_link_speed" 2>/dev/null || echo "n/a")
    note "$(basename "$dev")  width ${cur}/${max}  speed ${spd}"
done
note ""
note "width 0  = never trained. Physical fault; no driver or rescan will help."
note "width 1  = trained at x1. Expected on a VER009S riser."
note "A speed of 2.5GT/s on a 5GT/s-capable link means it stepped down —"
note "usually marginal signalling. Suspect the USB 3 cable."

section "05  Is a GPU on the bus at all?"
if lspci -nn 2>/dev/null | grep -iE "vga|3d|display" | sed 's/^/   /' | grep -q .; then
    lspci -nn 2>/dev/null | grep -iE "vga|3d|display" | sed 's/^/   /'
else
    note "No VGA/3D/Display device found. If the fan spins but nothing appears"
    note "here, that is a data-lane fault, not a power fault."
fi

section "06  Link error counters (is the link complaining?)"
DEVSTA=$(printf '%s' "$PORT_INFO" | grep -E "DevSta|LnkSta:")
if [ -n "$DEVSTA" ]; then
    printf '%s\n' "$DEVSTA" | sed 's/^[[:space:]]*/   /'
    note ""
    note "CorrErr+ / NonFatalErr+ / UnsupReq+ mean errors are actually being"
    note "counted — signal integrity, not software."
elif [ "$PRIV" -eq 0 ]; then
    note "skipped — DevSta is a root-only register. Re-run as root."
else
    note "no DevSta reported."
fi

section "07  Driver state"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,pstate --format=csv 2>&1 | sed 's/^/   /'
    note ""
    note "'Unable to determine the device handle' is the post-mortem state after"
    note "an Xid 79 — it describes the corpse, not the cause. See section 08."
else
    note "nvidia-smi not present."
fi
note ""
dmesg 2>/dev/null | grep -E "NVRM: loading|nvidia-drm" | tail -3 | sed 's/^/   /' \
    || note "(dmesg unreadable without privileges — try via a privileged container)"

section "08  Xid history (did it work, then die?)"
XIDS=$(dmesg 2>/dev/null | grep -E "Xid|fallen off the bus" | tail -10)
if [ -n "$XIDS" ]; then
    printf '%s\n' "$XIDS" | sed 's/^/   /'
    note ""
    note "Xid 79  = GPU fell off the bus. Power delivery or PCIe signal integrity."
    note "Xid 154 = GPU Reset Required. It will not recover without a reboot."
else
    note "No Xid events logged. Either healthy, or dmesg has rotated past them."
fi

section "09  Immich ML container (is it actually on the GPU?)"
if command -v docker >/dev/null 2>&1; then
    IMG=$(docker inspect immich-machine-learning --format '{{.Config.Image}}' 2>/dev/null)
    if [ -n "$IMG" ]; then
        note "image: $IMG"
        case "$IMG" in
            *-cuda*) note "        CUDA variant — correct." ;;
            *)       note "        NOT the -cuda tag. This will run on CPU forever." ;;
        esac
        docker inspect immich-machine-learning \
            --format '   devices: {{.HostConfig.DeviceRequests}}' 2>/dev/null
        note ""
        note "Recent CPU fallbacks (the silent failure mode):"
        docker logs --tail 500 immich-machine-learning 2>&1 \
            | grep -iE "CUDA failure|CPUExecutionProvider" | tail -3 | sed 's/^/   /' \
            || note "   none — good."
    else
        note "immich-machine-learning container not found."
    fi
else
    note "docker not available to this user."
fi

printf '\n'
