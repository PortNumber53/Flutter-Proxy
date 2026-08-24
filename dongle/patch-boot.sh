#!/usr/bin/env bash
#
# Wire the boot hook into aawgd.conf on the FAT boot partition.
#
# /etc/aawgd.conf on the device is a symlink to /boot/aawgd.conf, and
# /etc/init.d/rcS sources it as root (via rcS_aawgd_conf, under `set -o
# allexport`) before any S??* init script runs. That makes this file the only
# place a Mac can inject boot-time behaviour: / and /boot are mounted read-only
# on the device and macOS cannot write ext4 at all.
#
# Idempotent: re-running replaces the managed block.
#
set -euo pipefail

VOL="${WIRELESSAA_VOL:-/Volumes/WirelessAA}"
CONF="$VOL/aawgd.conf"
HERE="$(cd "$(dirname "$0")" && pwd)"
BEGIN="######## BEGIN proxy-pac (managed by dongle/patch-boot.sh) ########"
END="######## END proxy-pac ########"

[[ -f "$CONF" ]] || { echo "$CONF not found -- is the SD card's boot partition mounted?" >&2; exit 1; }

cp -p "$CONF" "$HERE/aawgd.conf.bak.$(date +%Y%m%d-%H%M%S)"

# Drop any previous managed block, then append the current one.
tmp="$(mktemp)"
awk -v b="$BEGIN" -v e="$END" '
	$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
' "$CONF" > "$tmp"

cat >> "$tmp" <<HOOK
$BEGIN
## Proxy auto-configuration for clients on the dongle's Wi-Fi.
##
## The dongle runs tinyproxy on 10.0.0.1:8080 and forwards everything upstream
## to the proxy in the Flutter app on the phone. Clients discover it through a
## PAC file served at http://10.0.0.1/wpad.dat, advertised over DHCP option 252
## and DNS (wpad.lan).
##
## The heavy lifting lives on /persist (the only writable filesystem); this
## block is inert until dongle/install.sh has put it there.

AAWG_EXTRA_PROXY_ENABLE=1

## Where the dongle's own proxy listens.
AAWG_EXTRA_PROXY_LISTEN_IP=10.0.0.1
AAWG_EXTRA_PROXY_PORT=8080

## The phone running the Flutter proxy app. This must match the address the
## phone actually gets from DHCP -- pin it with AAWG_EXTRA_PHONE_MAC below,
## otherwise the lease can land anywhere in 10.0.0.2-10.0.0.20 and the upstream
## silently points at nothing.
AAWG_EXTRA_UPSTREAM_IP=10.0.0.2
AAWG_EXTRA_UPSTREAM_PORT=8080

## Port the PAC file is served on.
AAWG_EXTRA_PAC_PORT=80

## Which proxy the PAC hands out to clients.
##   phone  - straight to the phone (AAWG_EXTRA_UPSTREAM_IP). The phone then sees
##            each client's real IP, so its per-device metrics are meaningful.
##   dongle - via tinyproxy on the dongle. One extra hop, and the phone sees only
##            10.0.0.1, so every client collapses into a single row.
## tinyproxy keeps running either way, so anything pointed at 10.0.0.1 still works.
AAWG_EXTRA_PAC_TARGET=phone

## Phone's Wi-Fi MAC, to pin its DHCP lease to AAWG_EXTRA_UPSTREAM_IP.
## NOTE: Android randomises its MAC per SSID by default. Either turn that off
## for this network (Wi-Fi > AAWirelessDongle > Privacy > Use device MAC) or
## read the randomised one -- it is stable per-SSID -- and paste it here.
#AAWG_EXTRA_PHONE_MAC=aa:bb:cc:dd:ee:ff

## Seconds to wait for wlan0 to come up before giving up.
AAWG_EXTRA_PROXY_WAIT=60

## Graceful shutdown endpoint for the phone app: POST /shutdown on this port.
## Set a token to require it (X-Auth-Token header or ?token=); leave unset and
## any client on the AP can power the dongle off. The AP is WPA2 and the only
## clients are yours, so unset is a reasonable default -- set it if you carry
## passengers you would rather not hand a power switch to.
AAWG_EXTRA_SHUTDOWN_PORT=8081
#AAWG_EXTRA_SHUTDOWN_TOKEN=

if [ "\$AAWG_EXTRA_PROXY_ENABLE" = "1" ] && [ -x /persist/proxy/bootstrap.sh ]; then
	# Synchronous, and must stay fast: this runs inside rcS, before dnsmasq.
	/persist/proxy/bootstrap.sh early
	# Detached: waits for the AP, then starts tinyproxy and the PAC server.
	( /persist/proxy/bootstrap.sh late & ) </dev/null >/dev/null 2>&1
fi
$END
HOOK

sh -n "$tmp" || { echo "generated aawgd.conf failed a syntax check -- not installing" >&2; rm -f "$tmp"; exit 1; }
cat "$tmp" > "$CONF"
rm -f "$tmp"

# macOS sprinkles AppleDouble/Spotlight droppings on FAT volumes. Harmless
# (the device mounts /boot read-only) but there is no reason to leave them.
rm -f "$VOL"/._* 2>/dev/null || true
rm -rf "$VOL"/.Spotlight-V100 "$VOL"/.Trashes 2>/dev/null || true

echo "==> patched $CONF"
echo "    backup: $HERE/aawgd.conf.bak.*"
echo
echo "Remember to eject cleanly:  diskutil unmount \"$VOL\""
