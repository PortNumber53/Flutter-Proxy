#!/usr/bin/env bash
#
# Cross-build a static armv7 tinyproxy (+ the pacd fallback) for the dongle.
#
# Why static/musl: the dongle's Buildroot rootfs uses uClibc-ng (the defconfig
# sets no BR2_TOOLCHAIN_*_LIBC, so Buildroot's default applies), so a
# glibc-linked binary will not load. A fully static musl binary sidesteps the
# question entirely.
#
# The Pi Zero 2W is a Cortex-A53 but this image runs a 32-bit kernel
# (BR2_LINUX_KERNEL_DEFCONFIG="bcm2709"), so the target is linux/arm/v7.
#
set -euo pipefail

TINYPROXY_VERSION="${TINYPROXY_VERSION:-1.11.2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../persist-proxy/bin"

command -v docker >/dev/null || { echo "docker is required (Docker Desktop, colima, ...)" >&2; exit 1; }
mkdir -p "$OUT"

echo "==> building static armv7 tinyproxy ${TINYPROXY_VERSION} + pacd (qemu-emulated, takes a few minutes)"

docker run --rm --platform linux/arm/v7 \
	-v "$HERE:/work" -v "$OUT:/out" -w /build \
	alpine:3.20 sh -euxc "
	apk add --no-cache build-base curl automake autoconf

	curl -fsSL -o tinyproxy.tar.gz \
		https://github.com/tinyproxy/tinyproxy/releases/download/${TINYPROXY_VERSION}/tinyproxy-${TINYPROXY_VERSION}.tar.gz
	tar xf tinyproxy.tar.gz
	cd tinyproxy-${TINYPROXY_VERSION}

	# --enable-upstream is what makes the 'upstream http ...' directive exist;
	# without it the dongle cannot forward to the phone at all.
	./configure \
		--enable-upstream \
		--disable-regexcheck \
		--disable-manpage-support \
		CFLAGS='-Os' LDFLAGS='-static'
	make -j\"\$(nproc)\"

	src/tinyproxy -v
	cp src/tinyproxy /out/tinyproxy

	cd /build
	cc -Os -static -o /out/pacd /work/pacd.c

	strip /out/tinyproxy /out/pacd
	chmod +x /out/tinyproxy /out/pacd
"

echo
echo "==> built:"
ls -l "$OUT"
file "$OUT/tinyproxy" "$OUT/pacd" 2>/dev/null || true
echo
echo "Both must report 'statically linked'. Next: ./install.sh"
