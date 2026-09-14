#!/bin/busybox sh
# ------------------------------------------------------------
# Gudao Linux - initramfs init
# Terminal : busybox ash
# Keyboard : AT/PS2 (i8042) + USB HID (built into the kernel)
# ------------------------------------------------------------

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

# ---------------------------------------------------------------
# merged-usr boot order (CRITICAL - do not reorder):
#   1. mounts + apt-pack unpack, all via explicit /bin/busybox calls
#   2. THEN install the busybox applets into /bin
# The root is merged-usr (/bin -> usr/bin), so installing applets
# means writing into /usr/bin - the SAME directory the packs fill
# with real Debian binaries. Installing applets before the unpack
# would leave symlinks in the way: busybox tar extracting a regular
# file over an applet symlink would follow the link and clobber
# /usr/bin/busybox itself. Applets are installed LAST; real files
# from the packs always win (the installer skips existing paths).
# ---------------------------------------------------------------

# keep the console quiet at runtime too (only KERN_ERR and worse)
/bin/busybox dmesg -n 3 2>/dev/null || true

/bin/busybox mkdir -p /proc /sys /dev /tmp /mnt /root /run /opt /var/log /var/lib/dbus /var/lib/xkb /var/cache
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || /bin/busybox mdev -s
# /dev/shm: POSIX shared memory, needed by X11 (MIT-SHM) and GTK
/bin/busybox mount -t tmpfs -o mode=1777 shm /dev/shm 2>/dev/null || true
# /dev/pts: PTY slave devices. devtmpfs alone does NOT provide them - the
# devpts filesystem must be mounted explicitly. Without it every terminal
# emulator (xfce4-terminal / VTE) fails with "Failed to open PTY: No such
# file or directory"; busybox ash keeps working only because it sits on
# /dev/console instead of a PTY.
/bin/busybox mkdir -p /dev/pts
/bin/busybox mount -t devpts devpts /dev/pts 2>/dev/null || true

# merged-usr sanity: dpkg and apt 3.x refuse an unmerged usr (and a
# runtime-installed usrmerge package would fail to configure, taking
# whole install transactions down with it). Fail loudly at boot if the
# four root symlinks are not exactly the layout the packs expect.
for l in bin sbin lib lib64; do
    [ -L "/$l" ] \
        || echo "gudao: ERROR - /$l is not a symlink into /usr (merged-usr layout broken; package installs WILL fail)"
done

# --- apt pack: unpack the package manager at every boot ----------
# The system lives in RAM, so /opt/apt-pack.tar.gz is unpacked on boot
# (unlike the desktop pack which waits for the `desktop` command): apt
# should work headless from the very first shell prompt.
if [ -f /opt/apt-pack.tar.gz ] && [ ! -x /usr/bin/apt-get ]; then
    echo "gudao: unpacking package manager (apt)..."
    /bin/busybox tar xzf /opt/apt-pack.tar.gz -C / \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/group \
        --exclude=etc/gudao-banner \
        || echo "gudao: WARNING - tar reported errors unpacking the apt pack"
    /bin/busybox rm -f /opt/apt-pack.tar.gz   # free the RAM occupied by the archive
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
    /bin/busybox chmod 1777 /tmp 2>/dev/null
    /bin/busybox mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial /var/log/apt
    /bin/busybox chown -R _apt:_apt /var/lib/apt/lists /var/cache/apt/archives /var/log/apt 2>/dev/null
fi

# ---- install the busybox applets (AFTER the packs unpacked) --------
# /bin is a symlink to usr/bin on the merged-usr root, so this fills
# /usr/bin with applet symlinks - skipping every path that already has a
# real file from a pack (real binaries always win; e.g. the real dpkg,
# tar, awk ... from Debian replace their busybox counterparts, which is
# exactly what a merged system wants). A disabled dpkg applet
# (CONFIG_DPKG=n in the busybox build) additionally guarantees the real
# /usr/bin/dpkg can never be shadowed by a busybox lookalike.
for a in $(/bin/busybox --list); do
    [ -e "/bin/$a" ] || /bin/busybox ln -sf busybox "/bin/$a"
