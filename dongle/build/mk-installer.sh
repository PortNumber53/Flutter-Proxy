#!/usr/bin/env bash
#
# Generate dongle-proxy-installer.sh: a single self-extracting file that can be
# carried to any machine able to reach the dongle.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/dongle-proxy-installer.sh"

cat > "$OUT" <<'HEADER'
#!/bin/sh
#
# Self-contained installer for the WirelessAA proxy bundle.
#
# Copy this ONE file to whatever machine can talk to the dongle and run it.
# It works two ways, auto-detected:
#
#   * On a laptop joined to the AAWirelessDongle Wi-Fi -> pushes over SSH.
#     Override the target with DONGLE_HOST / DONGLE_USER.
#
#   * On the dongle itself (if you copied this file across) -> installs locally.
#
# Everything lands in /persist/proxy. Nothing outside /persist is touched;
# the boot hook in /boot/aawgd.conf is wired separately by patch-boot.sh.
#
set -eu

PAYLOAD_LINE=$(awk '/^__PAYLOAD_BELOW__$/{print NR + 1; exit 0}' "$0")

# The dongle's busybox tar is built WITHOUT gzip support (-z is rejected), so
# decompression is a separate gunzip stage rather than tar's own flag. Alpine's
# busybox does accept -z, which is why this only shows up on the real device.
payload() { tail -n "+${PAYLOAD_LINE}" "$0" | base64 -d; }

if [ -d /persist ] && [ -w /persist ] && [ -f /etc/aawgd.conf ]; then
	echo "==> running on the dongle; installing to /persist/proxy"
	mkdir -p /persist/proxy
	payload | gunzip -c | tar xf - -C /persist/proxy
	chmod +x /persist/proxy/bootstrap.sh /persist/proxy/bin/* 2>/dev/null || true
	echo "==> installed"
	ls -l /persist/proxy /persist/proxy/bin
	echo
	echo "Start it now without rebooting:"
	echo "  /persist/proxy/bootstrap.sh late"
	exit 0
fi

HOST="${DONGLE_HOST:-10.0.0.1}"
USER_="${DONGLE_USER:-root}"

echo "==> pushing to ${USER_}@${HOST}:/persist/proxy"
# Dropbear on the target speaks older algorithms than current OpenSSH enables.
payload | ssh -o HostKeyAlgorithms=+ssh-rsa \
	      -o PubkeyAcceptedAlgorithms=+ssh-rsa \
	      -o StrictHostKeyChecking=accept-new \
	      -o ConnectTimeout=10 \
	      "${USER_}@${HOST}" \
	  'mkdir -p /persist/proxy \
	   && gunzip -c | tar xf - -C /persist/proxy \
	   && chmod +x /persist/proxy/bootstrap.sh /persist/proxy/bin/* \
	   && echo "--- installed:" && ls /persist/proxy \
	   && echo "--- tinyproxy:" && /persist/proxy/bin/tinyproxy -v 2>&1 | head -1 \
	   && echo "--- busybox httpd applet:" \
	   && { busybox httpd --help >/dev/null 2>&1 && echo present || echo "ABSENT (pacd fallback will be used)"; } \
	   && echo "--- /persist free:" && df -h /persist | tail -1'

echo
echo "Done. Start it now without rebooting:"
echo "  ssh ${USER_}@${HOST} '/persist/proxy/bootstrap.sh late'"
exit 0

__PAYLOAD_BELOW__
HEADER

tar czf - -C "$HERE/persist-proxy" . | base64 >> "$OUT"
chmod +x "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
