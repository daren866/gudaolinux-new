#!/bin/sh
# ------------------------------------------------------------
# Gudao Linux - "Install to disk"
#
# Installs the RUNNING live system onto a hard disk as a
# PERSISTENT system: partition -> format -> copy the complete
# live root (base + apt pack + desktop pack as currently
# unpacked) -> GRUB -> reboot from disk. Everything installed
# with apt afterwards survives reboots.
#
# Layout (chosen by the firmware this session runs under):
#   BIOS boot : MBR table, one ext4 root partition,
#               GRUB i386-pc embedded in the MBR gap
#   UEFI boot : GPT, ESP (512M FAT32, EFI/BOOT/BOOTX64.EFI
#               via grub-install --removable) + ext4 root
#
# The installed system boots WITHOUT an initramfs: the kernel
# mounts the ext4 root directly (root=PARTUUID=...,
# init=/sbin/init-gudao, ext4 is built in). The installer only
# needs the source medium to copy the kernel image from.
#
# Environment:
#   GUDAO_SOURCE_DIR  use this dir as the source tree (must
#                     contain boot/vmlinuz-gudao) instead of
#                     scanning CD/USB media
#
# Notes:
#   - the target disk is DESTROYED (interactive mode asks you
#     to type 'yes'; --auto does not ask: CI/automation only)
#   - Secure Boot must be OFF (the EFI binary is unsigned)
# ------------------------------------------------------------

B=/bin/busybox
TGT=/mnt/gudao-root
SRC=/mnt/gudao-src

say() { echo "install-to-disk: $*"; }
die() { echo "install-to-disk: ERROR - $*" >&2; exit 1; }

usage() {
cat <<'USAGE'
Install to disk - install the running Gudao Linux onto a hard disk
as a PERSISTENT system (apt installs and config changes survive reboot).

Usage:
  install-to-disk                     interactive: pick the target disk
  install-to-disk /dev/sdX            target given, still asks to confirm
  install-to-disk --auto /dev/sdX     NO prompts at all (CI/automation!)

Options:
  --target-uefi        install the UEFI layout (GPT + ESP) even when the
                       installer session runs BIOS-booted (CI override)
  --target-bios        force the BIOS layout (MBR + ext4)
  --serial-console     make the installed GRUB default entry use the
                       serial console (console=ttyS0) - CI/debug installs
  -h, --help           this help

The installer:
  1. finds the source medium (the ISO/USB the system booted from) to
     copy the kernel image from: CD-ROM, dd'ed USB stick, a FAT/ext4
     stick with the ISO contents, an ISO file on a disk (Ventoy), or
     /boot of a running installed system - QEMU: attach the ISO as -cdrom
  2. partitions the target disk (BIOS: MBR+ext4 / UEFI: GPT+ESP+ext4)
  3. formats it and copies the complete live system (base + apt pack +
     desktop pack as currently unpacked) onto the root partition
  4. installs GRUB (BIOS: i386-pc to the MBR gap; UEFI: x86_64-efi as
     EFI/BOOT/BOOTX64.EFI, no NVRAM dependency)
  5. writes /boot/grub/grub.cfg; the system boots without initramfs:
     kernel mounts ext4 root directly (root=PARTUUID, init=/sbin/init-gudao)

Minimum target size: 2 GB (8 GB recommended).
USAGE
exit 0
}

# ------------------------------------------------------------
# parse arguments
# ------------------------------------------------------------
TARGET=""
AUTO=0
FIRMWARE=""
SERIAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --auto)
            shift
            [ $# -gt 0 ] || die "--auto needs the target disk"
            [ -n "$TARGET" ] && die "target given twice"
            TARGET="$1"
            AUTO=1
            ;;
        --target-uefi) FIRMWARE=uefi ;;
        --target-bios) FIRMWARE=bios ;;
        --serial-console) SERIAL=1 ;;
        -h|--help) usage ;;
        --*|-*[a-zA-Z]*) die "unknown option: $1 (see --help)" ;;
        *)
            [ -n "$TARGET" ] && die "target disk given twice ('$TARGET' and '$1')"
            TARGET="$1"
            ;;
    esac
    shift
