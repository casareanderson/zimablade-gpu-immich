# Setting up the ZimaBlade GPU tools

Two scripts and a compose fragment:

- **`diagnostics/zima-gpu-check.sh`** reads everything about the slot, the link, the driver and Immich in one
  read-only pass. Run it when a card won't show up, or after it dies.
- **`diagnostics/zima-gpu-watch.sh`** checks every few minutes whether the GPU is still on the bus, logs how long it
  survives each boot, and alerts once when it falls off (and once when it's back).
- **`immich/docker-compose.gpu.yml`** puts Immich machine learning on the GPU.

Read the [guide in the README](../README.md#how-it-works-the-field-guide) before buying a card: the slot's 25 W limit
and the missing Above-4G decoding rule out more cards than anything here can fix.

The blocks marked as tested run on a fresh Ubuntu runner every week in
[`setup-check`](../.github/workflows/setup-check.yml). The runner has no GPU, so CI proves that both scripts run
cleanly on a machine without one, and that the watcher's alive/dead logic alerts exactly once per change (using a
stand-in for `nvidia-smi`). The steps on your Zima aren't marked.

## What you need

- A ZimaBlade (or any Linux box with a GPU in a PCIe slot) and a shell on it.
- For the full check: root. On ZimaOS, where the SSH user has no sudo password, that means the privileged-container
  route below.
- For the watcher: another always-on Linux machine with SSH key access to the Zima (recommended), or cron on the
  Zima itself.

## 1. Get the scripts

```sh setup-check
git clone -q https://github.com/casareanderson/zimablade-gpu-immich
cd zimablade-gpu-immich
```

## 2. Run the diagnostic

As a normal user, sections 04, 05, 07, 08 and 09 are accurate and the others say they need root. It changes nothing:

```sh setup-check
bash diagnostics/zima-gpu-check.sh | tee /tmp/gpu-check.txt
grep -q "== 09" /tmp/gpu-check.txt
```

On a machine without the ZimaBlade's slot, section 01 says `Root port 00:13.0 not found — is this a ZimaBlade?`.
If your board's slot sits elsewhere, set `ROOT_PORT=xx:xx.x`.

**All nine sections, on ZimaOS.** Copy the script to the host's `/tmp` and run it with the host's own tools through a
privileged container. That container is root on the machine, so read the script first:

```
cp diagnostics/zima-gpu-check.sh /tmp/
docker run --rm --privileged --pid=host -v /:/host alpine \
  chroot /host /bin/bash /tmp/zima-gpu-check.sh
```

On a normal Linux box, `sudo bash diagnostics/zima-gpu-check.sh` does the same.

Read section 04 first: `width 0` is a physical fault no driver can fix, `width 1` is normal on a VER009S riser, and
2.5 GT/s on a 5 GT/s link means the link stepped down. Section 08 shows whether it worked and then died (Xid 79).

## 3. Watch it

A dead GPU doesn't break Immich: it falls back to the CPU and carries on, slowly. Mine went unnoticed for six days.
The watcher is the alarm for that.

### Check it on any machine first

This runs the watcher's logic with a stand-in `nvidia-smi` that you switch between "alive" and "dead", so you can see
exactly what it logs and when it alerts:

```sh setup-check
mkdir -p /tmp/gpu-watch-try && cd /tmp/gpu-watch-try
printf '#!/bin/sh\necho "Quadro P600, 41, 1"\n' > alive
printf '#!/bin/sh\necho "Unable to determine the device handle for GPU0: Unknown Error"\nexit 255\n' > dead
chmod +x alive dead
export LOCAL=1 GPU_MATCH=P600 STATE_DIR=/tmp/gpu-watch-try/state
W="$OLDPWD/diagnostics/zima-gpu-watch.sh"
NVIDIA_SMI=./alive bash "$W"                      # first run: records "alive", no alert
NVIDIA_SMI=./alive bash "$W" | tee run2.txt       # still alive: logs a line, no alert
! grep -q ALERT run2.txt
NVIDIA_SMI=./dead bash "$W" | tee run3.txt        # fell off: ONE alert
grep -q "ALERT: GPU fell off the bus" run3.txt
NVIDIA_SMI=./dead bash "$W" | tee run4.txt        # still dead: no repeat
! grep -q ALERT run4.txt
NVIDIA_SMI=./alive bash "$W" | tee run5.txt       # back: ONE alert
grep -q "ALERT: GPU is back" run5.txt
cat state/zima-gpu-watch.log
cd "$OLDPWD"
unset LOCAL GPU_MATCH STATE_DIR
```

Every run logs a line with the state and the machine's uptime, so the log shows how many hours each boot's GPU lasted.

### Point it at your Zima

From another always-on machine with SSH key access to the Zima (`ssh-copy-id you@zima` once):

```
ZIMA=you@zima GPU_MATCH=P600 bash diagnostics/zima-gpu-watch.sh
```

On a healthy card you'll see `alive uptime=...h Quadro P600, 41, 1` (name, temperature, link width). After Xid 79 it
reads `dead ... Unable to determine the device handle for GPU0: ... Unknown Error`.

Then a cron line, every 15 minutes, with alerts to a Discord (or compatible) webhook:

```cron
*/15 * * * *  ZIMA=you@zima GPU_MATCH=P600 WEBHOOK=https://discord.com/api/webhooks/... bash /path/to/zima-gpu-watch.sh >> /dev/null 2>&1
```

Running it from another machine is better than cron on the Zima: ZimaOS doesn't run `cron`, and the watcher keeps
working while the Zima reboots.

**Unreachable isn't dead.** If SSH can't reach the Zima, the watcher logs `unreachable - not judging the GPU` and
leaves the state alone. A reboot or a network blip never counts as the GPU falling off.

| setting | default | what it does |
|---|---|---|
| `ZIMA` | required, unless `LOCAL=1` | `user@host` to SSH to |
| `LOCAL` | `0` | `1` checks this machine instead |
| `GPU_MATCH` | any GPU | text that must be in the GPU's name to count as alive |
| `WEBHOOK` | unset | URL that accepts `{"content": "..."}`; alerts always go to stdout too |
| `STATE_DIR` | `~/.local/state` | where `zima-gpu-watch.log` and `zima-gpu-watch.state` live |
| `NVIDIA_SMI` | `nvidia-smi` | the command to run |
| `SSH_TIMEOUT` | `15` | seconds before SSH counts as unreachable |

## 4. Put Immich ML on the GPU

Not tested in CI: this needs a GPU and your Immich stack.

Merge [`immich/docker-compose.gpu.yml`](../immich/docker-compose.gpu.yml) into your Immich compose file: the `-cuda`
image tag, `DEVICE=cuda`, and a per-container device request. Recreate the container, then check it took:

```
docker inspect immich-machine-learning --format '{{.Config.Image}}'
#   must end in -cuda
docker inspect immich-machine-learning --format '{{.HostConfig.DeviceRequests}}'
#   [{nvidia 1 [] [[gpu]]}]
```

**Pascal and Maxwell cards** (GTX 9xx, GTX 10xx, Quadro P-series) can't run Immich v3's `-cuda` ML image: it crashes
with exit code 132 and restarts forever. Either pin `ghcr.io/immich-app/immich-machine-learning:v2.4.1-cuda` or leave
ML on the CPU and use the card for NVENC transcoding only. The README's section 05 has the detail.

## Common problems

| you see | what it means | what to do |
|---|---|---|
| `Running unprivileged — sections 01, 02, 03 and 06 need root` | expected as a normal user | run as root (privileged container on ZimaOS) |
| `Root port 00:13.0 not found — is this a ZimaBlade?` | not a ZimaBlade, or a different slot | `ROOT_PORT=xx:xx.x` |
| all windows read `00000000-00000000` | `/proc/iomem` hides addresses from non-root readers | run as root; it's not a hardware fault |
| section 04 `width 0` | the link never trained | cable, x16 board, card, power, grounds; see README section 03 |
| `nvidia-smi` says `Unable to determine the device handle` | the card has dropped off the bus (Xid 79) | reboot to recover; fix the riser or grounding to stop it recurring |
| watcher says `set ZIMA=user@host (or LOCAL=1 ...)` and exits 2 | no target set | set `ZIMA` or `LOCAL=1` |
| watcher logs `unreachable` every time | SSH from this machine to the Zima fails | check `ssh -o BatchMode=yes you@zima true` works without a password |
| watcher logs `webhook post failed` | the webhook URL rejected the post | check the URL; the alert still went to stdout and the log |
| Immich ML keeps restarting with exit code 132 | a pre-Turing card on the v3 `-cuda` image | pin `v2.4.1-cuda` or use the CPU image |

## Update and uninstall

```
cd zimablade-gpu-immich && git pull     # update
```

To remove the watcher, delete its cron line and `~/.local/state/zima-gpu-watch.*`. Neither script installs or
changes anything on the machine it checks.
