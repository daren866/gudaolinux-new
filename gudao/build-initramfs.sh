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
mkdir -p "$ROOT"/{etc,proc,sys,dev,tmp,mnt,root,run,usr/bin,usr/sbin,usr/lib,usr/lib64,opt,var/log,var/lib/dbus,var/lib/xkb,var/cache}
# /tmp MUST be world-writable (1777): apt's fetch sandbox drops privileges
# to the _apt user and its gpgv verification does mkstemp(/tmp/apt.sig.*)
# - a 755 /tmp makes every signature check fail with EACCES ("repository
# is not signed") even though the download itself succeeded
chmod 1777 "$ROOT/tmp"

# busybox lives in /usr/bin (merged-usr: /bin IS /usr/bin)
cp "$BB" "$ROOT/usr/bin/busybox"
chmod 755 "$ROOT/usr/bin/busybox"

# ---- merged-usr root layout (mandatory since Debian bookworm) --------
# /bin /sbin /lib /lib64 are symlinks into /usr. dpkg and apt 3.x REFUSE
# an unmerged usr (apt warns "Unmerged usr is no longer supported" and a
# runtime-pulled usrmerge package fails to configure - which took down
# tzdata/libpython/python3 with it in the r21 image). The busybox root
# OWNS these four symlinks; neither pack ever ships root-level entries,
# so they survive every pack unpack untouched.
ln -sfn usr/bin   "$ROOT/bin"
ln -sfn usr/sbin  "$ROOT/sbin"
ln -sfn usr/lib   "$ROOT/lib"
ln -sfn usr/lib64 "$ROOT/lib64"
for pair in "bin usr/bin" "sbin usr/sbin" "lib usr/lib" "lib64 usr/lib64"; do
    set -- $pair
    test -L "$ROOT/$1" && [ "$(readlink "$ROOT/$1")" = "$2" ] \
        || { echo "FAIL: merged-usr symlink $ROOT/$1 -> $2 missing"; exit 1; }
