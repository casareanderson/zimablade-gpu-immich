#!/bin/bash
# zima-gpu-watch.sh — is the GPU still on the bus? Run it every few minutes from cron or a timer.
#
# Why: on the author's ZimaBlade a Quadro P600 on a powered riser ran for hours and then logged
# "Xid 79, GPU has fallen off the bus", and stayed gone until a reboot. Immich quietly fell back to
# the CPU, so nothing looked broken. This records how long the GPU survives each boot, and alerts
# ONCE per change (alive -> dead, dead -> alive), never on every run.
#
# Read-only: it runs nvidia-smi and reads /proc/uptime. It changes nothing on the machine it checks.
#
#   ZIMA=you@zima bash zima-gpu-watch.sh       # from another always-on machine, over SSH (recommended)
#   LOCAL=1 bash zima-gpu-watch.sh             # on the machine with the GPU itself
#
# Settings (environment):
#   ZIMA         user@host to SSH to (key auth). Required unless LOCAL=1.
#   LOCAL        1 = check this machine instead of SSHing anywhere.
#   GPU_MATCH    text that must appear in the GPU's name to count as alive, e.g. "P600". Default: any GPU.
#   WEBHOOK      optional URL that accepts {"content": "..."} (Discord, and anything compatible). Alerts are
#                always printed to stdout as well, so cron mail or a log still gets them.
#   STATE_DIR    where the log and state live. Default ~/.local/state
#   NVIDIA_SMI   the nvidia-smi command. Default nvidia-smi. (The setup check uses a stand-in here.)
#   SSH_TIMEOUT  seconds before an SSH attempt counts as unreachable. Default 15.
#
# Exit code is always 0 unless the settings are wrong (2): a dead GPU is a result, not an error.
set -uo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.local/state}"
LOG="$STATE_DIR/zima-gpu-watch.log"
STATE="$STATE_DIR/zima-gpu-watch.state"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
GPU_MATCH="${GPU_MATCH:-}"
SSH_TIMEOUT="${SSH_TIMEOUT:-15}"
mkdir -p "$STATE_DIR"

PROBE="$NVIDIA_SMI --query-gpu=name,temperature.gpu,pcie.link.width.current --format=csv,noheader 2>&1; echo \"rc=\$?\"; cut -d' ' -f1 /proc/uptime"

if [ "${LOCAL:-0}" = 1 ]; then
    out=$(bash -c "$PROBE" 2>&1)
    reached=1
elif [ -n "${ZIMA:-}" ]; then
    out=$(ssh -n -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$ZIMA" "$PROBE" 2>&1)
    grep -q '^rc=' <<<"$out" && reached=1 || reached=0
else
    echo "set ZIMA=user@host (or LOCAL=1 to check this machine)" >&2
    exit 2
fi

# Unreachable is not dead. A reboot, a busy minute or a network blip must not read as "GPU gone".
if [ "$reached" != 1 ]; then
    echo "$(date '+%F %T') unreachable - not judging the GPU ($(head -1 <<<"$out"))" | tee -a "$LOG"
    exit 0
fi

rc=$(grep -o '^rc=[0-9]*' <<<"$out" | cut -d= -f2)
first=$(head -1 <<<"$out")
up_h=$(tail -1 <<<"$out" | awk '{printf "%.1f", $1/3600}')
if [ "$rc" = 0 ] && { [ -z "$GPU_MATCH" ] || grep -qF "$GPU_MATCH" <<<"$first"; }; then
    now=alive
else
    now=dead
fi
prev=$(cat "$STATE" 2>/dev/null || echo unknown)
echo "$(date '+%F %T') $now uptime=${up_h}h $first" | tee -a "$LOG"

[ "$now" = "$prev" ] && exit 0
echo "$now" > "$STATE"
if [ "$prev" = unknown ]; then
    echo "first run: recorded $now as the starting state, no alert"
    exit 0
fi

# Only letters, digits and a few safe characters from the GPU's own output go into the alert.
name=$(cut -d, -f1 <<<"$first" | tr -cd 'A-Za-z0-9 ._-' | cut -c1-60)
if [ "$now" = dead ]; then
    msg="GPU fell off the bus after about ${up_h} h of uptime. Anything using it (Immich ML, NVENC) falls back to the CPU until it is back. It needs a reboot to return, and a riser or ground fix to stay."
else
    msg="GPU is back: ${name:-a GPU} answering, uptime ${up_h} h."
fi
echo "ALERT: $msg"
if [ -n "${WEBHOOK:-}" ]; then
    curl -fsS -m 20 -H 'Content-Type: application/json' -d "{\"content\": \"$msg\"}" "$WEBHOOK" > /dev/null \
        || echo "$(date '+%F %T') webhook post failed" | tee -a "$LOG"
fi
exit 0
