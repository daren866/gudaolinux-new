#!/usr/bin/env bash
# ------------------------------------------------------------
# Build the Gudao Linux desktop pack.
# Downloads the dependency closure of the X desktop stack from
# Debian trixie (Xorg + Mesa llvmpipe + xfwm4 + xfce4-panel +
# xfdesktop + thunar + xfce4-terminal + dbus + udev + fonts), unpacks the debs
# into a rootfs tree, strips docs/locales and packs it into
# desktop-pack.tar.gz which gets embedded into the initramfs
# at /opt/. The `desktop` command unpacks it at runtime.
# ------------------------------------------------------------
set -euo pipefail

TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$TOP_DIR/desktop-pack.tar.gz"
# paths are overridable for local verification (CI uses the defaults)
APTROOT="${GUDAO_APTROOT:-/tmp/aptroot}"
ROOT="${GUDAO_DESKTOP_ROOT:-/tmp/desktop-root}"

PKGS=(
  # X server + drivers (modesetting is built into xserver-xorg-core)
  xserver-xorg-core
  xserver-xorg-video-fbdev
  xserver-xorg-input-libinput
  # Mesa - CPU rendering via llvmpipe
  libgl1-mesa-dri
  libglx-mesa0
  libgl1
  mesa-utils
  # desktop applications
  xfwm4
  xfce4-panel
  # native XFCE desktop layer (wallpaper + desktop icons, replaces the old
  # pcmanfm --desktop; thunar is its file-manager companion)
  # NOTE: Debian binary package name is xfdesktop4 (not xfdesktop)
  xfdesktop4
  thunar
  xfce4-terminal
  # MIME handler database: thunar 'Open With' and the garcon appmenu of
  # xfdesktop read the update-desktop-database cache
  desktop-file-utils
  # xfce session daemons: xfconf provides xfconfd (panel layout storage -
  # without it xfce4-panel shows NO panel at all), xfce4-settings provides
  # xfsettingsd (theme/icon settings). Both are only Recommends of the
  # panel, so --no-install-recommends drops them - list them explicitly!
  xfconf
  xfce4-settings
  # SVG icon loader for gdk-pixbuf (adwaita icons ship SVG variants)
  librsvg2-common
  # desktop infrastructure
  dbus
  dbus-x11
  udev
  adwaita-icon-theme
  shared-mime-info
  # fonts
  fonts-dejavu-core
  # sound: ALSA userland for the built-in virtual sound cards
  # (aplay/amixer/alsamixer/speaker-test/alsactl + the Front_Center test
  # wav; libasound2 pulls in /usr/share/alsa/alsa.conf). The DRIVERS live
  # in the kernel fragment (SND_HDA_INTEL / INTEL8X0 / ENS1370/1371) -
  # the initramfs ships no modules.
  alsa-utils
  # X diagnostics (xrandr / xwininfo / xdpyinfo)
  x11-utils
  x11-xserver-utils
)

echo ">>> preparing isolated apt environment (Debian trixie, download only)"
rm -rf "$APTROOT" "$ROOT"
mkdir -p "$APTROOT/lists/partial" "$APTROOT/cache/archives/partial" "$ROOT"
touch "$APTROOT/status"

cat > "$APTROOT/debian.list" <<'EOF'
deb [trusted=yes] http://deb.debian.org/debian trixie main
EOF

APT_OPTS=(
  -o Dir::Etc::SourceList="$APTROOT/debian.list"
  -o Dir::Etc::SourceParts=-
  -o Dir::State::Status="$APTROOT/status"
  -o Dir::State::lists="$APTROOT/lists"
  -o Dir::Cache="$APTROOT/cache"
  -o APT::Architecture=amd64
  -o APT::Architectures=amd64
  -o Acquire::Languages=none
  -o Acquire::Retries=3
)

apt-get "${APT_OPTS[@]}" update

echo ">>> resolving dependency closure for: ${PKGS[*]}"
apt-get "${APT_OPTS[@]}" install --download-only -y --no-install-recommends "${PKGS[@]}"

