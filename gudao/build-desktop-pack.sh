#!/usr/bin/env bash
# ------------------------------------------------------------
# Build the Gudao Linux desktop pack.
# Downloads the dependency closure of the X desktop stack from
# Debian trixie (Xorg + Mesa llvmpipe + xfwm4 + xfce4-panel +
# pcmanfm + lxterminal + dbus + udev + fonts), unpacks the debs
# into a rootfs tree, strips docs/locales and packs it into
# desktop-pack.tar.gz which gets embedded into the initramfs
# at /opt/. The `desktop` command unpacks it at runtime.
# ------------------------------------------------------------
set -euo pipefail

TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$TOP_DIR/desktop-pack.tar.gz"
APTROOT=/tmp/aptroot
ROOT=/tmp/desktop-root

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
  pcmanfm
  lxterminal
  # desktop infrastructure
  dbus
  dbus-x11
  udev
  adwaita-icon-theme
  shared-mime-info
  # fonts
  fonts-dejavu-core
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
test -f "$ROOT/usr/bin/pcmanfm"         || { echo "FAIL: pcmanfm missing";       exit 1; }
test -f "$ROOT/usr/bin/lxterminal"      || { echo "FAIL: lxterminal missing";    exit 1; }
test -f "$ROOT/usr/bin/udevadm"         || { echo "FAIL: udevadm missing";       exit 1; }
test -f "$ROOT/usr/bin/dbus-launch"     || { echo "FAIL: dbus-launch missing";   exit 1; }
test -f "$ROOT/usr/bin/glxinfo"         || { echo "FAIL: glxinfo missing";       exit 1; }
ls "$ROOT"/usr/lib/x86_64-linux-gnu/dri/ || true
ls "$ROOT"/usr/lib/x86_64-linux-gnu/libLLVM* >/dev/null 2>&1 && echo "LLVM (llvmpipe backend) present"
ls "$ROOT"/usr/share/X11/xkb >/dev/null 2>&1 && echo "xkb data present"

echo ">>> packing desktop-pack.tar.gz"
tar czf "$OUT" -C "$ROOT" .
echo ">>> unpacked size: $(du -sh "$ROOT" | cut -f1)"
echo ">>> desktop pack written: $OUT ($(du -h "$OUT" | cut -f1))"
