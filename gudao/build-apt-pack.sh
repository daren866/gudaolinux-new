#!/usr/bin/env bash
# ------------------------------------------------------------
# Build the Gudao Linux apt pack.
# The package manager for the live system: apt + dpkg + Debian
# archive keyring + CA certificates, resolved from Debian trixie,
# unpacked into a small tarball embedded in the initramfs at
# /opt/apt-pack.tar.gz and unpacked at every boot by /init.
#
# The runtime sources point to TUNA (mirrors.tuna.tsinghua.edu.cn)
# as requested - see the sources.list shipped below. HTTPS needs
# ca-certificates (only a Recommends of apt, so listed explicitly);
# signature checks need gpgv + debian-archive-keyring.
# ------------------------------------------------------------
set -euo pipefail

TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$TOP_DIR/apt-pack.tar.gz"
# paths are overridable for local verification (CI uses the defaults)
APTROOT="${GUDAO_APTROOT:-/tmp/aptroot-apt}"
ROOT="${GUDAO_APT_ROOT:-/tmp/apt-root}"

PKGS=(
  # the package manager itself + its database
  apt
  apt-utils
  dpkg
  # InRelease signature verification (apt Depends, listed for clarity)
  gpgv
  debian-archive-keyring
  # HTTPS transport certificates (only a Recommends of apt - without
  # it every https:// mirror fails TLS verification)
  ca-certificates
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

echo ">>> shipping Gudao apt sources (TUNA trixie, traditional format)"
mkdir -p "$ROOT/etc/apt"
# NOTE: the traditional /etc/apt/sources.list only - do NOT also ship a
# DEB822 /etc/apt/sources.list.d/debian.sources, apt would read BOTH and
# every index would be downloaded twice.
cat > "$ROOT/etc/apt/sources.list" <<'EOF'
# Gudao Linux default apt sources (Tsinghua TUNA mirror)
# deb-src lines are commented to keep `apt update` fast - uncomment if needed
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main contrib non-free non-free-firmware

deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware

deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware

# security updates come from the official security host
deb https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
# deb-src https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo ">>> seeding the dpkg database skeleton (fresh system: no packages installed yet)"
mkdir -p "$ROOT/var/lib/dpkg/info" \
         "$ROOT/var/lib/dpkg/updates" \
         "$ROOT/var/lib/dpkg/alternatives" \
         "$ROOT/var/lib/dpkg/triggers" \
         "$ROOT/var/log/apt" \
         "$ROOT/var/cache/apt/archives/partial" \
         "$ROOT/var/lib/apt/lists/partial"
: > "$ROOT/var/lib/dpkg/status"
: > "$ROOT/var/lib/dpkg/available"

echo ">>> generating the CA bundle at build time"
# The ca-certificates deb no longer ships /etc/ssl/certs/ca-certificates.crt
# nor /etc/ca-certificates.conf - its postinst generates both via
# update-ca-certificates, which we cannot run when merely unpacking debs.
# Reproduce what it does, portable (no root needed):
#   1. conf  = all mozilla certs (the package default), relative paths
#   2. bundle = concat of the conf-listed certs
#   3. hash symlinks in /etc/ssl/certs via `openssl rehash`
mkdir -p "$ROOT/etc/ssl/certs" "$ROOT/usr/share/ca-certificates"
( cd "$ROOT/usr/share/ca-certificates" && ls mozilla/*.crt 2>/dev/null | sort ) \
  > "$ROOT/etc/ca-certificates.conf"
N=$(wc -l < "$ROOT/etc/ca-certificates.conf")
echo ">>> $N certificates enabled in /etc/ca-certificates.conf"
test -s "$ROOT/etc/ca-certificates.conf" || { echo "FAIL: no mozilla certs found"; exit 1; }
: > "$ROOT/etc/ssl/certs/ca-certificates.crt"
while IFS= read -r crt; do
  cat "$ROOT/usr/share/ca-certificates/$crt" >> "$ROOT/etc/ssl/certs/ca-certificates.crt"
done < "$ROOT/etc/ca-certificates.conf"
cp "$ROOT"/usr/share/ca-certificates/mozilla/*.crt "$ROOT/etc/ssl/certs/"
OPENSSL_BIN="$ROOT/usr/bin/openssl"
[ -x "$OPENSSL_BIN" ] || OPENSSL_BIN=openssl
( cd "$ROOT/etc/ssl/certs" && "$OPENSSL_BIN" rehash . >/dev/null 2>&1 ) || true
HASHN=$(ls "$ROOT/etc/ssl/certs" | grep -cE '^[0-9a-f]{8}\.' || true)
echo ">>> CA bundle: $(du -h "$ROOT/etc/ssl/certs/ca-certificates.crt" | cut -f1), $HASHN hash symlinks"

echo ">>> live-system policies"
# never auto-start services while packages are being installed
# (invoke-rc.d honours exit 101 as "action denied by policy")
mkdir -p "$ROOT/usr/sbin"
cat > "$ROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
# Gudao live system: do NOT start/stop services on package install/remove.
exit 101
EOF
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
# no systemd runs here; maintainer scripts of daemon packages call
# systemctl unconditionally - let them succeed so installs do not fail
cat > "$ROOT/usr/bin/systemctl" <<'EOF'
#!/bin/sh
# Gudao live system: systemd is not running. Pretend success so package
# maintainer scripts (postinst) do not fail. Service management is a no-op.
exit 0
EOF
chmod 755 "$ROOT/usr/bin/systemctl"

echo ">>> sanity checks"
test -f "$ROOT/usr/bin/apt-get"  || { echo "FAIL: apt-get missing";  exit 1; }
test -f "$ROOT/usr/bin/apt"      || { echo "FAIL: apt missing";      exit 1; }
test -f "$ROOT/usr/bin/dpkg"     || { echo "FAIL: dpkg missing";     exit 1; }
test -f "$ROOT/usr/bin/dpkg-deb" || { echo "FAIL: dpkg-deb missing"; exit 1; }
test -f "$ROOT/usr/bin/gpgv"     || { echo "FAIL: gpgv missing";     exit 1; }
test -f "$ROOT/usr/lib/apt/methods/https" \
  || { echo "FAIL: apt https method missing (https mirrors will not work!)"; exit 1; }
test -f "$ROOT/usr/share/keyrings/debian-archive-keyring.gpg" \
  || { echo "FAIL: debian archive keyring missing (apt update will fail signature check!)"; exit 1; }
test -s "$ROOT/etc/ssl/certs/ca-certificates.crt" \
  || { echo "FAIL: CA bundle missing or empty (TLS to mirrors will fail!)"; exit 1; }
test -s "$ROOT/etc/ca-certificates.conf" \
  || { echo "FAIL: ca-certificates.conf missing (update-ca-certificates would rebuild nothing)"; exit 1; }
test -f "$ROOT/etc/apt/sources.list" || { echo "FAIL: sources.list missing"; exit 1; }
grep -q 'mirrors.tuna.tsinghua.edu.cn/debian/ trixie main' "$ROOT/etc/apt/sources.list" \
  || { echo "FAIL: TUNA trixie entry missing in sources.list"; exit 1; }
grep -q 'trixie-security' "$ROOT/etc/apt/sources.list" \
  || { echo "FAIL: trixie-security entry missing in sources.list"; exit 1; }
test -f "$ROOT/etc/apt/sources.list.d/debian.sources" \
  && { echo "FAIL: DEB822 debian.sources present - would double every apt index!"; exit 1; } || true
echo ">>> apt/dpkg closure OK"

echo ">>> packing apt-pack.tar.gz"
# same usrmerge handling as the desktop pack: top-level ./bin and ./sbin
# symlinks collide with the busybox initramfs root - exclude them
tar czf "$OUT" -C "$ROOT" \
    --exclude='./bin' \
    --exclude='./sbin' \
    .
echo ">>> unpacked size: $(du -sh "$ROOT" | cut -f1)"
echo ">>> apt pack written: $OUT ($(du -h "$OUT" | cut -f1))"