done
echo ">>> merged-usr root layout in place"

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
    # 1a. drop busybox applet symlinks first: the pack ships REAL binaries
    # for many of the same paths, and tar extracting a regular file over an
    # applet symlink would FOLLOW the link and clobber /usr/bin/busybox
    # itself. Applets are restored after the unpack (real files win).
    for f in /usr/bin/*; do
        [ "$(/bin/busybox readlink "$f" 2>/dev/null)" = "busybox" ] \
            && /bin/busybox rm -f "$f"
    done
    # 1b. unpack via the busybox binary directly (PATH applets just got
    # swept, so bare 'tar' may not resolve)
    /bin/busybox tar xzf "$PACK" -C / \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/group \
        --exclude=etc/gudao-banner \
        || { echo "desktop: unpack failed"; exit 1; }
    /bin/busybox rm -f "$PACK"   # free the RAM occupied by the archive
    # 1c. restore the busybox applets the pack did not shadow with real
    # binaries (real Debian binaries always win over applets)
    for a in $(/bin/busybox --list); do
        [ -e "/bin/$a" ] || /bin/busybox ln -sf busybox "/bin/$a"
    done
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
    /bin/busybox mkdir -p /run/udev
    UDEVD=/usr/lib/systemd/systemd-udevd
    [ -x "$UDEVD" ] || UDEVD=/lib/udev/udevd
    "$UDEVD" --daemon >/dev/null 2>&1 || true
    udevadm trigger --action=add >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
fi

# 2b. system dbus bus (Xorg connects to it; silences dbus-core errors)
if [ ! -S /run/dbus/system_bus_socket ]; then
    /bin/busybox mkdir -p /run/dbus
    dbus-daemon --system --fork >/dev/null 2>&1 || true
fi

# 2c. sound: HDA/AC97 codecs power up MUTED, so nothing would be audible
#     until the mixer is initialized. sound-init waits for the card and
#     applies Debian's standard unmute+levels rules; backgrounded so a
#     slow codec probe never delays the X session. Log: sound-init.log
/usr/bin/sound-init >/var/log/sound-init.log 2>&1 &

# 3. runtime dirs + dbus + Mesa CPU rendering (llvmpipe)
# /bin/busybox prefix: the desktop pack may or may not ship coreutils, so
# the real mkdir/chmod/mount may exist only as the (re-created) busybox
# applets - call the binary directly to stay independent of PATH state
/bin/busybox mkdir -p /tmp/.X11-unix /var/log /var/lib/dbus /root/.config
/bin/busybox chmod 1777 /tmp/.X11-unix
# devpts fallback: VTE terminals (xfce4-terminal) open shells through
# /dev/ptmx -> /dev/pts/N; if init did not mount devpts for any reason,
# mount it here or every terminal fails with "Failed to open PTY"
/bin/busybox mkdir -p /dev/pts
/bin/busybox mountpoint -q /dev/pts 2>/dev/null \
  || /bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null \
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

# 5b. volume control applet (tray mixer, ALSA backend): left-click popup
#     slider / scroll-wheel volume, right-click menu (mixer + preferences).
#     applet = volumeicon (pnmixer 0.7.2 aborts in vol_meter_draw, Debian
#     bug #922932, on codecs without dB info - QEMU hda-duplex - as soon
#     as the volume changes; volumeicon has no such assertion).
#     Preseed its config FIRST: without one it pops a setup dialog on
#     start, and the default lmb_slider=false + onclick=xterm would make
#     the left click useless (xterm is not shipped). Started once a sound
#     card actually registers - without a card the applet would only warn.
if [ -x /usr/bin/volumeicon ]; then
    (
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null && break
            sleep 1
        done
        if grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null; then
            /bin/busybox mkdir -p /root/.config/volumeicon
            /bin/busybox cat > /root/.config/volumeicon/volumeicon <<'VICFG'
[Alsa]
card=default
channel=Master
logarithmic_scale=false

[Notification]
show_notification=false
notification_type=0

[StatusIcon]
stepsize=5
onclick=xfce4-terminal -x alsamixer
theme=tango
use_panel_specific_icons=true
lmb_slider=true
mmb_mute=true
use_horizontal_slider=false
use_transparent_background=false
VICFG
            exec /usr/bin/volumeicon
        else
            echo "volumeicon: no sound card detected - volume applet not started (run 'sound-init' after attaching one)"
        fi
    ) >/var/log/volumeicon.log 2>&1 &
else
    echo "desktop: WARNING - volumeicon missing from the desktop pack (no volume control)"
fi

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
echo "                  + thunar (file manager) + xfce4-terminal + volumeicon (volume)"
echo "  Look at the GUI display of your VM / machine (vt1)."
echo "  Sound: volume slider in the panel tray; sound-init re-runs mixer init."
echo
EOF
chmod 755 "$ROOT/usr/bin/desktop"

# ---- the `sound-init` command (ALSA mixer bring-up) ----
# HDA/AC97 codecs power up muted; without this, a freshly booted VM is
# silent even though the card and playback path are perfectly fine
# (Run#31 CI passed aplay while the user's real VM stayed silent).
# The desktop launcher backgrounds it at session start; it is also a
# standalone console command for manual re-runs.
cat > "$ROOT/usr/bin/sound-init" <<'EOF'
#!/bin/sh
# ------------------------------------------------------------
# Gudao Linux sound-init: bring the ALSA mixer of the (emulated)
# sound card into a sane audible state.
#
# HDA and AC97 codecs power up with outputs MUTED or at volume 0,
# so a freshly booted VM is silent until something unmutes the
# mixer. This script does exactly that:
#   1. wait for a card to register (the HDA codec probe runs on an
#      async workqueue and may lag the boot by a few seconds)
#   2. alsactl init - Debian's standard per-card mixer rules
#      (unmute + sane levels for Master/PCM/Front/...)
#   3. amixer fallback for codecs the rules did not cover
#
# The desktop launcher backgrounds it at session start (log:
# /var/log/sound-init.log); it can also be run by hand at any
# time from the console:  sound-init
# ------------------------------------------------------------
LOG_TAG="sound-init"
say() { echo "[$LOG_TAG] $*"; }

# /var/lib/alsa: alsactl state/lock directory
/bin/busybox mkdir -p /var/lib/alsa 2>/dev/null

# 1. wait up to 10s for a real card line ("  0 [Intel  ]: HDA-Intel - ...").
#    procfs files always report st_size 0 and an empty card list still
#    contains the literal "--- no soundcards ---", so never test file
#    size or emptiness here - match the card line itself.
W=0
while [ $W -lt 10 ]; do
    grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null && break
    W=$((W+1))
    sleep 1
done
if ! grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null; then
    say "no sound card in /proc/asound/cards (VM has no audio device?)"
    say "QEMU: add  -device intel-hda -device hda-duplex  (see README-GUDAO.md)"
    exit 1
fi
say "card detected: $(sed -n 's/^ *//;1p' /proc/asound/cards | tr -s ' ')"

