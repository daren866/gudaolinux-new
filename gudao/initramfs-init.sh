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
# /dev/pts: PTY slave devices. devtmpfs alone does NOT provide them - the
# devpts filesystem must be mounted explicitly. Without it every terminal
# emulator (xfce4-terminal / VTE) fails with "Failed to open PTY: No such
# file or directory"; busybox ash keeps working only because it sits on
# /dev/console instead of a PTY.
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# --- apt pack: unpack the package manager at every boot ----------
# The system lives in RAM, so /opt/apt-pack.tar.gz is unpacked on boot
# (unlike the desktop pack which waits for the `desktop` command): apt
# should work headless from the very first shell prompt.
if [ -f /opt/apt-pack.tar.gz ] && [ ! -x /usr/bin/apt-get ]; then
    echo "gudao: unpacking package manager (apt)..."
    tar xzf /opt/apt-pack.tar.gz -C / \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/group \
        --exclude=etc/gudao-banner \
        || echo "gudao: WARNING - tar reported errors unpacking the apt pack"
    rm -f /opt/apt-pack.tar.gz   # free the RAM occupied by the archive
    # verify reality instead of assuming success: a silent partial unpack
    # used to masquerade as "apt ready" here
    if [ -x /usr/bin/apt-get ]; then
        echo "gudao: apt ready (sources: TUNA trixie + security.debian.org)"
    else
        echo "gudao: ERROR - /usr/bin/apt-get missing after unpack, apt unavailable"
    fi
    # apt fetch sandbox (user _apt) requirements, enforced at boot:
    # - /tmp world-writable, else gpgv mkstemp(/tmp/apt.sig.*) fails EACCES
    #   and every repo is declared "not signed" despite successful downloads
    # - _apt-owned lists/archives partial dirs, else downloads either fail
    #   or fall back to unsandboxed-root mode
    chmod 1777 /tmp 2>/dev/null
    mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial /var/log/apt
    chown -R _apt:_apt /var/lib/apt/lists /var/cache/apt/archives /var/log/apt 2>/dev/null
fi

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
# xfwm4 + xfce4-panel + xfdesktop + thunar + xfce4-terminal,
# verifies them and powers off
if grep -q 'gudao_desktoptest' /proc/cmdline 2>/dev/null; then
    echo "[desktop] launching desktop stack (unpack + Xorg + xfwm4 + panel + xfdesktop + thunar + xfce4-terminal)..."
    /usr/bin/desktop 2>&1
    echo "[desktop] launcher finished, checking processes..."
    sleep 5
    OK=1
    # Xorg: verify via its X11 unix socket (pgrep by name is unreliable -
    # Xorg rewrites its own process title; the running server + glxinfo
    # were proven working while pgrep -x "Xorg" still missed it)
    if [ -S /tmp/.X11-unix/X0 ]; then
        echo "[desktop] Xorg: running (socket /tmp/.X11-unix/X0 present)"
    else
        echo "[desktop] Xorg: NOT RUNNING (no X0 socket)"
        OK=0
    fi
    for p in xfwm4 xfce4-panel xfdesktop thunar xfce4-terminal; do
        if pgrep -x "$p" >/dev/null 2>&1; then
            echo "[desktop] $p: running"
        else
            echo "[desktop] $p: NOT RUNNING"
            OK=0
        fi
    done
    # the panel PROCESS can be alive while its window never shows - check
    # the real thing: a mapped xfce4-panel window on the root
    PWAIT=0
    while [ $PWAIT -lt 10 ]; do
        DISPLAY=:0 xwininfo -root -tree 2>/dev/null | grep -qi 'xfce4.panel' && break
        PWAIT=$((PWAIT+1))
        sleep 1
    done
    if DISPLAY=:0 xwininfo -root -tree 2>/dev/null | grep -qi 'xfce4.panel'; then
        echo "[desktop] PANEL WINDOW: PASS"
    else
        echo "[desktop] PANEL WINDOW: NOT MAPPED"
        OK=0
        echo "[desktop] xfce4-panel log tail:"
        tail -12 /var/log/xfce4-panel.log 2>/dev/null || true
        echo "[desktop] top-level windows:"
        DISPLAY=:0 xwininfo -root -tree 2>/dev/null | sed -n '3,12p' || true
    fi
    # GIO mime database (without it gdk-pixbuf cannot recognize ANY image
    # and GTK apps abort on the first icon load)
    if [ -f /usr/share/mime/mime.cache ]; then
        echo "[desktop] MIME database: OK"
    else
        echo "[desktop] MIME database: MISSING"
        OK=0
    fi
    # PTY support (devpts): xfce4-terminal cannot spawn a shell without it,
    # yet its process stays alive showing an error dialog - so the process
    # check above would still pass. Test the real thing: devpts mounted AND
    # /dev/ptmx openable.
    if grep -q 'devpts' /proc/mounts 2>/dev/null \
       && (exec 3<>/dev/ptmx) 2>/dev/null; then
        echo "[desktop] PTY (devpts): PASS"
    else
        echo "[desktop] PTY (devpts): FAIL (terminal emulators cannot open a pty)"
        echo "[desktop] /proc/mounts devpts line: $(grep devpts /proc/mounts 2>/dev/null || echo none)"
        echo "[desktop] /dev/ptmx: $(ls -la /dev/ptmx 2>/dev/null || echo MISSING)"
        OK=0
    fi
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

