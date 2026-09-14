# Gudao Linux

基于 Linux 7.2.4（Debian 打包源码为基底）的独立发行版。内核、BusyBox 用户态、
GRUB 引导的混合（BIOS + UEFI）启动 ISO 全部由 GitHub Actions 自动构建，并自动发布
到仓库 Releases。

## 特性

| 项目 | 说明 |
|------|------|
| 内核 | Linux 7.2.4 + 77 个 Debian 补丁，本地版本号 `7.2.4-gudao` |
| 内核名称 | `NAME = "Gudao Linux"`（Makefile），主机名 `gudao` |
| 用户态 | BusyBox 1.36.1（**全静态编译**，无 glibc 依赖）+ Gudao 自研 applet |
| 终端 | `/dev/console` 上的 BusyBox ash（setsid + cttyhack） |
| 键盘 | 基础键盘驱动：PS/2（i8042 + atkbd）与 USB（xHCI/EHCI/UHCI + usbhid），全部内建 |
| 网络 | Intel e1000/e1000e 网卡驱动内建；**开机自动 DHCP 分配 IP**，DNS 固定为 `8.8.8.8` |
| 包管理 | **apt + dpkg 开机即用**，默认源为清华 TUNA（trixie + updates/backports + security），可在运行时安装/卸载软件（装在 RAM，重启后消失） |
| 桌面 | 输入 `desktop` 一键启动：**Xorg（Mesa llvmpipe CPU 渲染）→ xfwm4 → xfce4-panel → xfdesktop → thunar → xfce4-terminal → volumeicon**；libinput 输入管理 |
| 声音 | QEMU/VMware/VirtualBox 虚拟声卡驱动全内建（Intel HDA、ICH AC97、ES1370/1371）；开机自动解除混音器静音（`sound-init`），面板托盘 **volumeicon** 调音量 |
| 图形驱动 | 内建：QEMU（bochs/cirrus/virtio-gpu）、VMware（vmwgfx + vmmouse）、VirtualBox（vboxvideo）；VESA fb 兜底 |
| 引导 | GRUB 2，默认 5 秒菜单；**默认安静 display-only 启动（无内核日志）**，想看日志在菜单手动选 "with kernel log" 项 |
| CI | GitHub Actions：内核 → busybox → 桌面包 → initramfs → QEMU 冒烟测试（含桌面自测） → ISO → Release |

## 内置指令（Gudao applets）

源码位于 `busybox-1.36.1/miscutils/`，随 BusyBox 一起静态编译，开机即用：

| 指令 | 格式 | 示例 | 说明 |
|------|------|------|------|
| `calc` | `calc <数学表达式>` | `calc 2*(2+2)` → `8` | 支持加减乘除、取余、括号、小数，带除零/语法错误检查 |
| `about` | `about` | — | 显示系统名、内核版本、内存大小（动态检测）、CPU 型号 |

```text
# calc 2*(2+2)
8
# calc 10/4
2.5
# about
system: Gudao Linux
kernel: Linux7 (7.2.4-gudao)
ram: 2048mb(2GB)
cpu: Intel Core i7-6500U
```

添加新指令：在 `busybox-1.36.1/miscutils/` 下新建 `<name>.c`（仿照 `about.c` 的
`//config:` / `//applet:` / `//usage:` 头部），提交后 CI 自动编译进 ISO。

## 网络（e1000 + 自动 DHCP + DNS 8.8.8.8）

- 驱动：Intel e1000 / e1000e **内建于内核**（CONFIG_E1000=y），QEMU、VirtualBox、
  VMware 默认虚拟网卡开机即可识别为 `eth0`
- 自动分配 IP：init 引导阶段用 busybox `udhcpc` 向 DHCP 服务器申请地址
  （QEMU/VirtualBox/家用路由器的 DHCP 均可直接使用），并自动配置默认网关
- DNS：`/etc/resolv.conf` 固定包含 `nameserver 8.8.8.8`（DHCP 下发的 DNS 也会写入，
  8.8.8.8 始终兜底）
- 开机欢迎页会显示获取到的地址，例如 `Network: eth0  10.0.2.15  (dhcp, dns 8.8.8.8)`
- 手动验证：

```text
# ifconfig eth0            # 查看 DHCP 分配到的地址
# cat /etc/resolv.conf     # nameserver 8.8.8.8
# route                    # 查看默认网关
```

## 包管理（apt，TUNA 源）