echo ">>> unpacking debs into $ROOT"
for deb in "$APTROOT"/cache/archives/*.deb; do
  dpkg-deb -x "$deb" "$ROOT"
done
echo ">>> $(ls "$APTROOT"/cache/archives/*.deb | wc -l) packages unpacked"

echo ">>> stripping docs / locales / dev files"
rm -rf "$ROOT"/usr/share/doc "$ROOT"/usr/share/man "$ROOT"/usr/share/locale \
       "$ROOT"/usr/share/info "$ROOT"/usr/share/lintian "$ROOT"/usr/share/bug \
       "$ROOT"/usr/include "$ROOT"/usr/lib/pkgconfig "$ROOT"/usr/share/pkgconfig
find "$ROOT" -name '*.a' -print0 | xargs -0 -r rm -f
find "$ROOT" -name '*.la' -print0 | xargs -0 -r rm -f

echo ">>> sanity checks"
test -f "$ROOT/usr/lib/xorg/Xorg"       || { echo "FAIL: Xorg binary missing";   exit 1; }
test -f "$ROOT/usr/bin/xfwm4"           || { echo "FAIL: xfwm4 missing";         exit 1; }
test -f "$ROOT/usr/bin/xfce4-panel"     || { echo "FAIL: xfce4-panel missing";   exit 1; }
test -f "$ROOT/usr/bin/xfdesktop"       || { echo "FAIL: xfdesktop missing";     exit 1; }
test -f "$ROOT/usr/bin/thunar"          || { echo "FAIL: thunar missing";        exit 1; }
test -f "$ROOT/usr/bin/xfce4-terminal"  || { echo "FAIL: xfce4-terminal missing"; exit 1; }
test -f "$ROOT/usr/bin/udevadm"         || { echo "FAIL: udevadm missing";       exit 1; }
test -f "$ROOT/usr/bin/dbus-launch"     || { echo "FAIL: dbus-launch missing";   exit 1; }
test -f "$ROOT/usr/bin/glxinfo"         || { echo "FAIL: glxinfo missing";       exit 1; }
test -f "$ROOT/usr/lib/x86_64-linux-gnu/xfce4/xfconf/xfconfd" || { echo "FAIL: xfconfd missing (xfce4-panel will not display!)"; exit 1; }
test -f "$ROOT/usr/bin/xfsettingsd"     || { echo "FAIL: xfsettingsd missing";   exit 1; }
test -f "$ROOT/usr/bin/update-mime-database" || { echo "FAIL: update-mime-database missing (image sniffing will break!)"; exit 1; }
test -f "$ROOT/usr/bin/aplay"         || { echo "FAIL: aplay missing (no sound playback!)";  exit 1; }
test -f "$ROOT/usr/sbin/alsactl"      || { echo "FAIL: alsactl missing (mixer init broken)"; exit 1; }
test -f "$ROOT/usr/share/alsa/alsa.conf" || { echo "FAIL: alsa.conf missing (libasound2 config absent - aplay cannot open ANY pcm)"; exit 1; }
test -f "$ROOT/usr/share/sounds/alsa/Front_Center.wav" || { echo "FAIL: Front_Center.wav missing (sound self-test would fail)"; exit 1; }
echo "ALSA userland present (aplay/alsactl + alsa.conf + test wav)"
ls "$ROOT"/usr/lib/x86_64-linux-gnu/dri/ || true
ls "$ROOT"/usr/lib/x86_64-linux-gnu/libLLVM* >/dev/null 2>&1 && echo "LLVM (llvmpipe backend) present"
ls "$ROOT"/usr/share/X11/xkb >/dev/null 2>&1 && echo "xkb data present"
ls "$ROOT"/usr/bin/update-desktop-database >/dev/null 2>&1 && echo "desktop-file-utils present"

echo ">>> merged-usr staging checks (base-files must have extracted first)"
# the desktop closure contains base-files which ships the four usrmerge
# root symlinks; every other deb extracts THROUGH them, so the whole
# staging tree must be merged-usr. If /bin is a real directory here the
# extraction order broke (a deb shipped /bin content before base-files)
# and the pack would collide with the live root's symlinks.
test -L "$ROOT/bin"   && [ "$(readlink "$ROOT/bin")" = "usr/bin" ] \
  || { echo "FAIL: staging /bin is not a symlink to usr/bin (base-files missing or extracted out of order)"; exit 1; }
for l in sbin lib lib64; do
    test -L "$ROOT/$l" \
        || { echo "FAIL: staging /$l is not a usrmerge symlink"; exit 1; }
done
echo ">>> staging is merged-usr (bin/sbin/lib/lib64 -> usr/...): OK"

echo ">>> packing desktop-pack.tar.gz"
# NOTE: exclude the top-level usrmerge symlinks (./bin ./sbin ./lib
# ./lib64): the live root's initramfs owns that layout (build-initramfs.sh
# creates the four symlinks), and a pack carrying them would collide at
# unpack time. Every real file lives under ./usr, which merges cleanly.
tar czf "$OUT" -C "$ROOT" \
    --exclude='./bin' \
    --exclude='./sbin' \
    --exclude='./lib' \
    --exclude='./lib64' \
    .
echo ">>> unpacked size: $(du -sh "$ROOT" | cut -f1)"
echo ">>> desktop pack written: $OUT ($(du -h "$OUT" | cut -f1))"
