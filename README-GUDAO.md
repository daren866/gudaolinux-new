# Gudao Linux

基于 Linux 7.2.4（Debian 打包源码为基底）的独立发行版。内核、BusyBox 用户态、
GRUB 引导的混合（BIOS + UEFI）启动 ISO 全部由 GitHub Actions 自动构建，并自动发布
到仓库 Releases。

## 特性

| 项目 | 说明 |
|------|------|
| 内核 | Linux 7.2.4 + 77 个 Debian 补丁，本地版本号 `7.2.4-gudao` |
| 内核名称 | `NAME = "Gudao Linux"`（Makefile），主机名 `gudao` |
| 用户态 | BusyBox 1.36.1（**全静态编译**，无 glibc 依赖） |
| 终端 | `/dev/console` 上的 BusyBox ash（setsid + cttyhack） |
| 键盘 | 基础键盘驱动：PS/2（i8042 + atkbd）与 USB（xHCI/EHCI/UHCI + usbhid），全部内建 |
| 引导 | GRUB 2，默认 5 秒菜单，含串口控制台与 nomodeset 备用启动项 |
| CI | GitHub Actions：内核 → busybox → initramfs → QEMU 冒烟测试 → ISO → Release |

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
qemu-system-x86_64 -m 512M -cdrom GudaoLinux-*.iso
# 串口调试:
qemu-system-x86_64 -m 512M -nographic -cdrom GudaoLinux-*.iso
# 然后在 GRUB 菜单选 "serial console ttyS0" 启动项
```

### 真机 / 虚拟机

- VirtualBox / VMware：直接挂载 ISO 启动
- 物理机 U 盘：`dd if=GudaoLinux-*.iso of=/dev/sdX bs=4M status=progress && sync`
- UEFI 机器如遇启动问题请在固件中**关闭 Secure Boot**（内核未签名）

## 仓库结构（新增部分）

```
.github/workflows/build-iso.yml   GitHub Actions 构建流水线
gudao/kernel-fragment.config      内核配置片段（键盘/串口/命名/精简构建）
gudao/initramfs/init              initramfs 启动脚本（busybox 终端入口）
gudao/grub/grub.cfg               GRUB 引导菜单
```

> 注：根目录 `.gitignore` 含 Debian 打包仓库专用的 `/*` 规则，向本仓库添加
> 新顶层目录时需 `git add -f`。