系统内置 apt + dpkg，开机自动解包就绪（无需先启动桌面）：

```text
# apt update                          # 从清华 TUNA + security.debian.org 拉索引
# apt install <包名>                   # 安装软件（含 contrib/non-free/non-free-firmware）
# apt remove <包名>                    # 卸载
# apt search <关键词>                  # 搜索
```

- 源配置：`/etc/apt/sources.list`（传统格式），三件套 `trixie / trixie-updates /
  trixie-backports` 走 `mirrors.tuna.tsinghua.edu.cn`，安全更新走官方
  `security.debian.org`；deb-src 默认注释以提高 update 速度
- HTTPS 证书与 Debian 签名密钥环已内置（ca-certificates + debian-archive-keyring）
- 活系统策略：包安装时**不会自动启动服务**（policy-rc.d），systemd 不存在，
  服务脚本调用 systemctl 会被静默忽略（仅装包不启动）
- **注意：整个系统驻留 RAM，apt 装的软件重启后消失**；如需长期保留请把软件
  装进持久化存储（后续版本提供）

## 图形桌面（`desktop` 命令）

在 busybox shell 里输入 `desktop` 即可启动 X 桌面（首次运行需解压桌面包，
约 1 分钟；完成后看虚拟机/真机的图形显示 tty1）：

```text
# desktop
desktop: unpacking desktop pack (first run only, please wait)...
desktop: starting Xorg (Mesa CPU rendering)...
desktop: loading xfwm4 (window manager)...
desktop: loading xfce4-panel...
desktop: loading xfdesktop (desktop layer)...
desktop: loading thunar (file manager, daemon mode)...
desktop: loading xfce4-terminal...

  Desktop is up: ... + volumeicon (volume)
```

启动顺序与组件：

1. **Xorg** — 内核 bochs/vmwgfx/vboxvideo DRM 或 VESA fb 驱动，`LIBGL_ALWAYS_SOFTWARE=1`
   强制 **Mesa llvmpipe CPU 渲染**（无需 GPU）；
2. **xfwm4** — 窗口管理器（关闭合成器，纯 CPU 友好）；
3. **xfce4-panel** — 顶栏（应用菜单/任务列表/托盘/时钟）；
4. **xfdesktop** — 桌面背景、桌面图标与右键菜单；
5. **thunar** — 文件管理器（守护模式随桌面启动，双击桌面图标即可打开）；
6. **xfce4-terminal** — 自动打开一个终端窗口；
7. **volumeicon** — 面板托盘音量控件（检测到声卡后自动启动）。

技术实现：

- 桌面用户态来自 **Debian trixie**（Xorg/Mesa/XFCE 依赖闭包），CI 自动下载
  解包打为 `desktop-pack.tar.gz` 嵌入 initramfs `/opt/`，`desktop` 命令首次运行时
  解压到根（tmpfs），并排除 resolv.conf/hosts/passwd 等基础文件防覆盖；
- 输入：**libinput** + udev（udevd 启动后供 libinput 枚举设备），PS/2 / USB HID /
  VMware vmmouse 鼠标键盘均可；
- **内存建议 ≥ 2 GB**（整个系统连同桌面全部驻留 RAM，桌面包解压后约 550 MB）。

### 声音（音量调节与输出）

- **内核驱动全内建**（无模块即无加载失败面），覆盖主流虚拟机默认声卡：

  | 平台 | 仿真声卡 | 内建驱动 |
  |------|----------|----------|
  | QEMU/virt-manager 默认 | Intel HDA + hda-duplex | SND_HDA_INTEL + SND_HDA_GENERIC |
  | QEMU AC97 / VBox ICH AC97 | ICH AC97 | SND_INTEL8X0 + SND_AC97_CODEC |
  | QEMU ES1370 | Ensoniq ES1370 | SND_ENS1370 |
  | VBox 默认 HD Audio | Intel HD Audio | SND_HDA_INTEL |
  | VMware 默认 | ES1371 / HD Audio | SND_ENS1371 / SND_HDA_INTEL |

- **开机自动解除静音**：HDA/AC97 codec 上电默认静音或零音量，`desktop`
  启动时后台执行 **`sound-init`**（等卡片注册 → `alsactl init` 解除静音并设
  音量 → amixer 兜底），日志在 `/var/log/sound-init.log`；
