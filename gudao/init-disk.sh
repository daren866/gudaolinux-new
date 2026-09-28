#!/bin/sh
# ------------------------------------------------------------
# Gudao Linux disk-boot init (PID 1 on installed systems)
#
# Boot chain of an installed Gudao Linux:
#   GRUB -> kernel root=PARTUUID=... init=/sbin/init-gudao
#   (NO initramfs: the kernel mounts the ext4 root partition
#   directly - ext4 is built into the kernel - and this script
#   is the first userland process on the persistent system)
#
# The installer (install-to-disk) copies this file to
# /sbin/init-gudao on the target root filesystem.
# ------------------------------------------------------------

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

# kernel messages off the console (same as the live system)
/bin/busybox dmesg -n 3 2>/dev/null || true

/bin/busybox mkdir -p /proc /sys /dev /tmp /run /mnt /opt /var/log
/bin/busybox mount -t proc none /proc 2>/dev/null || true
/bin/busybox mount -t sysfs none /sys 2>/dev/null || true
# CONFIG_DEVTMPFS_MOUNT=y makes the kernel mount devtmpfs on /dev
# before starting init; keep the manual mount as a fallback anyway
if ! /bin/busybox mountpoint -q /dev 2>/dev/null; then
    /bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null \
        || /bin/busybox mdev -s 2>/dev/null || true
fi
# /dev/pts: PTY slaves for terminal emulators (xfce4-terminal/VTE);
# /dev/shm: POSIX shared memory for X11 (MIT-SHM) and GTK
/bin/busybox mkdir -p /dev/pts /dev/shm
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true
/bin/busybox mount -t tmpfs -o mode=1777 shm /dev/shm 2>/dev/null || true
/bin/busybox chmod 1777 /tmp 2>/dev/null || true
/bin/busybox hostname gudao 2>/dev/null || true

# --- network bring-up: DHCP + DNS 8.8.8.8 (same as live) ------
gudao_net_up() {
    NET_IFACE=""
    NET_IP=""
    mkdir -p /usr/share/udhcpc /etc
    cat > /usr/share/udhcpc/default.script <<'UDHCPEOF'
#!/bin/sh
case "$1" in
  deconfig)
    ifconfig "$interface" 0.0.0.0 up
    ;;
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up
    if [ -n "$router" ]; then
      while route del default dev "$interface" 2>/dev/null; do :; done
      for gw in $router; do
        route add default gw "$gw" dev "$interface" 2>/dev/null
      done
    fi
    : > /etc/resolv.conf
    for ns in $dns; do
      echo "nameserver $ns" >> /etc/resolv.conf
    done
    grep -q '^nameserver 8.8.8.8' /etc/resolv.conf 2>/dev/null \
      || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    ;;
esac
exit 0
UDHCPEOF
    chmod +x /usr/share/udhcpc/default.script

    for devpath in /sys/class/net/*; do
        iface="${devpath##*/}"
        [ "$iface" = "lo" ] && continue
        ifconfig "$iface" up 2>/dev/null
        if udhcpc -i "$iface" -s /usr/share/udhcpc/default.script \
                  -n -q -t 4 -T 2 >/dev/null 2>&1; then
            ipaddr="$(ip -4 addr show dev "$iface" 2>/dev/null \
                      | awk '/inet /{ print $2; exit }' | cut -d/ -f1)"
            [ -z "$ipaddr" ] && ipaddr="$(ifconfig "$iface" 2>/dev/null \
                      | awk '/inet addr:/{ print $2; exit }' | cut -d: -f2)"
            NET_IFACE="$iface"
            NET_IP="$ipaddr"
            break
        fi
    done

    if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
}
gudao_net_up

if [ -n "$NET_IFACE" ] && [ -n "$NET_IP" ]; then
    NET_LINE="$NET_IFACE  $NET_IP  (dhcp, dns 8.8.8.8)"
else
    NET_LINE="no DHCP lease (dns 8.8.8.8)"
fi

clear 2>/dev/null || true
cat /etc/gudao-banner 2>/dev/null || true
echo
echo "  Welcome to Gudao Linux (installed system)"
echo "  Kernel : $(uname -s) $(uname -r)"
echo "  Root   : persistent on disk (changes survive reboot)"
if [ -f /etc/gudao-install-stamp ]; then
    echo "  Install: $(head -1 /etc/gudao-install-stamp 2>/dev/null)"
fi
echo "  Shell  : busybox ash   (type 'help' to list all applets)"
echo "  Extras : calc <expr>  |  about  |  desktop  |  sound-init  |  apt install <pkg>"
echo "  Network: $NET_LINE"
echo "  System : INSTALLED SYSTEM OK - persistent root, nothing is thrown away"
echo
echo "  (this is PID 1; type 'exit' to restart the shell, 'desktop' starts the GUI)"
echo

# PID 1 loop: a shell exit must not take the whole system down
# (the live system execs a single shell; on disk we respawn)
while :; do
    setsid cttyhack sh
    echo
    echo "  shell session ended - respawning (PID 1)"
    echo
done