done

echo
echo "============================================================"
echo "  Gudao Linux - Install to disk"
echo "============================================================"
echo

[ "$(id -u)" = "0" ] || die "must run as root (the live system IS root; who dropped privileges?)"

# ------------------------------------------------------------
# firmware -> default layout
# ------------------------------------------------------------
if [ -z "$FIRMWARE" ]; then
    if [ -d /sys/firmware/efi ]; then
        FIRMWARE=uefi
    else
        FIRMWARE=bios
    fi
fi
say "install mode : $FIRMWARE (firmware detection)"
say "target system: persistent (survives reboot), boots without initramfs"

# ------------------------------------------------------------
# find the source medium (needs /boot/vmlinuz-gudao)
# ------------------------------------------------------------
SRC_KERNEL=""
SRC_DEV=""          # device the source was found on (excluded from targets)
SRC_DEV2=""         # extra mount to clean up (iso-scan loop mount)

# try_source DEV FS...: mount DEV read-only at $SRC trying each fs type
# and check the Gudao marker; on success leaves it mounted, returns 0.
# NOTE: use busybox mount, NOT the real util-linux mount: the live root
# is the initramfs (mounted MS_NOSUID), so util-linux's suid mount
# cannot take effect and refuses with "must be superuser" even as root;
# busybox mount needs no suid bit.
try_source() {
    _dev="$1"; shift
    for _fs in "$@"; do
        if $B mount -t "$_fs" -o ro "$_dev" "$SRC" 2>/dev/null; then
            if [ -f "$SRC/boot/vmlinuz-gudao" ]; then
                return 0
            fi
            $B umount "$SRC" 2>/dev/null || true
        fi
    done
    return 1
}

# block-device candidates: CD/DVD drives first, then whole disks and
# their partitions (dd'ed isohybrid sticks, ISOs attached as disks)
CANDS=""
for d in /sys/block/*; do
    dev="${d##*/}"
    case "$dev" in sr*) [ -b "/dev/$dev" ] && CANDS="$CANDS /dev/$dev" ;; esac
done
for d in /sys/block/*; do
    dev="${d##*/}"
    case "$dev" in
        loop*|ram*|zram*|fd*|md*|dm-*|nbd*|sr*) continue ;;
    esac
    [ -e "/dev/$dev" ] && CANDS="$CANDS /dev/$dev"
    for p in "$d"/*[0-9]; do
        [ -e "$p" ] || continue
        CANDS="$CANDS /dev/${p##*/}"
    done
done

if [ -n "$GUDAO_SOURCE_DIR" ] && [ -f "$GUDAO_SOURCE_DIR/boot/vmlinuz-gudao" ]; then
    SRC_KERNEL="$GUDAO_SOURCE_DIR/boot/vmlinuz-gudao"
    say "source: GUDAO_SOURCE_DIR=$GUDAO_SOURCE_DIR"
