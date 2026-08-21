# rootfs_mini — RISC-V 最小 rootfs(initrd) 一键构建

基于 busybox 一键构建适用于 RISC-V 的最小 rootfs（initrd），同时生成 **rv32** 与 **rv64** 两个产物，可直接用于 QEMU 启动验证：

- `rootfs_rv64.cpio.gz`
- `rootfs_rv32.cpio.gz`

## 目录结构

```
rootfs_mini/
├── build_rootfs.sh        # 一键构建脚本
├── README.md
├── config/                # busybox 配置（*.config）
│   ├── tiny.config            # 最小档：tinyconfig
│   ├── def.config             # 默认档：defconfig + 裁剪
│   ├── full.config            # 全量档：全部 applet（SELinux 除外）
│   └── busybox_applets.conf   # 全部命令清单（menuconfig 参考）
├── src/                   # 下载的 busybox 压缩包
├── tmp/                   # 解压的源码与编译中间产物
├── rootfs_rv64/           # rv64 rootfs 安装目录
├── rootfs_rv32/           # rv32 rootfs 安装目录
├── rootfs_rv64.cpio.gz    # 产物：rv64 initrd
└── rootfs_rv32.cpio.gz    # 产物：rv32 initrd
```

## 依赖

- 主机工具：`curl`、`bzip2`、`cpio`、`gzip`、`make`、`file`
- RISC-V 交叉编译器：rv64 与 rv32（可以是独立工具链，也可以是 multilib）

## 快速开始

```bash
./build_rootfs.sh
```

首次运行自动下载最新 busybox；再次运行时若 `src/` 已有压缩包，会交互提示：

```
检测到本地已有 busybox: 1.38.0，线上最新: 1.38.0
  [1] 下载并使用最新版本
  [2] 使用本地已有最新版本 (1.38.0)
```

## 常用选项（环境变量）

| 变量 | 说明 | 默认值 |
|---|---|---|
| `CROSS_COMPILE_64` | rv64 交叉编译器前缀（可为绝对路径） | `riscv64-unknown-linux-gnu-` |
| `CROSS_COMPILE_32` | rv32 交叉编译器前缀 | `riscv32-unknown-linux-gnu-` |
| `RV32_CFLAGS` | rv32 编译/链接标志（multilib 工具链需要） | `-march=rv32imac -mabi=ilp32` |
| `BB_CONFIG` | 使用 `config/` 下指定的自定义 busybox 配置 | 未设则 defconfig |
| `BUSYBOX_DIR` | 复用本地已有 busybox 源码目录（跳过下载） | 无 |
| `JOBS` | 并行编译数 | `nproc` |

示例（使用 Xuantie multilib 工具链同时构建双架构）：

```bash
XT=/path/to/Xuantie/bin/riscv64-unknown-linux-gnu-
CROSS_COMPILE_64=$XT CROSS_COMPILE_32=$XT ./build_rootfs.sh
```

交叉编译器不存在时脚本会报错并提示如何指定。

## 自定义 busybox 配置

自定义配置存放在 `config/*.config`：

- 构建时若存在配置文件，会交互提示选择：`[0] 默认 defconfig + 裁剪` 或 `[1..n] 某自定义配置`；非交互时用 `BB_CONFIG=<文件名> ./build_rootfs.sh` 指定。
- 不选择任何配置时使用 busybox defconfig + 脚本内置裁剪（静态链接、关闭 TC/SUID/IPv6 等）。
- 无论使用哪种配置，脚本都会强制 `CONFIG_STATIC=y`（initrd 需静态链接），并在 rv32 构建时自动注入 `RV32_CFLAGS` 到 EXTRA_CFLAGS/EXTRA_LDFLAGS。

内置三档配置（同一份 config 通用于 rv32/rv64）：

| 配置 | 来源 | 命令数 | rootfs cpio.gz |
|---|---|---|---|
| `tiny.config` | allnoconfig + 核心 applet（ash/init/getty/mount/mdev 等） | 33 | ~556K |
| `def.config` | busybox defconfig + 默认裁剪 | 403 | ~1.2M |
| `full.config` | 全量 applet（SELinux 系列除外）+ IPv6 | 427 | ~1.2M |

生成自己的配置：

```bash
# 1. 先构建一次得到 defconfig 结果
# 2. 按需修改（或进源码目录 make menuconfig）
# 3. 复制到 config/
cp tmp/busybox-build-rv64/.config config/demo.config
```

参考文件：`config/busybox_applets.conf` 列出 busybox 源码支持的**全部**命令（applet）及对应 CONFIG 符号、默认安装路径，供 menuconfig 裁剪时查阅。

## QEMU 启动验证

```bash
# rv64
qemu-system-riscv64 -M virt -nographic \
    -kernel <Image> -initrd rootfs_rv64.cpio.gz \
    -append 'console=ttyS0 rdinit=/init'

# rv32
qemu-system-riscv32 -M virt -nographic \
    -bios <fw_dynamic.bin> -kernel <Image> -initrd rootfs_rv32.cpio.gz \
    -append 'console=ttyS0 rdinit=/init'
```

启动成功后 `rcS` 会挂载 proc/sysfs/devtmpfs 并打印 `Mini rootfs ready.`，随后进入 getty 登录提示符（root，无密码）。

## rootfs 内容说明

- `/init` → `exec /sbin/init`（initrd 入口）
- `/etc/inittab`：执行 `rcS`、在 console 上 respawn getty
- `/etc/init.d/rcS`：挂载 proc/sys/devtmpfs/tmp
- busybox 静态链接安装，提供 sh、ls、mount、getty 等常用命令
