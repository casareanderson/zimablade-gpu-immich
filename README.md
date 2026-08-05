# Putting a GPU in a ZimaBlade

**The slot's real limits, the driver trap that bricks older cards, and how to read the failure when the card works for eight hours and then vanishes.**

A field report from a working homelab. Every number below was read off the machine, not a spec sheet — including the ones that killed the build.

---

## Where this ends up

The card enumerates. The driver binds. Immich picks it up. Then, eight and a half hours after boot, the GPU falls off the PCIe bus and stays gone until the next reboot.

This guide is the map of everything I verified on the way to that answer — most of which you want **before** you buy a card, not after.

**Hardware:** ZimaBlade 7700 (board ZBB001-BK10032) · NVIDIA Quadro P600 2 GB (GP107GL, Pascal) · VER009S powered riser · ZimaOS with NVIDIA 580.105.08 · Immich machine-learning v3.0.1-cuda

---

## 01 · Read the slot before you spend money

The ZimaBlade has a PCIe slot, which is most of why people buy it. What the marketing doesn't tell you is what that slot can actually carry. Four values decide whether your card has any chance, and all four are readable from a running board in about ten seconds.

```console
$ lspci -vvv -s 00:13.0 | grep -E "LnkCap|SltCap"
LnkCap: Port #3, Speed 5GT/s, Width x4, ASPM not supported
SltCap: AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug- Surprise-
        Slot #2, PowerLimit 25W; Interlock- NoCompl+
```

| Reading | Means | Consequence |
|---|---|---|
| `Speed 5GT/s, Width x4` | PCIe 2.0, four lanes | ~2 GB/s ceiling. Fine for compute and transcode, poor for gaming. |
| `PowerLimit 25W` | Slot power budget | A 40 W card **cannot** run slot-powered. You need external 12 V. |
| `HotPlug-` | No hot-plug | Enumeration happens at cold boot only. `/sys/bus/pci/rescan` will not save you. |
| All windows < 4 GB | No Above-4G decoding | The real blocker for big-VRAM cards. See below. |

### The Above-4G problem

This is the one that quietly rules out the card you probably wanted. A GPU asks the host for a memory aperture roughly the size of its VRAM. Without Above-4G decoding, every PCI window has to live below the 4 GB line — and on this board the largest is about 1.25 GB:

```console
$ grep "PCI Bus" /proc/iomem
80000000-cfffffff : PCI Bus 0000:00     # ≈ 1.25 GB — the largest window
  91000000-920fffff : PCI Bus 0000:01
```

A 2 GB Quadro P600 needs only a ~256 MB aperture and fits comfortably. A modern 12 GB or 16 GB card typically wants an aperture to match, and there is nowhere to put it. **Check your card's BAR sizes before buying, not after.**

---

## 02 · The driver trap

ZimaOS is an immutable, appliance-style OS, so the reasonable assumption is that you'll have to fight it to get NVIDIA drivers on. That assumption is wrong, and acting on it is how people break working setups.

### ZimaOS already ships the proprietary driver

Not a stub, not a userspace shim — the full proprietary kernel module, plus the container toolkit for Docker GPU passthrough. It is baked into the base image, not delivered as a system extension:

```console
$ which nvidia-smi nvidia-ctk nvidia-container-runtime
/usr/bin/nvidia-smi
/usr/bin/nvidia-ctk
/usr/bin/nvidia-container-runtime

$ dmesg | grep NVRM
NVRM: loading NVIDIA UNIX x86_64 Kernel Module  580.105.08

$ ls /var/lib/extensions/        # note: nvidia is NOT here — it's in the base image
icewhale_files.raw  icewhale_peerdrop.raw  manticore.raw  zimaos_zvm.raw
```

> ### ⚠️ Do not install `nvidia-open-kernel` on an older card
>
> The widely-shared ZimaOS tutorial for getting RTX 50-series cards working tells you to drop `nvidia-open-kernel` into `/var/lib/extensions/` and run `install-nvidia-kernel-open`. That advice is **correct only for Blackwell**, where NVIDIA dropped proprietary support and open is the sole option.
>
> The open module supports **Turing and newer only**. On anything older — Pascal, Maxwell, Volta — it will not bind to your card, and you will have replaced a working driver with one that cannot see your hardware. A GTX 1660 owner hit exactly this and had to run `uninstall-nvidia-kernel-open` to recover.
>
> If your card is pre-Turing, the shipped proprietary driver is strictly better. **Leave it alone.**

One useful detail on longevity: driver branch **580 is the last one to support Maxwell, Pascal and Volta**. A future ZimaOS bump to 590+ would drop those cards. There is no kernel build tree on the box, so you cannot compile your way out — you get what ships.