else
    mkdir -p "$SRC" /mnt/gudao-isoloop
    say "scanning for the Gudao source medium (ISO/USB)..."

    # 1) an already-mounted medium (the user mounted the ISO, or a boot
    #    flow that keeps the boot medium mounted) - /proc/mounts rows
    #    with a real device in field 1
    for _m in $(awk '$1 ~ /^\// {print $2}' /proc/mounts 2>/dev/null); do
        [ -f "$_m/boot/vmlinuz-gudao" ] || continue
        SRC_KERNEL="$_m/boot/vmlinuz-gudao"
        say "source: already-mounted medium at $_m"
        break
    done

    # 2) device scan: iso9660 (ISO/DVD/dd'ed isohybrid stick), then vfat
    #    and ext4 (a stick with the ISO CONTENTS copied onto it)
    if [ -z "$SRC_KERNEL" ]; then
        for c in $CANDS; do
            [ -b "$c" ] || continue
            if try_source "$c" iso9660 vfat ext4; then
                SRC_KERNEL="$SRC/boot/vmlinuz-gudao"
                SRC_DEV="$c"
                say "source medium: $c mounted at $SRC"
                break
            fi
        done
    fi

    # 3) iso-scan: the ISO FILE lying on a partition (Ventoy-style
    #    sticks, an ISO kept on the disk). Loop-mount every *.iso
    #    bigger than 100 MB and check the marker (needs CONFIG_BLK_DEV_LOOP).
    if [ -z "$SRC_KERNEL" ]; then
        for c in $CANDS; do
            [ -b "$c" ] || continue
            case "$c" in "$SRC_DEV") continue ;; esac
            for fs in vfat ext4 exfat iso9660; do
                $B umount "$SRC" 2>/dev/null || true
                $B mount -t "$fs" -o ro "$c" "$SRC" 2>/dev/null || continue
                for isofile in "$SRC"/*.iso "$SRC"/*.ISO; do
                    [ -f "$isofile" ] || continue
                    size_kb=$(( $(wc -c < "$isofile" 2>/dev/null || echo 0) / 1024 ))
                    [ "$size_kb" -lt 100000 ] && continue
                    if $B mount -o loop -t iso9660 "$isofile" /mnt/gudao-isoloop 2>/dev/null; then
                        if [ -f /mnt/gudao-isoloop/boot/vmlinuz-gudao ]; then
                            SRC_KERNEL=/mnt/gudao-isoloop/boot/vmlinuz-gudao
                            SRC_DEV="$c"
                            SRC_DEV2=/mnt/gudao-isoloop
                            say "source: $isofile (on $c) loop-mounted"
                            break 2
                        fi
                        $B umount /mnt/gudao-isoloop 2>/dev/null || true
                    fi
                done
                [ -n "$SRC_KERNEL" ] && break
            done
        done
        [ -n "$SRC_KERNEL" ] || $B umount "$SRC" 2>/dev/null || true
    fi

    # 4) still nothing: this may be an INSTALLED system being
    #    re-installed/repaired - take the kernel from the running root
    if [ -z "$SRC_KERNEL" ] && [ -f /boot/vmlinuz-gudao ]; then
        SRC_KERNEL=/boot/vmlinuz-gudao
        say "source: /boot/vmlinuz-gudao of the RUNNING system (installed-system reinstall)"
    fi

    # 5) nothing found anywhere: diagnostic dump, then die
    if [ -z "$SRC_KERNEL" ]; then
        echo "install-to-disk: SOURCE SCAN FAILED - block devices seen:" >&2
        for d in /sys/block/*; do
            dev="${d##*/}"
            case "$dev" in loop*|ram*|zram*) continue ;; esac
            sz512="$(cat "$d/size" 2>/dev/null || echo 0)"
            mb=$(( sz512 / 2048 ))
            echo "  /dev/$dev  ${mb} MB  $([ -b "/dev/$dev" ] && echo '(node ok)' || echo '(NO /dev NODE - driver missing?)')" >&2
        done
        echo "  cmdline: $(cat /proc/cmdline 2>/dev/null)" >&2
        die "no Gudao source medium found.
  The installer copies the kernel image from the medium the system
  booted from, so a Gudao ISO/USB must be visible to the machine.
  Fixes:
    QEMU          add:  -cdrom gudao-linux-*.iso   (then reboot the VM)
    real machine  boot the Gudao USB stick / DVD
    advanced      export GUDAO_SOURCE_DIR=<dir containing
                  boot/vmlinuz-gudao> and re-run install-to-disk"
    fi
fi
[ -n "$SRC_KERNEL" ] || die "internal error: source scan ended without a source"
say "source kernel: $SRC_KERNEL"

