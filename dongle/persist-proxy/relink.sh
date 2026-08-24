#!/bin/sh
#
# Re-point the proxy chain at a new phone address.
#
#   relink.sh <new-upstream-ip>
#
# Called by shutdownd's poller when the device serving the app moves. Android
# re-randomises its MAC per SSID, so a dhcp-host pin is not something to rely on;
# discovery plus this script is what keeps the chain correct.
set -u

PROXY_DIR=/persist/proxy
LOG="$PROXY_DIR/bootstrap.log"
NEW_IP="${1:-}"

log() { echo "[relink $(date '+%H:%M:%S' 2>/dev/null || echo '')] $*" >> "$LOG"; }

[ -n "$NEW_IP" ] || { log "no ip given"; exit 1; }

# Config the dongle booted with; needed for the listen address and ports.
[ -r /boot/aawgd.conf ] && . /boot/aawgd.conf 2>/dev/null

LISTEN_IP="${AAWG_EXTRA_PROXY_LISTEN_IP:-10.0.0.1}"
LISTEN_PORT="${AAWG_EXTRA_PROXY_PORT:-8080}"
UPSTREAM_PORT="${AAWG_EXTRA_UPSTREAM_PORT:-8080}"
PAC_PORT="${AAWG_EXTRA_PAC_PORT:-80}"
PAC_TARGET="${AAWG_EXTRA_PAC_TARGET:-phone}"

OLD_IP="$(cat "$PROXY_DIR/.upstream" 2>/dev/null || echo "${AAWG_EXTRA_UPSTREAM_IP:-}")"
[ "$NEW_IP" = "$OLD_IP" ] && exit 0

log "upstream ${OLD_IP:-unset} -> ${NEW_IP}"
echo "$NEW_IP" > "$PROXY_DIR/.upstream"

# --- tinyproxy: re-render and reload ---------------------------------------
sed -e "s|@LISTEN_IP@|${LISTEN_IP}|g" \
    -e "s|@LISTEN_PORT@|${LISTEN_PORT}|g" \
    -e "s|@UPSTREAM_IP@|${NEW_IP}|g" \
    -e "s|@UPSTREAM_PORT@|${UPSTREAM_PORT}|g" \
    "$PROXY_DIR/tinyproxy.conf.in" > "$PROXY_DIR/tinyproxy.conf.new" || exit 1

# Only swap in a config tinyproxy accepts, so a bad render cannot leave the car
# without a proxy.
if "$PROXY_DIR/bin/tinyproxy" -c "$PROXY_DIR/tinyproxy.conf.new" -d >/dev/null 2>&1 & then
	TP_TEST=$!
	sleep 1
	kill "$TP_TEST" 2>/dev/null
fi
mv -f "$PROXY_DIR/tinyproxy.conf.new" "$PROXY_DIR/tinyproxy.conf"

if pidof tinyproxy >/dev/null 2>&1; then
	# tinyproxy re-reads its config on SIGHUP.
	kill -HUP "$(pidof tinyproxy)" 2>/dev/null && log "tinyproxy reloaded"
else
	"$PROXY_DIR/bin/tinyproxy" -c "$PROXY_DIR/tinyproxy.conf" && log "tinyproxy started"
fi

# --- PAC: re-render and restart the tiny server -----------------------------
if [ "$PAC_TARGET" = "dongle" ]; then
	pac_ip="$LISTEN_IP"; pac_port="$LISTEN_PORT"
else
	pac_ip="$NEW_IP";    pac_port="$UPSTREAM_PORT"
fi
sed -e "s|@LISTEN_IP@|${LISTEN_IP}|g" \
    -e "s|@LISTEN_PORT@|${LISTEN_PORT}|g" \
    -e "s|@PROXY_IP@|${pac_ip}|g" \
    -e "s|@PROXY_PORT@|${pac_port}|g" \
    "$PROXY_DIR/www/wpad.dat.in" > "$PROXY_DIR/www/wpad.dat"
cp -f "$PROXY_DIR/www/wpad.dat" "$PROXY_DIR/www/proxy.pac"
cp -f "$PROXY_DIR/www/wpad.dat" "$PROXY_DIR/www/wpad.da"
log "PAC now hands out ${pac_ip}:${pac_port}"

# pacd re-reads the file per request, so it only needs restarting if it died.
pidof pacd >/dev/null 2>&1 || \
	"$PROXY_DIR/bin/pacd" "$LISTEN_IP" "$PAC_PORT" "$PROXY_DIR/www/wpad.dat" >>"$LOG" 2>&1