> **Driver ≠ detection.** `lspci` enumeration happens with no driver loaded at all; a driver only binds to a device that is *already* on the bus. If your card isn't in `lspci`, no amount of driver installing will conjure it up. Don't chase driver fixes while the link width reads `0` — that's a physical fault, and you'll waste a weekend.

---

## 03 · Power, and one genuine fire hazard

The stock ZimaBlade supply is **12 V at 3 A — 36 W total**. The board, RAM and two SATA drives already draw roughly 25–30 W of that. There is no version of the arithmetic where it also feeds a 40 W graphics card. An external supply is mandatory, not optional.

Most people reach for a powered mining riser, which is the right instinct. Two warnings come with it:

- **A VER009S riser is electrically x1**, despite having a full x16 connector on top. The USB 3 cable is just the physical medium — no USB protocol is involved. Your ceiling becomes PCIe 2.0 x1, about 500 MB/s. Tolerable for CUDA and transcoding; useless for a gaming card.
- **Throw away the bundled SATA-to-6-pin adapter.** A SATA power connector is rated for around 54 W; a 6-pin PCIe connector is rated for 75 W and cards will happily try to draw it. These adapters are a well-documented fire risk. Use a proper Molex or native PCIe lead from the PSU instead.

> ### Two power supplies means two ground domains
>
> If the ZimaBlade runs from its own two-pin (unearthed, floating) brick while the GPU runs from an earthed ATX supply, the only thing bonding those grounds is the thin ground wires in a USB 3 cable. PCIe uses differential signalling with a narrow common-mode range — a floating offset between the two domains produces exactly the signature you'd least expect: **power is obviously fine, and the data link never works.**
>
> The clean fix is to run the whole thing from one supply. The ZimaBlade is a 12 V device, so a barrel-jack pigtail off a Molex lead puts board and card in a single ground domain — and disposes of the 36 W ceiling at the same time.

---

## 04 · Diagnosing a slot that shows nothing

If the card doesn't appear, you need to know whether the problem is at the slot, the riser, the cable or the card. There is a neat trick for splitting that question in half, and it needs no root and no driver.

### Presence detect isolates the slot end

On every PCIe card, pins A1 (`PRSNT1#`) and B17 (`PRSNT2#`) are shorted together on the card's own PCB. The host grounds A1 and pulls B17 high; seating a card pulls B17 low, and the slot reports `PresDet+`. Crucially, that short is on the riser board itself — so it asserts presence **purely by being seated**, with no cable, no GPU and no external PSU attached.

So: plug the bare x1 riser board into the slot with nothing else connected, cold boot, and read it.

```console
$ lspci -vvv -s 00:13.0 | grep SltSta
SltSta: ... PresDet+ ...    # slot and riser board are making contact.
                            # Fault is downstream: cable, x16 board, card, power.
SltSta: ... PresDet- ...    # the riser isn't seated or is dead.
                            # Nothing downstream can matter yet.
```

> **Know what this does and doesn't prove.** `PresDet+` proves only that the small board is physically in the slot — the pins it shorts are two of the ZimaBlade's own, inside the ZimaBlade's own ground domain. It says *nothing* about the USB 3 cable, the x16 board or the GPU. It's a way to rule the slot **out**, not to rule the rest **in**.

### Then check whether the link trained

Presence is not a link. These two files, readable by any user, tell you whether lanes actually came up:

```console
$ cat /sys/bus/pci/devices/0000:00:13.0/current_link_width
0    # link never trained. Physical fault. Not fixable in software:
     # a rescan cannot train a width-0 link, and no driver will help.
1    # trained at x1. Expected on a VER009S riser.
```

---

## 05 · Wiring it into Immich

Once the card is up, Immich's machine-learning container is the reason most people are doing this — it's what runs face recognition and smart search. Getting it onto the GPU takes two things: the CUDA image variant, and a device request. This is a working configuration, read back off a live container:

```console
$ docker inspect immich-machine-learning
Image           ghcr.io/immich-app/immich-machine-learning:v3.0.1-cuda
DeviceRequests  [{nvidia 1 [] [[gpu]]}]
DEVICE=cuda
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=compute,utility
```

See [`immich/docker-compose.gpu.yml`](immich/docker-compose.gpu.yml) for the compose form.

Two things worth knowing. First, the plain image tag will silently run on CPU forever — you need the `-cuda` variant. Second, Docker's `default` runtime can stay `runc`; what matters is the per-container device request, so you don't need to make every container on the box GPU-aware.

