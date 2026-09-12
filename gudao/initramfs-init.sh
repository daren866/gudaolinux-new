#!/bin/busybox sh
# ------------------------------------------------------------
# Gudao Linux - initramfs init
# Terminal : busybox ash
# Keyboard : AT/PS2 (i8042) + USB HID (built into the kernel)
# ------------------------------------------------------------

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

/bin/busybox --install -s /bin 2>/dev/null

# keep the console quiet at runtime too (only KERN_ERR and worse)
dmesg -n 3 2>/dev/null || true

mkdir -p /proc /sys /dev /tmp /mnt /root
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# --- CI self-test (kernel cmdline: gudao_selftest) -----------
# boots, runs the Gudao applets, prints markers and powers off
if grep -q 'gudao_selftest' /proc/cmdline 2>/dev/null; then
    r="$(calc '2*(2+2)' 2>&1)"
    echo "[selftest] calc 2*(2+2) = $r"
    if [ "$r" = "8" ]; then
        echo "[selftest] CALC PASS"
    else
        echo "[selftest] CALC FAIL"
    fi
    echo "[selftest] --- about ---"
    about
    echo "[selftest] --- end ---"
    if [ "$r" = "8" ]; then
        echo "[selftest] ALL PASSED"
        echo "BOOT TEST PASSED - Gudao Linux is alive!"
    else
        echo "[selftest] FAILED"
    fi
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    sleep 5
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
fi

clear
cat /etc/gudao-banner
echo
echo "  Welcome to Gudao Linux"
echo "  Kernel : $(uname -s) $(uname -r)"
echo "  Shell  : busybox ash   (type 'help' to list all applets)"
echo "  Extras : calc <expr>  |  about   (Gudao built-in commands)"
echo "  System : live in RAM - nothing persists across reboot"
echo
exec setsid cttyhack sh
