# Which build runs

Upstream says only `arm`, `aarch64` and `mipsel` builds exist, and that x86_64 "cannot be used". That's true of the endpoints upstream asks about. Those are the **vendor-specific** ones, named after OEM routers:

```
https://router.uu.163.com/api/plugin?type=h3c-bx54      → ARM 32-bit
https://router.uu.163.com/api/plugin?type=h3c-nx30pro   → aarch64
https://router.uu.163.com/api/plugin?type=jd-hr06       → MIPS little endian
```

But NetEase's own [OpenWrt install guide](https://router.uu.163.com/app/html/online/baike_share.html?baike_id=5f963c9304c215e129ca40e8) installs a generic script that passes `$(uname -m)` straight through, and that lands on a **second family** nobody mentions:

```
https://router.uu.163.com/api/plugin?type=openwrt-x86_64    → x86-64   ✅
https://router.uu.163.com/api/plugin?type=openwrt-aarch64   → aarch64
https://router.uu.163.com/api/plugin?type=openwrt-arm       → ARM 32-bit
https://router.uu.163.com/api/plugin?type=openwrt-mipsel    → MIPS LE
https://router.uu.163.com/api/plugin?type=openwrt-mipseb    → MIPS BE
```

To be sure, I read `e_machine` out of each downloaded ELF. `openwrt-x86_64` really is an x86-64 binary, currently **v14.9.4**. That family is the whole reason native x86_64 and big-endian MIPS work here.

There's a catch, confirmed on a live router: **the generic builds only boost game consoles.** PC and phone boosting lives solely in the vendor builds, which report themselves as `hw: h3c` instead of `hw: openwrt`. Run the generic x86_64 build and the app offers no PC. Switch to a vendor build and it shows up.

So **What to boost** is really choosing a family, not an architecture:

| Setting | Build | Boosts |
|---|---|---|
| Game consoles only | `openwrt-<arch>`, native | consoles |
| Game consoles, PCs and phones | vendor (`h3c-*`) | consoles, PCs, phones |

Vendor builds are published per model, not per architecture, so there's no way to know up front what you'll get. The plugin reads the ELF header of whatever arrives and decides from that:

| Your router | What happens |
|---|---|
| Same architecture as the build (ARM routers) | It just runs. No emulator, no sysroot. |
| x86_64 | It runs under qemu user-mode emulation. |
| Anything else | Refused, and the message names both architectures. |

None of this is tied to a specific model, so a vendor build that isn't in the dropdown would still be classified correctly if you added it. And because the console-only path uses the generic family, it needs none of upstream's OEM identity spoofing (the fake `h3c_info` file, the `haiapi` shim for JD routers).

## Emulating a vendor build on x86_64

The x86_64 package carries everything needed:

| Piece | Why |
|---|---|
| `qemu-aarch64-static` (10 MB, static-pie) | OpenWrt's feeds only have `qemu-*-softmmu`, which emulates a whole machine rather than one binary |
| aarch64 musl sysroot (2.6 MB) | The vendor binary is dynamically linked, unlike the static generic build |

Only the plugin binary itself is downloaded at runtime, since it's versioned and gets updates. The generic build already works that way.

Three things made this awkward. The plugin handles all of them:

- **The sysroot has to match an old ABI.** The vendor binary wants the pre-C++11 COW `std::string` ABI (`_ZNSs…`). Alpine's musl libstdc++ only exports the new one, so the sysroot comes from OpenWrt's own aarch64 packages instead. Their libstdc++ still carries both.
- **There's no `binfmt_misc`.** `uuplugin` execs its watchdog, and with nothing around to re-invoke qemu for a foreign binary, that exec just fails. The watchdog gets replaced by a native `/bin/sh` shim that calls qemu itself. If the same router later runs a build natively, the real watchdog comes back.
- **procd's `LD_PRELOAD` leaks into the guest.** procd sets `LD_PRELOAD=/lib/libsetlbf.so` for line-buffered logging. The emulated aarch64 loader inherits it and dies with *unsupported relocation type*, so both the service command and the shim clear it first.

Idle CPU cost is nothing to speak of. Under load there's real emulation overhead, but it only touches UU's userspace processing. The tunnel data path is still kernel TUN.

To set it up by hand, or to re-fetch after a failed download:

```bash
/etc/init.d/uuplugin prepare_oem
```

[← back to the README](../README.md)