# ------------------------------------------------------------
# make sure the installer tools are present (desktop pack)
# ------------------------------------------------------------
TOOLS_OK=1
for t in /usr/sbin/sfdisk /usr/sbin/mkfs.ext4 /usr/sbin/mkfs.vfat /usr/sbin/grub-install; do
    [ -x "$t" ] || TOOLS_OK=0
done
if [ "$TOOLS_OK" = "0" ]; then
    say "installer tools missing (sfdisk/mkfs/grub live in the desktop pack)"
    if [ -x /usr/bin/desktop ] && [ -f /opt/desktop-pack.tar.gz ]; then
        say "unpacking the desktop pack (desktop unpack-only, no X)..."
        /usr/bin/desktop unpack-only || die "desktop pack unpack failed"
    fi
    for t in /usr/sbin/sfdisk /usr/sbin/mkfs.ext4 /usr/sbin/mkfs.vfat /usr/sbin/grub-install; do
        [ -x "$t" ] || die "$t still missing - this build has no desktop pack with installer tools"
    done
fi
say "installer tools: sfdisk/mkfs.ext4/mkfs.vfat/grub-install OK"

GRUB_TARGET_OK=1
if [ "$FIRMWARE" = "uefi" ]; then
    [ -d /usr/lib/grub/x86_64-efi ] || GRUB_TARGET_OK=0
else
    [ -d /usr/lib/grub/i386-pc ] || GRUB_TARGET_OK=0
fi
[ "$GRUB_TARGET_OK" = "1" ] || die "GRUB platform modules for $FIRMWARE missing from the desktop pack (grub-pc-bin / grub-efi-amd64-bin)"

# ------------------------------------------------------------
# enumerate candidate target disks
# ------------------------------------------------------------
# src_disk(): reduce a device (possibly a partition) to its disk
src_disk() {
    _sd="$1"
    while :; do
        case "$_sd" in *[0-9]) _sd="${_sd%?}" ;; *) break ;; esac
    done
    case "$_sd" in *nvme*|*mmcblk*) _sd="${_sd%p}" ;; esac
    echo "$_sd"
}
# part_of DISK N: partition N of DISK (nvme/mmcblk use pN)
part_of() {
    _d="$1"; _n="$2"
    case "$_d" in
        *nvme*|*mmcblk*) echo "${_d}p${_n}" ;;
        *) echo "${_d}${_n}" ;;
    esac
}

# disks that must NEVER be offered as targets:
#   SRC_DISK - the medium the source kernel came from (a dd'ed USB stick
#              is a perfectly sized "target" and would destroy the boot
#              medium mid-install)
#   RUN_DISK - the disk the RUNNING system itself boots from (an
#              installed-system reinstall must not eat its own root)
#              resolved from root= in /proc/cmdline (PARTUUID against
#              the partition uevents, or a plain /dev path)
RUN_DISK=""
for w in $(cat /proc/cmdline 2>/dev/null); do
    case "$w" in
        root=PARTUUID=*)
            _pu="${w#root=PARTUUID=}"
            for pue in /sys/block/*/*/uevent; do
                [ -f "$pue" ] || continue
                grep -q "^PARTUUID=$_pu\$" "$pue" 2>/dev/null || continue
                _pn="${pue%/*}"; _pn="${_pn##*/}"       # partition (sda2)
                _dn="${pue%/*/*}"; _dn="${_dn##*/}"     # disk     (sda)
                RUN_DISK="/dev/$_dn"
                break
            done
            ;;
        root=/dev/*) RUN_DISK="/dev/$(src_disk "${w#root=/dev/}")" ;;
    esac
    [ -n "$RUN_DISK" ] && break
done
SRC_DISK=""
[ -n "$SRC_DEV" ] && SRC_DISK="/dev/$(src_disk "${SRC_DEV##*/}")"
say "excluded from targets: source=${SRC_DISK:-none} running-root=${RUN_DISK:-none}"