# --- CI apt self-test (kernel cmdline: gudao_apttest) ---------
# end-to-end package manager test against the REAL configured mirrors:
# apt-get update -> install 'ed' -> run it -> remove it -> power off
if grep -q 'gudao_apttest' /proc/cmdline 2>/dev/null; then
    if [ ! -x /usr/bin/apt-get ]; then
        echo "[apt] FAIL: apt-get not present (apt pack missing?)"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
    fi
    gudao_net_up
    echo "[apt] NET: $NET_IFACE $NET_IP"
    echo "[apt] apt-get update (TUNA trixie + security.debian.org)..."
    if apt-get update >/var/log/apt-update.log 2>&1; then
        echo "[apt] APT UPDATE: PASS ($(ls /var/lib/apt/lists/ 2>/dev/null | grep -c '_Packages$') indexes)"
    else
        echo "[apt] APT UPDATE: FAIL - log tail:"
        tail -15 /var/log/apt-update.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    echo "[apt] apt-get install ed (small editor, only libc dependency)..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ed >/var/log/apt-install.log 2>&1 \
       && dpkg -s ed >/dev/null 2>&1 && [ -x /usr/bin/ed ]; then
        echo "[apt] APT INSTALL: PASS ($(dpkg -s ed 2>/dev/null | grep '^Version:' | tr -d '\r'))"
    else
        echo "[apt] APT INSTALL: FAIL - log tail:"
        tail -15 /var/log/apt-install.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    R="$(printf 'a\nhello from apt\n.\np\n' | ed 2>/dev/null | tail -1)"
    if [ "$R" = "hello from apt" ]; then
        echo "[apt] APT RUN: PASS (ed executed: $R)"
    else
        echo "[apt] APT RUN: FAIL (ed output: $R)"
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    echo "[apt] apt-get remove ed..."
    if DEBIAN_FRONTEND=noninteractive apt-get remove -y ed >/var/log/apt-remove.log 2>&1 \
       && ! dpkg -s ed >/dev/null 2>&1; then
        echo "[apt] APT REMOVE: PASS"
    else
        echo "[apt] APT REMOVE: FAIL - log tail:"
        tail -15 /var/log/apt-remove.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    echo "[selftest] APT PASS"
    echo "APT TEST PASSED - Gudao package manager is alive!"
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
echo "  Extras : calc <expr>  |  about  |  desktop  |  apt install <pkg>"
echo "  Network: $NET_LINE"
echo "  System : live in RAM - nothing persists across reboot"
echo
exec setsid cttyhack sh
