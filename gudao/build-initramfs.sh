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
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,dev,tmp,mnt,root,run,usr/bin,usr/sbin}

cp "$BB" "$ROOT/bin/busybox"
chmod 755 "$ROOT/bin/busybox"

cp "$GUDAO_DIR/initramfs-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"

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