disk_list=""
i=0
for d in /sys/block/*; do
    dev="${d##*/}"
    case "$dev" in
        loop*|ram*|zram*|fd*|md*|dm-*|nbd*|sr*) continue ;;
    esac
    [ -b "/dev/$dev" ] || continue
    [ "/dev/$dev" = "$SRC_DISK" ] && continue
    [ "/dev/$dev" = "$RUN_DISK" ] && continue
    sz512="$(cat "$d/size" 2>/dev/null || echo 0)"
    mb=$(( sz512 / 2048 ))
    [ "$mb" -lt 1900 ] && continue   # need room for the system copy
    model="$(cat "$d/device/model" 2>/dev/null | tr -s ' ' || true)"
    i=$(( i+1 ))
    echo "  $i) /dev/$dev   ${mb} MB   $model"
    disk_list="$disk_list /dev/$dev"
done

if [ "$i" -eq 0 ]; then
    die "no suitable target disk found (>=2 GB, not the source medium).
  QEMU: attach one:  -drive file=disk.raw,if=virtio,format=raw"
fi

# ------------------------------------------------------------
# pick + verify the target
# ------------------------------------------------------------
if [ -n "$TARGET" ]; then
    FOUND=0
    for dl in $disk_list; do
        [ "$dl" = "$TARGET" ] && FOUND=1
    done
    [ "$FOUND" = "1" ] || die "$TARGET is not a valid target disk (candidates:$disk_list)"
else
    printf 'target disk number [1-%s]: ' "$i"
    read ANS
    n=0
    TARGET=""
    for dl in $disk_list; do
        n=$(( n+1 ))
        [ "$n" = "$ANS" ] && TARGET="$dl"
    done
    [ -n "$TARGET" ] || die "invalid selection: $ANS"
fi
say "target disk: $TARGET"

# ------------------------------------------------------------
# confirm (interactive modes only)
# ------------------------------------------------------------
if [ "$AUTO" != "1" ]; then
    echo
    echo "  THIS WILL DESTROY ALL DATA ON $TARGET"
    echo "  layout: $([ "$FIRMWARE" = "uefi" ] && echo 'GPT: ESP 512M (FAT32) + ext4 root' || echo 'MBR: one ext4 root partition')"
    echo "  then the live system (incl. everything installed this session)"
    echo "  is copied to it, and GRUB is installed for $FIRMWARE boot."
    echo
    printf "  type 'yes' to continue (anything else aborts): "
    read CONFIRM
    [ "$CONFIRM" = "yes" ] || { say "aborted (nothing was written)"; exit 1; }
fi

# ------------------------------------------------------------
# [1/6] partition
# ------------------------------------------------------------
say "[1/6] partitioning $TARGET ($FIRMWARE layout)..."
/usr/sbin/wipefs -a "$TARGET" >/dev/null 2>&1 || true
if [ "$FIRMWARE" = "uefi" ]; then
    /usr/sbin/sfdisk --force "$TARGET" >/tmp/sfdisk.log 2>&1 <<'PARTS'
label: gpt
2048,1048576,U,*
,,L,*
PARTS
else
    /usr/sbin/sfdisk --force "$TARGET" >/tmp/sfdisk.log 2>&1 <<'PARTS'
label: dos
2048,,83,*
PARTS
fi
[ $? -eq 0 ] || { cat /tmp/sfdisk.log >&2; die "sfdisk failed on $TARGET"; }
/usr/bin/partx -u "$TARGET" >/dev/null 2>&1 || true
sleep 1
PART1="$(part_of "$TARGET" 1)"
PART2="$(part_of "$TARGET" 2)"
if [ "$FIRMWARE" = "uefi" ]; then
    [ -b "$PART1" ] || die "$PART1 did not appear after partitioning"
    [ -b "$PART2" ] || die "$PART2 did not appear after partitioning"
    PART_ROOT="$PART2"
else
    [ -b "$PART1" ] || die "$PART1 did not appear after partitioning"
    PART_ROOT="$PART1"
fi
say "      partitions ready: $([ "$FIRMWARE" = "uefi" ] && echo "$PART1 (ESP) $PART2 (root)" || echo "$PART1 (root)")"