- **音量调节**：面板托盘 **volumeicon**（左键弹滑条/滚轮调节，中键静音，右键
  菜单可开 alsamixer）——前提是 VM 里真的有声卡（QEMU 必须显式加
  `-device intel-hda -device hda-duplex`，见上节启动命令）；
- **排查**：控制台敲 `sound-init` 重放混音器初始化并输出诊断（卡片、
  Master 状态、aplay -l、PCM 列表）；
  `aplay /usr/share/sounds/alsa/Front_Center.wav` 实听测试；
  `cat /proc/asound/cards` 看卡片是否注册（空 → VM 没接声卡设备）。
  **guest/宿主侧判定**：若 `aplay` 播放成功但 VM 仍无声，guest 侧已正常
  （音频数据已交给内核声卡），问题在宿主侧——QEMU 缺 `-audiodev` 或后端
  配置错误（QEMU 8+ 无 audiodev 时默认丢弃音频）、VMware/VBox 声卡设置
  未启用或宿主音量静音。

## 自动构建

触发方式（任选其一）：

1. **手动触发**：仓库页面 → Actions → *Build Gudao Linux ISO* → *Run workflow*
2. **打标签触发**：`git tag v0.1 && git push origin v0.1`

构建流程完成后：

- 每次运行都会在 **Releases** 发布 `GudaOLinux-<版本>-x86_64.iso` 与 `SHA256SUMS.txt`
  （手动触发的运行使用 `auto-YYYYMMDD-buildN` 版本号）
- Actions 运行详情页同时提供 artifact 下载

## 本地（克隆本仓库后手动构建）

```bash
make x86_64_defconfig
./scripts/kconfig/merge_config.sh -m .config gudao/kernel-fragment.config
make olddefconfig
make -j"$(nproc)" bzImage
# 之后按 .github/workflows/build-iso.yml 中 initramfs / ISO 步骤操作即可
```

## 启动方式

### QEMU（最快验证）

```bash
# 带声音输出（Linux 宿主 PulseAudio/PipeWire，桌面场景内存建议 2G）:
qemu-system-x86_64 -m 2G -enable-kvm -cdrom GudaoLinux-*.iso \
  -audiodev pa,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0
# 无宿主音频（仅验证驱动/播放路径，CI 同款）:
qemu-system-x86_64 -m 2G -cdrom GudaoLinux-*.iso \
  -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0
# 串口调试:
qemu-system-x86_64 -m 2G -nographic -cdrom GudaoLinux-*.iso
# 然后在 GRUB 菜单选 "serial console ttyS0" 启动项
```

> 声卡设备必须显式指定：QEMU 6+ 默认**不带任何音频设备**，缺上面的
> `-device intel-hda -device hda-duplex` 参数时 VM 里根本没有声卡，
> 面板托盘也不会出现音量控件。

### 真机 / 虚拟机

- VirtualBox / VMware：直接挂载 ISO 启动；若无声，请确认虚拟机设置里**声卡已启用**
  （VMware: 虚拟机设置 → 声卡；VirtualBox: 设置 → 音频 → 启用音频）
- 物理机 U 盘：`dd if=GudaoLinux-*.iso of=/dev/sdX bs=4M status=progress && sync`
- UEFI 机器如遇启动问题请在固件中**关闭 Secure Boot**（内核未签名）

## 仓库结构（新增部分）

```
.github/workflows/build-gudao-iso.yml   GitHub Actions 构建流水线（主流程）
.github/workflows/build-iso.yml          备用流水线
gudao/kernel-fragment.config      内核配置片段（键盘/串口/网络/显卡/命名）
gudao/initramfs-init.sh           initramfs 启动脚本（busybox 终端入口 + CI 自测）
gudao/build-initramfs.sh          initramfs 组装脚本（含 desktop 启动器生成）
gudao/build-apt-pack.sh           apt 包管理器构建（apt+dpkg+密钥环+CA证书闭包，TUNA sources.list）
gudao/build-desktop-pack.sh       桌面包构建（Debian trixie Xorg/XFCE 依赖闭包）
gudao/build-iso.sh                GRUB ISO 制作脚本
gudao/grub/grub.cfg               GRUB 引导菜单
busybox-1.36.1/                   BusyBox 完整源码（含 Gudao applet：calc、about）
```

> 注：根目录 `.gitignore` 含 Debian 打包仓库专用的 `/*` 规则（`busybox-1.36.1/`
> 已加入白名单），向本仓库添加其它新顶层目录时仍需 `git add -f` 或扩充白名单。