> ### It fails safe, which is why you might not notice
>
> If the GPU disappears, Immich does not break. ONNX Runtime logs the failure and quietly carries on:
>
> ```
> CUDA failure 100: no CUDA-capable device is detected
> Falling back to ['CPUExecutionProvider'] and retrying.
> ```
>
> Face recognition and smart search keep working, just slowly. Good design — but it means a dead GPU can go unnoticed for days. Mine did: six.

---

## 06 · When it works, then doesn't: reading Xid 79

This is where my build currently sits, and it's the most useful part of the story, because "it worked and then stopped" is much harder to search for than "it never worked".

At boot, everything is clean. The card enumerates, the driver loads, DRM initialises:

```
[   19.9s] nvidia 0000:01:00.0: enabling device (0000 -> 0003)
[   21.3s] NVRM: loading NVIDIA UNIX x86_64 Kernel Module  580.105.08
[   21.3s] [drm] Initialized nvidia-drm 0.0.0 for 0000:01:00.0 on minor 1
```

Eight and a half hours later, without anyone touching it:

```
[30709s] NVRM: Xid (PCI:0000:01:00): 79, GPU has fallen off the bus.
[30709s] NVRM: GPU 0000:01:00.0: GPU has fallen off the bus.
[30709s] NVRM: Xid (PCI:0000:01:00): 154, GPU recovery action changed
                from 0x0 (None) to 0x1 (GPU Reset Required)
```

**Xid 79 means the host stopped being able to reach the GPU.** It is almost always power delivery or PCIe signal integrity — not a driver bug, and not something a reinstall fixes. After it fires, everything downstream looks broken in confusing ways: `nvidia-smi` reports *"Unable to determine the device handle for GPU0: Unknown Error"*, and the card's memory regions read `[disabled]`. Those are symptoms of the corpse, not clues about the cause.

### The evidence that points at the riser

Two readings turn this from a guess into a diagnosis:

```console
$ lspci -vvv -s 01:00.0
LnkCap: Speed 5GT/s, Width x16
LnkSta: Speed 2.5GT/s (downgraded), Width x1 (downgraded)
DevSta: CorrErr+ NonFatalErr+ FatalErr- UnsupReq+ AuxPwr+ TransPend-
```

A VER009S is expected to give x1. It is **not** expected to drop to 2.5 GT/s — that's PCIe 1.0 signalling, a further step down, and it's what a link does when it can't hold a clean eye at the higher rate. Combine that with correctable and non-fatal errors actually being counted, and the story is marginal signalling that works cold and gives up under sustained use.

### Fix order

1. **Swap the riser's USB 3 cable.** It is the single most common failure point in these kits, and errors at a downgraded speed point straight at it. Cheapest thing to change, so change it first.
2. **Get onto one ground domain.** Power the ZimaBlade itself from the ATX supply rather than its own floating brick.
3. **Reseat the card in the x16 board.** Ribbon and riser assemblies fake-seat convincingly.

And note the recovery requirement: Xid 154 says **GPU Reset Required**, so the card will not come back without a reboot — it will sit dead until you give it one. On a NAS running your SSO, reverse proxy and photo library, that reboot is not free. Plan it.

---

## 07 · What I'd tell you before you start

- **Check Above-4G decoding before choosing a card.** It's the constraint nobody mentions and the one most likely to rule out your shortlist.
- **You don't need to install a driver.** ZimaOS ships the proprietary module and the container toolkit. Installing the open kernel module on a pre-Turing card actively makes things worse.
- **Budget for power properly.** 36 W stock supply, 25 W slot limit. Anything interesting needs an external PSU, and two PSUs need their grounds bonded.
- **Read the link, not the fan.** A spinning fan proves 12 V reached the card and nothing whatsoever about the data lanes. Every diagnosis above starts at `current_link_width`.
- **Watch for the silent fallback.** Immich degrading to CPU is good engineering and a monitoring blind spot. Alert on it.

The honest bottom line: a low-profile, sub-25 W, small-VRAM card on a properly grounded single supply is a realistic ZimaBlade GPU. A riser hanging off a second PSU is a science project — a rewarding one, but budget the evenings.

---

## Run the checks yourself

[`diagnostics/zima-gpu-check.sh`](diagnostics/zima-gpu-check.sh) runs every read-only check in this guide in one pass — slot capabilities, Above-4G windows, presence detect, link training, driver state and Xid history. No root required, nothing is modified.

```console
$ ./diagnostics/zima-gpu-check.sh
```

---

*Every command output reproduced here was captured from the running machine. The build is not finished — it is documented at the point where the fault is understood but the cable has not yet been replaced.*