# ------------------------------------------------------------
# [2/6] format
# ------------------------------------------------------------
say "[2/6] formatting..."
if [ "$FIRMWARE" = "uefi" ]; then
    /usr/sbin/mkfs.vfat -F 32 -n GUDAO "$PART1" >/tmp/mkfs-esp.log 2>&1 \
        || { cat /tmp/mkfs-esp.log >&2; die "mkfs.vfat failed on $PART1"; }
fi
/usr/sbin/mkfs.ext4 -F -q -L gudao-root "$PART_ROOT" >/tmp/mkfs-root.log 2>&1 \
    || { cat /tmp/mkfs-root.log >&2; die "mkfs.ext4 failed on $PART_ROOT"; }
say "      ext4 root on $PART_ROOT $([ "$FIRMWARE" = "uefi" ] && echo "+ FAT32 ESP on $PART1")"

# ------------------------------------------------------------
# [3/6] mount + copy the live system
# ------------------------------------------------------------
say "[3/6] copying the live system to $PART_ROOT (a few minutes)..."
mkdir -p "$TGT"
# busybox mount again (see the note at the source-medium scan: the
# initramfs rootfs is NOSUID, util-linux's suid mount refuses to work)
$B mount -t ext4 "$PART_ROOT" "$TGT" \
    || die "cannot mount $PART_ROOT at $TGT (busybox mount: $?)"
if [ "$FIRMWARE" = "uefi" ]; then
    mkdir -p "$TGT/boot/efi"
    $B mount -t vfat "$PART1" "$TGT/boot/efi" \
        || die "cannot mount ESP $PART1 (busybox mount: $?)"
fi
# exclude the pseudo-fs mounts, the mountpoints themselves, the pack
# archives (their CONTENT is already in the live root), transient apt
# state and the initramfs init script (the installed system boots with
# init=/sbin/init-gudao instead)
$B tar -cf - -C / \
    --exclude=./proc \
    --exclude=./sys \
    --exclude=./dev \
    --exclude=./run \
    --exclude=./tmp \
    --exclude=./mnt \
    --exclude=./media \
    --exclude=./opt \
    --exclude=./init \
    --exclude=./lost+found \
    --exclude=./var/cache/apt \
    --exclude=./var/lib/apt/lists \
    --exclude=./var/log \
    . 2>/tmp/tar-out.log | $B tar -xf - -C "$TGT" 2>/tmp/tar-in.log \
    || { echo "tar out: $(tail -3 /tmp/tar-out.log)" >&2; echo "tar in:  $(tail -3 /tmp/tar-in.log)" >&2; die "system copy failed"; }
# recreate the excluded directories (+ empty apt/log state)
for dd in proc sys dev run tmp mnt media opt boot var/log \
          var/lib/apt/lists/partial var/cache/apt/archives/partial root; do
    mkdir -p "$TGT/$dd"
