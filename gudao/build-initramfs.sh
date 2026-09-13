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
# /tmp MUST be world-writable (1777): apt's fetch sandbox drops privileges
# to the _apt user and its gpgv verification does mkstemp(/tmp/apt.sig.*)
# - a 755 /tmp makes every signature check fail with EACCES ("repository
# is not signed") even though the download itself succeeded
chmod 1777 "$ROOT/tmp"

cp "$BB" "$ROOT/bin/busybox"
chmod 755 "$ROOT/bin/busybox"

cp "$GUDAO_DIR/initramfs-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"

# ---- the `desktop` command (Xorg + Mesa CPU rendering + xfwm4 stack) ----
# The heavy desktop payload lives in /opt/desktop-pack.tar.gz (embedded below);
# this launcher unpacks it on first use and brings the stack up in order:
#   Xorg (Mesa llvmpipe) -> xfwm4 -> xfce4-panel -> xfdesktop
#   -> thunar --daemon + xfce4-terminal
cat > "$ROOT/usr/bin/desktop" <<'EOF'
#!/bin/sh
# ------------------------------------------------------------
# Gudao Linux desktop launcher
#   desktop   -> Xorg (Mesa CPU rendering) + xfwm4 + xfce4-panel
#                + xfdesktop + thunar (file manager, daemon mode)
#                + xfce4-terminal
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
    # generate the gdk-pixbuf loader cache (Debian debs don't ship it;
    # external loaders like gif/tiff/svg are dead without it)
    GPQ=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders
    [ -x "$GPQ" ] && "$GPQ" --update-cache >/dev/null 2>&1 || true
    # regenerate the freedesktop MIME database. The shared-mime-info deb only
    # ships the XML source - without the compiled cache GIO cannot sniff ANY
    # image type, gdk-pixbuf reports "Unrecognized image file format" and GTK
    # aborts on the first icon load (this used to crash xfce4-panel instantly)
    UMD=/usr/bin/update-mime-database
    [ -x "$UMD" ] && "$UMD" /usr/share/mime >/dev/null 2>&1 || true
    # regenerate the .desktop MIME handler cache (same story: debs ship no
    # cache; without it thunar 'Open With' and the xfdesktop/garcon menu
    # application lists are incomplete)
    UDD=/usr/bin/update-desktop-database
    [ -x "$UDD" ] && "$UDD" /usr/share/applications >/dev/null 2>&1 || true
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
# devpts fallback: VTE terminals (xfce4-terminal) open shells through
# /dev/ptmx -> /dev/pts/N; if init did not mount devpts for any reason,
# mount it here or every terminal fails with "Failed to open PTY"
mkdir -p /dev/pts
mountpoint -q /dev/pts 2>/dev/null \
  || mount -t devpts devpts /dev/pts 2>/dev/null \
  || true
dbus-uuidgen --ensure >/dev/null 2>&1 || true
eval "$(dbus-launch --sh-syntax 2>/dev/null)"
export LIBGL_ALWAYS_SOFTWARE=1        # force Mesa software rendering (llvmpipe)
export GALLIUM_DRIVER=llvmpipe
export NO_AT_BRIDGE=1                 # no accessibility bus in the live system
export DISPLAY=:0

# 3b. xfce session daemons (need the session bus from dbus-launch above):
#   xfconfd     - stores the panel layout; xfce4-panel shows NO panel without it
#   xfsettingsd - applies theme/icon/keyboard settings
XCFD=/usr/lib/x86_64-linux-gnu/xfce4/xfconf/xfconfd
if [ -x "$XCFD" ]; then
    "$XCFD" >/var/log/xfconfd.log 2>&1 &
fi
if [ -x /usr/bin/xfsettingsd ]; then
    xfsettingsd >/var/log/xfsettingsd.log 2>&1 &
fi

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
xfwm4 --compositor=off >/var/log/xfwm4.log 2>&1 &
echo "desktop: loading xfce4-panel..."
xfce4-panel >/var/log/xfce4-panel.log 2>&1 &
echo "desktop: loading xfdesktop (desktop layer)..."
xfdesktop >/var/log/xfdesktop.log 2>&1 &
echo "desktop: loading thunar (file manager, daemon mode)..."
thunar --daemon >/var/log/thunar.log 2>&1 &
echo "desktop: loading xfce4-terminal..."
xfce4-terminal >/var/log/xfce4-terminal.log 2>&1 &

# 6. verify the panel window is actually mapped on the screen (the process
#    can be alive while its window never shows - verify the real thing)
PANEL_OK=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    xwininfo -root -tree 2>/dev/null | grep -qi 'xfce4.panel' && PANEL_OK=1 && break
    sleep 1
done
if [ "$PANEL_OK" = "1" ]; then
    echo "desktop: panel window mapped."
else
    echo "desktop: WARNING - panel window not detected! panel log tail:"
    tail -12 /var/log/xfce4-panel.log 2>/dev/null || true
    echo "desktop: top-level windows on screen:"
    xwininfo -root -tree 2>/dev/null | sed -n '3,12p' || true
fi

echo
echo "  Desktop is up: Xorg (Mesa llvmpipe) + xfwm4 + xfce4-panel + xfdesktop"
echo "                  + thunar (file manager) + xfce4-terminal"
echo "  Look at the GUI display of your VM / machine (vt1)."
echo
EOF
chmod 755 "$ROOT/usr/bin/desktop"

# ---- embed the apt pack if it has been built ----
# (package manager: apt+dpkg unpacked by /init at every boot, see
# gudao/build-apt-pack.sh - works headless, independent of the desktop pack)
if [ -f "$TOP_DIR/apt-pack.tar.gz" ]; then
    echo ">>> embedding apt pack into initramfs /opt/"
    cp "$TOP_DIR/apt-pack.tar.gz" "$ROOT/opt/apt-pack.tar.gz"
else
    echo ">>> no apt-pack.tar.gz found, building initramfs without apt"
fi

# ---- embed the desktop pack if it has been built ----
if [ -f "$TOP_DIR/desktop-pack.tar.gz" ]; then
    echo ">>> embedding desktop pack into initramfs /opt/"
    cp "$TOP_DIR/desktop-pack.tar.gz" "$ROOT/opt/desktop-pack.tar.gz"
else
    echo ">>> no desktop-pack.tar.gz found, building base-only initramfs"
fi

cat > "$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
_apt:x:100:100::/nonexistent:/bin/false
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF
cat > "$ROOT/etc/group" <<'EOF'
root:x:0:
_apt:x:100:
nogroup:x:65534:
EOF
cat > "$ROOT/etc/hosts" <<'EOF'
127.0.0.1 localhost gudao
::1 localhost ip6-localhost ip6-loopback
EOF
cat > "$ROOT/etc/hostname" <<'EOF'
gudao
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
