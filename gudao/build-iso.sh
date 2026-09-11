#!/usr/bin/env bash
# ------------------------------------------------------------
# Build the Gudao Linux bootable ISO (GRUB, BIOS + UEFI hybrid)
# Requires: grub-mkrescue, xorriso, mtools, grub-pc-bin, grub-efi-amd64-bin
# ------------------------------------------------------------
set -euo pipefail

GUDAO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "$GUDAO_DIR/.." && pwd)"
KVER="$(make -s -C "$TOP_DIR" kernelversion)"
ISO="$TOP_DIR/gudao-linux-${KVER}.iso"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo ">>> Gudao Linux kernel version: $KVER"

mkdir -p "$STAGE/boot/grub"
cp "$TOP_DIR/vmlinuz-gudao"       "$STAGE/boot/vmlinuz-gudao"
cp "$TOP_DIR/initramfs-gudao.img" "$STAGE/boot/initramfs-gudao.img"
cp "$GUDAO_DIR/grub.cfg"          "$STAGE/boot/grub/grub.cfg"

grub-mkrescue -o "$ISO" "$STAGE" -- -volid GUDAOLINUX
echo ">>> ISO written: $ISO ($(du -h "$ISO" | cut -f1))"