done
chmod 1777 "$TGT/tmp"
# unpack any pack archives that never got unpacked this session
# (normally none: the apt pack unpacks at boot, the desktop pack just
# before this installer ran) - same excludes as the boot-time unpack
for pk in /opt/*.tar.gz; do
    [ -f "$pk" ] || continue
    say "      unpacking $(basename "$pk") onto the target..."
    $B tar xzf "$pk" -C "$TGT" \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/group \
        --exclude=etc/gudao-banner \
        || die "unpacking $pk onto the target failed"
done
# static /dev nodes: the kernel needs /dev/console on the root fs to
# attach init stdio BEFORE devtmpfs gets mounted (devtmpfs later
# shadows them)
mknod -m 600 "$TGT/dev/console" c 5 1 || die "mknod console failed"
mknod -m 666 "$TGT/dev/null"    c 1 3 || die "mknod null failed"
# sanity: the copied root must contain the essentials
for f in usr/bin/busybox bin usr/lib/gudao/init-disk etc/apt/sources.list; do
    [ -e "$TGT/$f" ] || die "copy is incomplete: $TGT/$f missing"
done
say "      copied: $(du -sh "$TGT" 2>/dev/null | cut -f1)"

# ------------------------------------------------------------
# [4/6] init, stamp, fstab, kernel
# ------------------------------------------------------------
say "[4/6] installing init-gudao (PID 1), fstab and kernel..."
cp /usr/lib/gudao/init-disk "$TGT/sbin/init-gudao" \
    || die "cannot install /sbin/init-gudao"
chmod 755 "$TGT/sbin/init-gudao"

STAMP="installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ') target=$TARGET firmware=$FIRMWARE kernel=$(uname -r)"
echo "$STAMP" > "$TGT/etc/gudao-install-stamp"

# fstab: informational (the kernel mounts / directly); keeps the
# layout self-documenting for later tools
ROOT_UUID="$(/usr/sbin/blkid -s UUID -o value "$PART_ROOT" 2>/dev/null)"
[ -n "$ROOT_UUID" ] || ROOT_UUID="$($B blkid "$PART_ROOT" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')"
{
    echo "# Gudao Linux (installed $(date -u '+%Y-%m-%d'))"
    if [ -n "$ROOT_UUID" ]; then
        echo "UUID=$ROOT_UUID  /      ext4  defaults        0 1"
    else
        echo "$PART_ROOT       /      ext4  defaults        0 1"
    fi
    if [ "$FIRMWARE" = "uefi" ]; then
        ESP_UUID="$(/usr/sbin/blkid -s UUID -o value "$PART1" 2>/dev/null)"
        [ -n "$ESP_UUID" ] && echo "UUID=$ESP_UUID  /boot/efi vfat defaults        0 2"
    fi
} > "$TGT/etc/fstab"

mkdir -p "$TGT/boot"
cp "$SRC_KERNEL" "$TGT/boot/vmlinuz-gudao" || die "cannot copy the kernel to the target"
$B sync

# ------------------------------------------------------------
# [5/6] GRUB
# ------------------------------------------------------------
say "[5/6] installing GRUB ($FIRMWARE)..."
# PARTUUID of the root partition: readable by the kernel without any
# initramfs (unlike filesystem UUIDs), stable across device renaming.
# NOTE: there is NO sysfs partuuid attribute in modern kernels - the
# kernel publishes the partition UUID in the uevent environment
# (block/partitions/core.c: PARTUUID=<uuid> from bd_meta_info), and
# early_lookup_bdev() resolves root=PARTUUID= against exactly that
# value. Read it back from the uevent file - same source, same format.
PART_BASE="${PART_ROOT##*/}"
DISK_BASE="$(src_disk "$PART_BASE")"
UEVENT="/sys/block/$DISK_BASE/$PART_BASE/uevent"
PARTUUID="$(sed -n 's/^PARTUUID=//p' "$UEVENT" 2>/dev/null)"
# fallback: util-linux blkid reads the table directly; normalise to the
# kernel's format (MSDOS form is SSSSSSSS-PP, no 0x prefix, lowercase
# hex). NOTE the explicit /usr/sbin path: bare `blkid` resolves to the
# busybox APPLET (/bin first in PATH), which does not understand
# -s/-o and would dump its whole "dev: LABEL=... UUID=... TYPE=..."
# line into the kernel cmdline.
if [ -z "$PARTUUID" ] && [ -x /usr/sbin/blkid ]; then
    PARTUUID="$(/usr/sbin/blkid -s PARTUUID -o value "$PART_ROOT" 2>/dev/null | sed 's/^0x//' | tr 'A-F' 'a-f')"
fi
if [ -z "$PARTUUID" ]; then
    say "      debug: $UEVENT = [$(cat "$UEVENT" 2>/dev/null | tr '\n' '|')]"
fi
if [ -n "$PARTUUID" ]; then
    ROOTPARAM="root=PARTUUID=$PARTUUID"
else
    ROOTPARAM="root=$PART_ROOT"
    say "      WARNING: PARTUUID not readable, using $ROOTPARAM (device names may shift)"
