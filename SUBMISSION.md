# ZimaSpace "Share a Server Tutorial" — submission notes

**Campaign:** https://shop.zimaspace.com/pages/share-a-server-tutorial-with-zimaspace
**Window:** 4–30 August 2026 · **Winners announced:** 4 September 2026
**Prizes:** ZimaBoard 2 832 (grand) · ZimaBlade 7700 Dual Bay NAS Kit (second) · $50 gift cards · ZimaOS+

**How to submit:** there is no email address. The "Share a Tutorial" button is an anchor to the
`#giveaway` section further down the same page, which renders an inline form. It asks for your
email, the tutorial link, and a few words on why you recommend it. One tutorial per participant.

**Link submitted:** https://github.com/casareanderson/zimablade-gpu-immich

---

## Why I recommend it (long form)

I wrote this after fitting a Quadro P600 to my own ZimaBlade to speed up Immich's face
recognition. Every guide I could find explained how it should work; none told me what the slot
can actually carry — so I measured it. PCIe 2.0 x4, 25 W, no hot-plug, and crucially no
Above-4G decoding, which is the constraint that quietly rules out most modern cards and which
nobody publishes.

It also documents a trap I nearly fell into: the popular RTX 50-series ZimaOS tutorial tells you
to install `nvidia-open-kernel`, but that module only supports Turing and newer — on a Pascal or
Maxwell card it replaces a working driver with one that cannot see your hardware. ZimaOS already
ships the proprietary driver and the container toolkit, so most people need to install nothing
at all.

And it is honest about the ending: my card runs for eight and a half hours, then falls off the
bus with Xid 79. Beginners are rarely shown how to *read* a failure, so the guide walks through
the presence-detect and link-width checks that separate a physical fault from a software one,
plus a script that runs every check in one pass. I think a beginner learns more from a
documented dead end than from a tutorial where everything works first time.

## Why I recommend it (short form)

An original field report from my own homelab: what the ZimaBlade's PCIe slot can really carry
(x4, 25 W, no Above-4G — the spec nobody publishes), why the popular RTX 50-series ZimaOS
tutorial breaks pre-Turing cards, and how to diagnose a GPU that works for eight hours then
falls off the bus. Includes a read-only script that runs every check. Beginner-focused, and
honest about the parts that failed.

---

## Notes to self

- Entry is **original**, which the rules say gets priority for hardware prizes.
- The guide's ending is a documented failure rather than a success. Kept deliberately: a working
  Immich write-up competes with dozens of entries; an Xid 79 diagnosis competes with none.
- Hardware prize winners are invited to collaborate with the ZimaSpace team on a blog post.