# 2. alsactl init (ships in /usr/sbin of the desktop pack; before the
#    pack is unpacked the tool simply is not there yet - say so)
ALSACTL=""
[ -x /usr/sbin/alsactl ] && ALSACTL=/usr/sbin/alsactl
[ -z "$ALSACTL" ] && ALSACTL=$(command -v alsactl 2>/dev/null)
INIT_OK=0
if [ -n "$ALSACTL" ] && [ -x "$ALSACTL" ]; then
    if "$ALSACTL" init >/var/log/alsactl-init.log 2>&1; then
        INIT_OK=1
        say "alsactl init applied (unmute + levels, see /var/log/alsactl-init.log)"
    else
        say "alsactl init failed (rc=$?) - falling back to amixer"
    fi
else
    say "alsactl not available yet (unpack the desktop pack first: run 'desktop') - falling back to amixer"
fi

# 3. amixer fallback: only when alsactl's rules could not run - setting
#    100% on top of a successful alsactl init would needlessly blast
#    full volume. Controls missing on a codec just draw errors we ignore.
if [ "$INIT_OK" = "0" ]; then
    AMIXER=$(command -v amixer 2>/dev/null)
    if [ -n "$AMIXER" ]; then
        for CTL in Master PCM Front Speaker Headphone; do
            "$AMIXER" sset "$CTL" 90% unmute >/dev/null 2>&1 || true
        done
        say "amixer fallback applied (Master/PCM/Front/Speaker/Headphone 90% unmute)"
    else
        say "amixer not available either - mixer left at codec defaults"
    fi
fi

# 4. report the state the user should hear + dump the evidence needed to
#    split "guest broken" from "host/VM backend silent":
#      - amixer get Master  -> mixer open/unmuted with a real level?
#      - aplay -l           -> which card/codec did the kernel register?
#    If playback through 'default' succeeds (run the aplay below) but the
#    VM is still silent, the guest side is DONE - the audio data reached
#    the kernel driver - and the problem is on the host side (QEMU:
#    missing -audiodev or backend, host output device; VMware/VBox: sound
#    card disabled in the VM settings or host muted).
if command -v amixer >/dev/null 2>&1; then
    if amixer get Master 2>/dev/null | grep -q '\[on\]'; then
        say "mixer state: Master unmuted (on) - sound should be audible now"
    else
        say "mixer state: Master control not found or still muted (codec may name it differently - try 'alsamixer')"
    fi
    say "mixer dump: [$(amixer get Master 2>/dev/null | tr '\n' '|' | head -c 300)]"
    say "aplay -l:   [$(aplay -l 2>&1 | tr '\n' '|' | head -c 300)]"
    say "PCM devices:[$(cat /proc/asound/pcm 2>/dev/null | tr '\n' '|' | head -c 200)]"
fi
say "done (test playback: aplay /usr/share/sounds/alsa/Front_Center.wav)"
say "if playback succeeds but the VM is still silent -> guest is fine, check the HOST side (QEMU -audiodev / VM sound card settings / host volume)"
exit 0
EOF
chmod 755 "$ROOT/usr/bin/sound-init"
# guard: the mixer bring-up script MUST exist or every boot stays silent
test -x "$ROOT/usr/bin/sound-init" \
    || { echo "FAIL: sound-init not generated (mixer would stay muted)"; exit 1; }

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
audio:x:29:
EOF
# the audio group is REQUIRED by ALSA dmix: the 'default' pcm maps to dmix
# whose ipc_gid field resolves to the 'audio' group - without the group,
# every playback through 'default' dies with
#   "The field ipc_gid must be a valid group (create group audio)"
# (Debian normally ships the group via base-passwd, which is not in our
# minimal closure). gid 29 is the Debian-standard audio group id.
grep -q '^audio:' "$ROOT/etc/group" \
    || { echo "FAIL: audio group missing (ALSA 'default'/dmix needs ipc_gid audio)"; exit 1; }
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
