# Dongle-side proxy + PAC

Adds an HTTP proxy with WPAD/PAC auto-configuration to a
[WirelessAndroidAutoDongle](https://github.com/nisargjhaveri/WirelessAndroidAutoDongle)
Pi Zero 2 W, using the proxy in this repo's Flutter app (on the phone) as the
upstream.

```
  passenger device ──Wi-Fi──┐
                            │  AAWirelessDongle  (10.0.0.0/24, no default route)
  phone ────────────────────┤
    │                       │
    │                  ┌────┴─────────────────────┐
    │                  │ Pi Zero 2 W  10.0.0.1    │
    │                  │  • hostapd + dnsmasq     │
    │                  │  • PAC @ :80/wpad.dat    │
    │  cellular        │  • tinyproxy :8080 ──────┼──┐
    ▼                  │  • aawgd :5288 ──USB/AOA─┼──┼──► car head unit
  internet ◄── Flutter proxy :8080 ◄──────────────┼──┘
                       └──────────────────────────┘
```

A client joins the dongle's Wi-Fi, picks up the PAC URL from DHCP option 252,
and proxies through `10.0.0.1:8080`. tinyproxy forwards everything except the
local subnet to the phone, which is the only device on the network with a route
to the internet.

## Why it is built this way

The SD card has three partitions and macOS can only mount the first:

| Partition | FS | Label | Mount on device | Writable from macOS |
|---|---|---|---|---|
| `p1` | FAT32 | `WirelessAA` | `/boot`, **ro** | ✅ |
| `p2` | ext4 | `rootfs` | `/`, **ro** | ❌ |
| `p3` | ext4 | `persist` | `/persist`, rw | ❌ |

So the work is split in two:

- **`patch-boot.sh`** writes the FAT partition. `/etc/aawgd.conf` on the device
  is a symlink to `/boot/aawgd.conf`, and `/etc/init.d/rcS` sources it as root
  (via `rcS_aawgd_conf`, under `set -o allexport`) before any `S??*` init script
  runs. That makes it the one place a Mac can inject boot-time behaviour.
- **`install.sh`** pushes everything else to `/persist` over SSH, because
  `/persist` is the only writable filesystem and macOS cannot write ext4.

The stock image ships no proxy daemon and no `iptables`, hence the
cross-compiled static tinyproxy. `/etc/dnsmasq.conf` has no `conf-dir=` line, so
the WPAD options cannot be added as a drop-in; `bootstrap.sh` bind-mounts a
generated config over it instead, before dnsmasq's first start.

## Install

```sh
./build/build.sh    # static armv7 tinyproxy + pacd, via Docker
./install.sh        # push to /persist  (join AAWirelessDongle first)
./patch-boot.sh     # wire the boot hook (SD card in the Mac)
```

Then set `AAWG_EXTRA_PHONE_MAC` in `/Volumes/WirelessAA/aawgd.conf` so the
phone's DHCP lease is pinned to the address tinyproxy forwards to.

Test without rebooting:

```sh
ssh root@10.0.0.1 '/persist/proxy/bootstrap.sh late'
curl -x 10.0.0.1:8080 http://example.com
curl http://10.0.0.1/wpad.dat
```

Logs: `/persist/proxy/bootstrap.log`, `/persist/proxy/tinyproxy.log`.

## Safety

`dnsmasq` is the AP's DHCP server. If it does not come up, the phone cannot
associate and Android Auto does not work at all — a bad thing to discover in a
car. `bootstrap.sh` therefore watchdogs it: if dnsmasq is not running 30 s after
boot, the bind-mount is reverted and dnsmasq is restarted on the stock config.
The boot hook is also inert unless `/persist/proxy/bootstrap.sh` exists and is
executable, so patching the SD card alone can never break a boot.

To back out completely: delete the `BEGIN/END proxy-pac` block from
`/Volumes/WirelessAA/aawgd.conf` (or restore `aawgd.conf.orig.bak`).

## Known limitations

**Android ignores DHCP option 252.** It has never implemented WPAD, so Android
clients do not pick up the proxy automatically even though the dongle advertises
it. Set it once per SSID — tested working on a Galaxy Tab S8 (Android 16):

*Settings > Connections > Wi-Fi > gear next to AAWirelessDongle > View more >
Proxy > **Auto-config** > PAC web address:* `http://10.0.0.1/wpad.dat`

Prefer Auto-config over Manual: the PAC already carries the local-subnet DIRECT
rules, so the dongle and the PAC file itself are never fetched through the proxy.
Do **not** use `settings put global http_proxy` — that applies to every network,
so the device breaks when it leaves the dongle. The per-SSID setting is scoped to
this network only.

Windows, macOS, iOS and desktop Linux need none of this; they honour option 252
and the `wpad` DNS name.

**The car head unit cannot use this.** It is attached over USB in AOA gadget
mode, which carries the Android Auto accessory protocol and no IP stack. It gets
no DHCP lease and cannot be given a proxy. Only Wi-Fi clients of the dongle can.

**The Flutter app egresses over cellular by itself — no platform channel needed.**
An earlier draft of this file claimed the opposite. Verified on device instead:
with the phone associated to `AAWirelessDongle` and the app's HTTP proxy running,
a request through the full chain came back with the phone's *mobile* address
(`172.58.x`, T-Mobile), not the broadband address the same request takes without
the proxy. HTTPS `CONNECT` works too.

The reason is Android's network validation. Every network is probed for real
internet reachability; the dongle AP fails that probe, so Android never promotes
it to the default network. Unbound app sockets — which is what `Socket.connect()`
in `lib/proxy_server.dart` creates — therefore keep using cellular. The listening
sockets still accept on Wi-Fi because they are bound to `anyIPv4`.

Two caveats follow from *relying* on validation rather than binding explicitly:

- If Android ever decides the AP does have internet (it does not here — the
  generated dnsmasq config advertises no default gateway via `dhcp-option=3`),
  upstream sockets would follow Wi-Fi into a loop back at the dongle.
- "Switch to mobile data automatically" / private DNS settings can change which
  network is default.

Binding upstream sockets explicitly with `ConnectivityManager.requestNetwork
(TRANSPORT_CELLULAR)` + `Network.bindSocket(fd)` (per-socket — *not*
`bindProcessToNetwork`, which would rebind the listener too) would make this
robust rather than incidental. It is not required for it to work today.

## Verified on device

Raspberry Pi Zero 2 W, phone SM-S908U / Android 16, second client a Pi 3B.

| Check | Result |
|---|---|
| Static armv7 `tinyproxy` on uClibc rootfs | `tinyproxy 1.11.2` |
| `busybox httpd` applet | **absent** — bundled `pacd` used |
| Boot hook fires from `/boot/aawgd.conf` | bind-mount + both daemons by 5s |
| DHCP option 252 received by client | `wpad = http://10.0.0.1:80/wpad.dat` |
| WPAD via DNS | `wpad`, `wpad.lan` → `10.0.0.1` |
| PAC MIME type | `application/x-ns-proxy-autoconfig` |
| Local-subnet exception | `No upstream proxy for 10.0.0.1` → direct |
| Full chain HTTP / HTTPS | `200` / `200`, egress = cellular |
| Second client (Tab S8) via PAC | Chrome renders pages; egress = cellular |
| Sustained browsing, 2 clients | peak 19 connections, 0 refusals |
| `shutdownd` GET /ping | `200 {"status":"ok"}` |
| `shutdownd` GET /shutdown | `405` — dongle stays up |
| `shutdownd` POST with wrong/short/long token | `403` in all cases |
| App button end-to-end (token armed) | app POST reached daemon, refused, dongle up |
| PAC target `phone`, 2 clients | app shows real IPs (`10.0.0.10`, `10.0.0.8`) |
| No default route leaked to clients | confirmed |

Device quirks found the hard way, all worked around in the scripts:

- The dongle's busybox `tar` has **no** `-z`; decompression is a separate
  `gunzip -c` stage. Alpine's busybox does accept `-z`, so this only appears on
  the real device.
- Dropbear regenerates its host key on every boot (read-only rootfs, nowhere to
  persist one), so SSH host-key pinning against the dongle is meaningless and
  produces a spurious MITM warning after each reboot.
- `MaxClients 60` with `Timeout 600` (my first draft) is badly wrong for real
  clients. Browsers park many idle CONNECT tunnels and each one holds a slot, so
  a *single* tablet saturated the pool and tinyproxy began refusing connections;
  a trivial fetch went from 0.3s to 4.2s. Now `MaxClients 256` / `Timeout 120`,
  which held at 19 concurrent connections under two-device browsing.
- `pacd` originally replied and closed without draining the request, which sends
  an RST; `curl` fit its headers in one segment and never noticed, but tinyproxy
  forwards a larger header block and failed every time. It now drains the request
  head, half-closes, and drains again, and forks per connection.

## Which proxy the PAC hands out

`AAWG_EXTRA_PAC_TARGET` in `/boot/aawgd.conf`:

- `phone` (default) — clients are sent straight to `AAWG_EXTRA_UPSTREAM_IP:8080`.
  The phone then sees each client's real source IP, so the app's per-device
  metrics are meaningful.
- `dongle` — clients go through tinyproxy. One extra hop, and because tinyproxy
  terminates every client connection the phone only ever sees `10.0.0.1`; all
  devices collapse into a single row in the app.

tinyproxy keeps running either way, so anything pointed at `10.0.0.1:8080`
manually still works.

## Graceful shutdown

Pulling car power cuts the SD card mid-write. `shutdownd` gives the phone app a way
to ask for a clean poweroff first. It listens on `10.0.0.1:8081`:

| Request | Result |
|---|---|
| `GET /ping` | `200` liveness check, never destructive |
| `POST /shutdown` | `200`, then `sync()` + `poweroff` |
| `GET /shutdown` | `405` |

Shutdown is **POST-only on purpose**: a GET would let a link prefetch, a captive-portal
probe, or a mistyped URL power off the car's head-unit link.

A token is optional. Set `AAWG_EXTRA_SHUTDOWN_TOKEN` in `/boot/aawgd.conf` and the same
value in `DongleControl(token: ...)`; leave it unset and any client on the AP can trigger
a shutdown. Unset is a reasonable default — the AP is WPA2 and the clients are yours —
but set it if you carry passengers. The comparison is constant-time and rejects both
prefixes and suffixes of the real token.

The app side is `lib/dongle_control.dart` plus a confirm-dialog button in `lib/main.dart`.

**The button does not work from the phone.** It works from Wi-Fi-only clients
(verified on a Galaxy Tab S8), but on a phone with cellular the request never
leaves: `ip route get 10.0.0.1` resolves via `rmnet`, and Android's rules key off
the output interface, so source-address binding does not help either. Binding to
the Wi-Fi network is the only route, and `requestNetwork` refuses it -- the dongle
AP advertises no `NET_CAPABILITY_INTERNET` and its agent specifier is local-only,
so a generic request is never satisfied and `Network.bindSocket` fails `EPERM`.
Adding `CHANGE_NETWORK_STATE` and dropping the INTERNET requirement did not help.

The fix is to reverse the direction: dongle -> phone works (that is how the proxy
has run all along), so the dongle should poll the phone for a pending shutdown
command. Not built yet.

## Files

| Path | Runs on | Purpose |
|---|---|---|
| `patch-boot.sh` | Mac | Append the managed hook block to `/boot/aawgd.conf` |
| `install.sh` | Mac | `tar`-over-SSH the bundle to `/persist/proxy` |
| `build/build.sh` | Mac | Docker `linux/arm/v7` static build |
| `build/pacd.c` | — | ~130-line PAC file server, fallback if busybox lacks `httpd` |
| `build/shutdownd.c` | — | Graceful-poweroff HTTP endpoint on `:8081` |
| `build/mk-installer.sh` | Mac | Generate the self-extracting `dongle-proxy-installer.sh` |
| `dongle-proxy-installer.sh` | any | Self-extracting bundle; pushes over SSH or installs locally |
| `persist-proxy/bootstrap.sh` | Pi | Boot orchestration, dnsmasq watchdog |
| `persist-proxy/tinyproxy.conf.in` | Pi | Proxy config template |
| `persist-proxy/www/wpad.dat.in` | Pi | PAC template |
| `persist-proxy/www/httpd.conf` | Pi | MIME map (`application/x-ns-proxy-autoconfig`) |
