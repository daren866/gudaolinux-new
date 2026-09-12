#!/usr/bin/env bash
# ------------------------------------------------------------
# Build the Gudao Linux initramfs (BusyBox-based)
# ------------------------------------------------------------
set -euo pipefail

GUDAO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "$GUDAO_DIR/.." && pwd)"
ROOT="$GUDAO_DIR/initramfs-root"
OUT="$TOP_DIR/initramfs-gudao.img"

# busybox binary: built from source (preferred) or distro fallback
BB="$TOP_DIR/busybox-1.36.1/busybox"
if [ ! -x "$BB" ]; then
    BB=/bin/busybox
fi
echo ">>> using busybox: $BB"

rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,dev,tmp,mnt,root,run,usr/bin,usr/sbin,opt,var/log,var/lib/dbus,var/lib/xkb,var/cache}

cp "$BB" "$ROOT/bin/busybox"
chmod 755 "$ROOT/bin/busybox"

cp "$GUDAO_DIR/initramfs-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"

# ---- the `desktop` command (Xorg + Mesa CPU rendering + xfwm4 stack) ----
# The heavy desktop payload lives in /opt/desktop-pack.tar.gz (embedded below);
# this launcher unpacks it on first use and brings the stack up in order:
#   Xorg (Mesa llvmpipe) -> xfwm4 -> xfce4-panel -> pcmanfm --desktop -> lxterminal
cat > "$ROOT/usr/bin/desktop" <<'EOF'
#!/bin/sh
# ------------------------------------------------------------
# Gudao Linux desktop launcher
#   desktop   -> Xorg (Mesa CPU rendering) + xfwm4 + xfce4-panel
#                + pcmanfm desktop + lxterminal
# ------------------------------------------------------------
PACK=/opt/desktop-pack.tar.gz

# 1. unpack the desktop pack on first use
if [ ! -x /usr/bin/xfwm4 ]; then
    if [ ! -f "$PACK" ]; then
        echo "desktop: $PACK not found (this build has no desktop pack)"
        exit 1
    fi
    echo "desktop: unpacking desktop pack (first run only, please wait)..."
    tar xzf "$PACK" -C / \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/group \
        --exclude=etc/gudao-banner \
        || { echo "desktop: unpack failed"; exit 1; }
    rm -f "$PACK"   # free the RAM occupied by the archive
    echo "desktop: pack unpacked."
    # generate the gdk-pixbuf loader cache (Debian debs don't ship it,
    # without it GTK apps cannot load any icons/images)
    GPQ=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders
    [ -x "$GPQ" ] && "$GPQ" --update-cache >/dev/null 2>&1 || true
fi

# 2. udev (libinput needs the udev database to find mice/keyboards)
if [ ! -d /run/udev/data ]; then
    mkdir -p /run/udev
    UDEVD=/usr/lib/systemd/systemd-udevd
    [ -x "$UDEVD" ] || UDEVD=/lib/udev/udevd
    "$UDEVD" --daemon >/dev/null 2>&1 || true
    udevadm trigger --action=add >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
fi

# 2b. system dbus bus (Xorg connects to it; silences dbus-core errors)
if [ ! -S /run/dbus/system_bus_socket ]; then
    mkdir -p /run/dbus
    dbus-daemon --system --fork >/dev/null 2>&1 || true
fi

# 3. runtime dirs + dbus + Mesa CPU rendering (llvmpipe)
mkdir -p /tmp/.X11-unix /var/log /var/lib/dbus /root/.config
chmod 1777 /tmp/.X11-unix
dbus-uuidgen --ensure >/dev/null 2>&1 || true
eval "$(dbus-launch --sh-syntax 2>/dev/null)"
export LIBGL_ALWAYS_SOFTWARE=1        # force Mesa software rendering (llvmpipe)
export GALLIUM_DRIVER=llvmpipe
export NO_AT_BRIDGE=1                 # no accessibility bus in the live system
export DISPLAY=:0

# 4. Xorg on vt1 (modesetting on a DRM card; fbdev/vesa fallback + Mesa GLX)
echo "desktop: graphics devices: /dev/dri=[$(ls /dev/dri 2>/dev/null | tr '\n' ' ')] fb=[$(ls /dev/fb* 2>/dev/null | tr '\n' ' ')]"
echo "desktop: starting Xorg (Mesa CPU rendering)..."
Xorg :0 -nolisten tcp -keeptty vt1 >/var/log/xorg-start.log 2>&1 &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
         21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    [ -S /tmp/.X11-unix/X0 ] && break
    sleep 1
done
if [ ! -S /tmp/.X11-unix/X0 ]; then
    echo "desktop: Xorg did not come up, log tail:"
    tail -20 /var/log/Xorg.0.log 2>/dev/null || tail -20 /var/log/xorg-start.log
    echo "desktop: diagnose /dev/dri:  $(ls /dev/dri 2>/dev/null || echo '(none)')"
    echo "desktop: diagnose /dev/fb*:  $(ls /dev/fb* 2>/dev/null || echo '(none)')"
    echo "desktop: diagnose kernel drm/fb messages:"
    dmesg 2>/dev/null | grep -iE 'drm|framebuffer|simple-frame|vesa|vbe|bochs|qxl|vmwgfx|vbox|virtio.gpu' | tail -12 || true
    exit 1
fi

# 5. window manager first, then the rest
echo "desktop: loading xfwm4 (window manager)..."
xfwm4 --compositor=off &
echo "desktop: loading xfce4-panel..."
xfce4-panel &
echo "desktop: loading pcmanfm (desktop background)..."
pcmanfm --desktop &
echo "desktop: loading lxterminal..."
lxterminal &

echo
echo "  Desktop is up: Xorg (Mesa llvmpipe) + xfwm4 + xfce4-panel + pcmanfm + lxterminal"
echo "  Look at the GUI display of your VM / machine (vt1)."
echo
EOF
chmod 755 "$ROOT/usr/bin/desktop"

# ---- embed the desktop pack if it has been built ----
if [ -f "$TOP_DIR/desktop-pack.tar.gz" ]; then
    echo ">>> embedding desktop pack into initramfs /opt/"
    cp "$TOP_DIR/desktop-pack.tar.gz" "$ROOT/opt/desktop-pack.tar.gz"
else
    echo ">>> no desktop-pack.tar.gz found, building base-only initramfs"
fi

cat > "$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "$ROOT/etc/group" <<'EOF'
root:x:0:
EOF

cp "$GUDAO_DIR/gudao-banner.txt" "$ROOT/etc/gudao-banner"

if command -v cpio > /dev/null 2>&1; then
    echo ">>> packing with system cpio"
    ( cd "$ROOT" && find . -print0 | cpio --null -o -H newc --quiet | gzip -9 ) > "$OUT"
else
    echo ">>> packing with busybox cpio fallback"
    ( cd "$ROOT" && find . | "$BB" cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT"
fi
echo ">>> initramfs written: $OUT ($(du -h "$OUT" | cut -f1))"
