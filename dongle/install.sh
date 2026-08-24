#!/usr/bin/env bash
#
# Push the proxy bundle to a running dongle over SSH.
#
# /persist is the only writable filesystem on the device and macOS cannot mount
# ext4, so the SD card in your Mac is not a delivery path for these files --
# only aawgd.conf on the FAT boot partition is (see patch-boot.sh).
#
# Connect this Mac to the dongle's Wi-Fi (SSID AAWirelessDongle) first.
#
set -euo pipefail

HOST="${DONGLE_HOST:-10.0.0.1}"
USER_="${DONGLE_USER:-root}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Dropbear speaks older algorithms than current OpenSSH enables by default.
SSH_OPTS=(
	-o HostKeyAlgorithms=+ssh-rsa
	-o PubkeyAcceptedAlgorithms=+ssh-rsa
	# The dongle regenerates its dropbear host key on every boot (read-only
	# rootfs, nowhere to persist one), so pinning it only produces a spurious
	# MITM failure after each reboot. The link is a WPA2 AP we control.
	-o UserKnownHostsFile=/dev/null
	-o StrictHostKeyChecking=no
	-o LogLevel=ERROR
	-o ConnectTimeout=10
)

if [[ ! -x "$HERE/persist-proxy/bin/tinyproxy" ]]; then
	echo "persist-proxy/bin/tinyproxy is missing -- run build/build.sh first." >&2
	exit 1
fi

echo "==> copying bundle to ${USER_}@${HOST}:/persist/proxy"
# tar over ssh rather than scp: Buildroot's dropbear does not reliably ship an
# scp binary on the target, but busybox always has tar and gzip.
tar czf - -C "$HERE/persist-proxy" . \
	| ssh "${SSH_OPTS[@]}" "${USER_}@${HOST}" \
	  'mkdir -p /persist/proxy && gunzip -c | tar xf - -C /persist/proxy && chmod +x /persist/proxy/bootstrap.sh /persist/proxy/bin/*'

echo "==> probing the device"
ssh "${SSH_OPTS[@]}" "${USER_}@${HOST}" 'sh -s' <<'REMOTE'
echo "--- tinyproxy binary"
/persist/proxy/bin/tinyproxy -v || echo "!! tinyproxy will not run (wrong arch or not static?)"
echo "--- busybox httpd applet"
if busybox httpd --help >/dev/null 2>&1; then
	echo "present -- pacd fallback not needed"
else
	echo "ABSENT -- bootstrap.sh will use the bundled pacd instead"
fi
echo "--- mount -o bind support"
busybox mount 2>&1 | grep -qi bind && echo "looks supported" || echo "unverified; watchdog covers it"
echo "--- free space on /persist"
df -h /persist | tail -1
REMOTE

echo
echo "Done. Now run ./patch-boot.sh (SD card in the Mac) to wire the boot hook,"
echo "or test right now without rebooting:"
echo "  ssh ${SSH_OPTS[*]} ${USER_}@${HOST} '/persist/proxy/bootstrap.sh late'"