fi
mkdir -p "$TGT/boot/grub"

GRUB_SERIAL_LINE="console=ttyS0,115200n8"
write_entry() {
    _title="$1"; _extra="$2"
    if [ -n "$_extra" ]; then
        printf 'menuentry "%s" {\n    linux /boot/vmlinuz-gudao %s rootfstype=ext4 rw init=/sbin/init-gudao %s\n}\n\n' \
            "$_title" "$ROOTPARAM" "$_extra"
    else
        printf 'menuentry "%s" {\n    insmod all_video\n    set gfxpayload=1024x768x32,1024x768,auto\n    linux /boot/vmlinuz-gudao %s rootfstype=ext4 rw init=/sbin/init-gudao quiet loglevel=3\n}\n\n' \
            "$_title" "$ROOTPARAM"
    fi
}
{
    echo "# Gudao Linux - GRUB config (written by install-to-disk)"
    echo "set default=0"
    echo "set timeout=3"
    echo
    if [ "$SERIAL" = "1" ]; then
        # serial-first: CI / headless installs see the boot on ttyS0
        write_entry "Gudao Linux (serial console)" "console=tty0 $GRUB_SERIAL_LINE"
        write_entry "Gudao Linux (display only)" ""
    else
        write_entry "Gudao Linux (display only)" ""
        write_entry "Gudao Linux (kernel log + serial console)" "console=tty0 $GRUB_SERIAL_LINE"
    fi
} > "$TGT/boot/grub/grub.cfg"

if [ "$FIRMWARE" = "uefi" ]; then
    /usr/sbin/grub-install --target=x86_64-efi \
        --efi-directory="$TGT/boot/efi" \
        --boot-directory="$TGT/boot" \
        --removable --no-nvram >/tmp/grub-install.log 2>&1 \
        || { cat /tmp/grub-install.log >&2; die "grub-install (x86_64-efi) failed"; }
    [ -f "$TGT/boot/efi/EFI/BOOT/BOOTX64.EFI" ] \
        || die "grub-install did not produce EFI/BOOT/BOOTX64.EFI"
    say "      EFI/BOOT/BOOTX64.EFI on the ESP + modules in /boot/grub/x86_64-efi"
else
    /usr/sbin/grub-install --target=i386-pc \
        --boot-directory="$TGT/boot" \
        "$TARGET" >/tmp/grub-install.log 2>&1 \
        || { cat /tmp/grub-install.log >&2; die "grub-install (i386-pc) failed"; }
    [ -f "$TGT/boot/grub/i386-pc/boot.img" ] \
        || die "grub-install did not stage the i386-pc modules"
    say "      GRUB embedded in the MBR of $TARGET + modules in /boot/grub/i386-pc"
fi

# ------------------------------------------------------------
# [6/6] finish
# ------------------------------------------------------------
say "[6/6] unmounting + sync..."
if [ "$FIRMWARE" = "uefi" ]; then
    $B umount "$TGT/boot/efi" 2>/dev/null || true
fi
$B umount "$TGT" || die "cannot unmount $TGT (something still holds it open)"
[ -n "$GUDAO_SOURCE_DIR" ] || $B umount "$SRC" 2>/dev/null || true
[ -n "$SRC_DEV2" ] && $B umount "$SRC_DEV2" 2>/dev/null || true
$B sync

echo
echo "============================================================"
echo "  Gudao Linux installed to $TARGET"
echo "  layout : $([ "$FIRMWARE" = "uefi" ] && echo "GPT + ESP(512M) + ext4 root" || echo "MBR + ext4 root")"
echo "  boot   : GRUB ($FIRMWARE), kernel from /boot, init=/sbin/init-gudao"
echo "  system : $STAMP"
echo
echo "  Reboot now and remove the ISO/USB - the machine boots"
echo "  Gudao Linux from disk. Everything you install with apt"
echo "  persists from now on."
echo "============================================================"
exit 0