done

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
    # SOUND: the virtual sound cards are built into the kernel (Intel HDA
    # for QEMU/VBox HD-Audio/VMware, ICH AC97 for VirtualBox/QEMU, Ensoniq
    # ES1370/1371 for VMware/QEMU). Verify the card enumerates AND a test
    # wav actually plays through the ALSA stack.
    # NOTE: never use [ -s /proc/... ] here - procfs files ALWAYS report
    # st_size 0, so the check would fail even with the card fully up.
    # And an empty card list still prints the literal "--- no soundcards ---",
    # so grep for a REAL card line ("  0 [Intel  ]: HDA-Intel - ...") instead.
    # The codec probe is an async workqueue, so give it a moment.
    SWAIT=0
    while [ $SWAIT -lt 15 ]; do
        grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null && break
        SWAIT=$((SWAIT+1))
        sleep 1
    done
    if grep -qE '^ *[0-9]+ \[' /proc/asound/cards 2>/dev/null; then
        echo "[desktop] SOUND CARD: PASS ($(sed -n '1p' /proc/asound/cards | sed 's/^ *//' | tr -s ' '))"
    else
        echo "[desktop] SOUND CARD: FAIL (no card listed in /proc/asound/cards)"
        echo "[desktop] /proc/asound: $(ls /proc/asound/ 2>/dev/null | tr '\n' ' ')"
        OK=0
    fi
    if [ -x /usr/bin/aplay ] && [ -f /usr/share/sounds/alsa/Front_Center.wav ]; then
        # shared mixer init (unmute + sane levels) - the very same script
        # the desktop session backgrounds at startup, so CI verifies what
        # real users get; a codec without the expected controls only draws
        # a WARNING - what counts is the playback assertion below
        /usr/bin/sound-init || true
        if amixer get Master 2>/dev/null | grep -q '\[on\]'; then
            echo "[desktop] MIXER MASTER: PASS (unmuted)"
        else
            echo "[desktop] MIXER MASTER: WARNING (Master not 'on' - codec may name it differently)"
        fi
        # try the playback devices real users would use, first success wins.
        # 'default' (dmix) / 'plughw' (auto params) / 'hw' (exact params).
        P_OK=""
        for DEV in default plughw:0,0 hw:0,0; do
            if timeout 30 aplay -q -D "$DEV" /usr/share/sounds/alsa/Front_Center.wav 2>/tmp/aplay.err; then
                P_OK="$DEV"
                break
            fi
            echo "[desktop] aplay -D $DEV failed: $(tr '\n' ';' < /tmp/aplay.err | head -c 300)"
        done
        if [ -n "$P_OK" ]; then
            if [ "$P_OK" = "default" ]; then
                echo "[desktop] SOUND PLAYBACK: PASS (Front_Center.wav via default PCM)"
            else
                echo "[desktop] SOUND PLAYBACK: PASS (Front_Center.wav via $P_OK - 'default' device FAILED, see aplay errors above)"
            fi
        else
            echo "[desktop] SOUND PLAYBACK: FAIL on all devices - ALSA state:"
            echo "[desktop] /proc/asound/cards: $(sed -n '1,4p' /proc/asound/cards 2>/dev/null | tr '\n' '|')"
            echo "[desktop] /proc/asound/pcm: $(cat /proc/asound/pcm 2>/dev/null | tr '\n' '|')"
            echo "[desktop] /proc/asound/card0: $(ls /proc/asound/card0/ 2>/dev/null | tr '\n' ' ')"
            echo "[desktop] /dev/snd: $(ls /dev/snd/ 2>/dev/null | tr '\n' ' ')"
            echo "[desktop] aplay -l: $(aplay -l 2>&1 | tr '\n' '|' | head -c 400)"
            echo "[desktop] kernel sound messages:"
            dmesg 2>/dev/null | grep -iE 'hda|snd|codec' | tail -12 | sed 's/^/[desktop]   /'
            OK=0
        fi
    else
        echo "[desktop] SOUND PLAYBACK: FAIL (aplay or test wav missing - alsa-utils broken in the desktop pack?)"
        OK=0
    fi
    # volume control applet: the desktop session starts volumeicon (tray
    # mixer) once a card registers - verify the process is actually alive
    # so the panel tray really has a volume control for the user
    A_OK=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        pgrep -x volumeicon >/dev/null 2>&1 && A_OK=1 && break
        sleep 1
    done
    if [ "$A_OK" = "1" ]; then
        echo "[desktop] VOLUME APPLET: PASS (volumeicon running)"
    else
        echo "[desktop] VOLUME APPLET: FAIL (volumeicon not running - tray has no volume control)"
        echo "[desktop] volumeicon log tail: $(tail -3 /var/log/volumeicon.log 2>/dev/null | tr '\n' ';')"
        OK=0
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
# apt-get update -> install 'ed' -> run it -> remove it ->
# install python3 (the user case: a full dependency chain with
# tzdata/debconf that must configure cleanly on the merged-usr root)
# -> remove it -> power off
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
       && dpkg-query -s ed >/dev/null 2>&1 && [ -x /usr/bin/ed ]; then
        echo "[apt] APT INSTALL: PASS ($(dpkg-query -s ed 2>/dev/null | grep '^Version:' | tr -d '\r'))"
    else
        echo "[apt] APT INSTALL: FAIL - log tail:"
        tail -15 /var/log/apt-install.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    # NOTE: the session must end with 'Q' (unconditional quit): the buffer
    # was modified (append without write), so plain 'q' refuses with a "?"
    # on stdout + exit 1 - and EOF without quit makes GNU ed print "?"
    # too. (Run#21 passed only because PATH resolved to the busybox ed
    # applet then; on the merged-usr root the real GNU ed runs.)
    R="$(printf 'a\nhello from apt\n.\np\nQ\n' | ed 2>/dev/null | tail -1)"
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
       && ! dpkg-query -W -f='${Status}' ed 2>/dev/null | grep -q 'install ok installed' \
       && [ ! -x /usr/bin/ed ]; then
        echo "[apt] APT REMOVE: PASS"
    else
        echo "[apt] APT REMOVE: FAIL - log tail:"
        tail -15 /var/log/apt-remove.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    echo "[apt] apt-get install python3 (full dependency chain: tzdata + debconf + netbase + media-types)..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 >/var/log/apt-python3.log 2>&1 \
       && dpkg-query -s python3 >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
        PYV="$(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)"
        echo "[apt] APT PYTHON3: PASS (python $PYV)"
    else
        echo "[apt] APT PYTHON3: FAIL - log tail:"
        tail -15 /var/log/apt-python3.log 2>/dev/null || true
        echo "[selftest] APT FAILED"
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
        sleep 5
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger
    fi
    echo "[apt] apt-get remove python3..."
    # assert on the dpkg status, not on a file: /usr/bin/python3 belongs
    # to python3-minimal and survives the removal of the python3 metapkg
    if DEBIAN_FRONTEND=noninteractive apt-get remove -y python3 >/var/log/apt-py-remove.log 2>&1 \
       && ! dpkg-query -W -f='${Status}' python3 2>/dev/null | grep -q 'install ok installed'; then
        echo "[apt] APT PYTHON3 REMOVE: PASS"
    else
        echo "[apt] APT PYTHON3 REMOVE: FAIL - log tail:"
        tail -15 /var/log/apt-py-remove.log 2>/dev/null || true
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
echo "  Extras : calc <expr>  |  about  |  desktop  |  sound-init  |  apt install <pkg>"
echo "  Network: $NET_LINE"
echo "  System : live in RAM - nothing persists across reboot"
echo
exec setsid cttyhack sh
