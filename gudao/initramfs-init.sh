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

mkdir -p /proc /sys /dev /tmp /mnt /root /run /opt /var/log /var/lib/dbus /var/lib/xkb /var/cache
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s
# /dev/shm: POSIX shared memory, needed by X11 (MIT-SHM) and GTK
mount -t tmpfs -o mode=1777 shm /dev/shm 2>/dev/null || true

# --- network bring-up: e1000 NIC + DHCP + DNS 8.8.8.8 ---------
# The e1000/e1000e driver is built into the kernel, so the NIC
# shows up as eth0 automatically. udhcpc asks a DHCP server for
# an IP, applies it via the hook script below and sets DNS.
gudao_net_up() {
    NET_IFACE=""
    NET_IP=""
    mkdir -p /usr/share/udhcpc /etc
    cat > /usr/share/udhcpc/default.script <<'UDHCPEOF'
#!/bin/sh
# udhcpc event hook - applies the DHCP lease to the interface
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
    # Gudao: keep 8.8.8.8 as a guaranteed resolver
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
        # -n: fail if no lease  -q: quit once leased  bounded retries
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

    # DNS 8.8.8.8 must always be set, even when DHCP failed
    if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
}

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
    echo "[selftest] --- network (e1000 + dhcp) ---"
    gudao_net_up
    NET_OK=0
    if [ -n "$NET_IFACE" ] && [ -n "$NET_IP" ]; then
        echo "[selftest] NET PASS ($NET_IFACE $NET_IP)"
        NET_OK=1
    else
        echo "[selftest] NET FAIL"
    fi
    if grep -q '^nameserver 8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo "[selftest] DNS PASS (8.8.8.8)"
    else
        echo "[selftest] DNS FAIL"
        NET_OK=0
    fi
    if [ "$r" = "8" ] && [ "$NET_OK" = "1" ]; then
        echo "[selftest] ALL PASSED"
        echo "BOOT TEST PASSED - Gudao Linux is alive!"
    else
        echo "[selftest] FAILED"
    fi
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    sleep 5
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
fi

# --- CI desktop self-test (kernel cmdline: gudao_desktoptest) ----
# unpacks the desktop pack, starts Xorg (Mesa CPU rendering) +
# xfwm4 + xfce4-panel + pcmanfm + lxterminal, verifies them and
# powers off
if grep -q 'gudao_desktoptest' /proc/cmdline 2>/dev/null; then
    echo "[desktop] launching desktop stack (unpack + Xorg + xfwm4 + panel + pcmanfm + lxterminal)..."
    /usr/bin/desktop 2>&1
    echo "[desktop] launcher finished, checking processes..."
    sleep 5
    OK=1
    for p in Xorg xfwm4 xfce4-panel pcmanfm lxterminal; do
        if pgrep -x "$p" >/dev/null 2>&1; then
            echo "[desktop] $p: running"
        else
            echo "[desktop] $p: NOT RUNNING"
            OK=0
        fi
    done
    if DISPLAY=:0 glxinfo -B 2>/dev/null | grep -qiE 'llvmpipe|softpipe|swrast'; then
        echo "[desktop] MESA CPU RENDER (llvmpipe): PASS"
    else
        echo "[desktop] MESA CPU RENDER: FAIL"
        OK=0
        echo "[desktop] glxinfo output:"
        DISPLAY=:0 glxinfo -B 2>&1 | head -20
    fi
    echo "[desktop] Xorg log tail:"
    tail -8 /var/log/Xorg.0.log 2>/dev/null || true
    if [ "$OK" = "1" ]; then
        echo "[selftest] DESKTOP PASS"
        echo "DESKTOP TEST PASSED - Gudao Linux GUI is alive!"
    else
        echo "[selftest] DESKTOP FAILED"
    fi
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    sleep 5
    poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
fi

# bring the network up before the shell appears (DHCP + DNS 8.8.8.8)
gudao_net_up

if [ -n "$NET_IFACE" ] && [ -n "$NET_IP" ]; then
    NET_LINE="$NET_IFACE  $NET_IP  (dhcp, dns 8.8.8.8)"
else
    NET_LINE="no DHCP lease (dns 8.8.8.8)"
fi

clear
cat /etc/gudao-banner
echo
echo "  Welcome to Gudao Linux"
echo "  Kernel : $(uname -s) $(uname -r)"
echo "  Shell  : busybox ash   (type 'help' to list all applets)"
echo "  Extras : calc <expr>  |  about   |  desktop   (Gudao built-in commands)"
echo "  Network: $NET_LINE"
echo "  System : live in RAM - nothing persists across reboot"
echo
exec setsid cttyhack sh
