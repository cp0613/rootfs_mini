#!/bin/bash
# build_rootfs.sh - 一键构建基于 busybox 的 RISC-V 最小 rootfs(initrd)，同时生成 rv32/rv64
#
# 用法:
#   ./build_rootfs.sh              # 拉取最新 busybox 并完整构建 rv32 + rv64
#   CROSS_COMPILE_64=<prefix> CROSS_COMPILE_32=<prefix> ./build_rootfs.sh  # 指定交叉编译器前缀
#   BUSYBOX_DIR=<dir> ./build_rootfs.sh        # 复用已有 busybox 源码目录(跳过下载)
#   BB_CONFIG=<文件名> ./build_rootfs.sh       # 使用 config/ 下指定的自定义 busybox 配置
#
# 源码与压缩包统一保存在 <脚本目录>/src/ 下；
# 若 src/ 已有 busybox，交互运行时提示选择"下载最新"或"使用本地已有最新版"。
# 自定义 busybox 配置存放在 <脚本目录>/config/*.config，构建时交互选择其一；
# 不选择（或非交互且未设 BB_CONFIG）时使用 defconfig + 默认裁剪。
#
# 产物: <脚本目录>/rootfs_rv64.cpio.gz 与 <脚本目录>/rootfs_rv32.cpio.gz

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

: "${CROSS_COMPILE_64:=riscv64-unknown-linux-gnu-}"
: "${CROSS_COMPILE_32:=riscv32-unknown-linux-gnu-}"
# rv32 编译标志（仅当使用 64 位 multilib 编译器作为 CROSS_COMPILE_32 时需要）
: "${RV32_CFLAGS:=-march=rv32imac -mabi=ilp32}"
: "${JOBS:=$(nproc)}"

log() { echo -e "\033[1;32m[build_rootfs]\033[0m $*"; }
die() { echo -e "\033[1;31m[build_rootfs ERROR]\033[0m $*" >&2; exit 1; }

check_tool() {
    command -v "$1" >/dev/null 2>&1 || die "缺少工具: $1，请先安装"
}

for t in curl bzip2 cpio gzip make; do check_tool "$t"; done
# 检查交叉编译器是否存在（兼容 PATH 中的简单前缀和绝对路径前缀）
for cc in "$CROSS_COMPILE_64" "$CROSS_COMPILE_32"; do
    if ! command -v "${cc}gcc" >/dev/null 2>&1; then
        die "交叉编译器不存在: ${cc}gcc
  请安装 RISC-V 交叉工具链，或通过环境变量 CROSS_COMPILE_64 / CROSS_COMPILE_32 指定编译器前缀（可为绝对路径），例如:
  CROSS_COMPILE_64=/path/to/bin/riscv64-unknown-linux-gnu- \\
  CROSS_COMPILE_32=/path/to/bin/riscv32-unknown-linux-gnu- ./build_rootfs.sh"
    fi
done

# ============================================================
# 1. 拉取 busybox（压缩包保存在 src/，解压与构建在 tmp/）
# ============================================================
SRC_ROOT="$SCRIPT_DIR/src"      # 下载的压缩包
TMP_ROOT="$SCRIPT_DIR/tmp"      # 解压出的源码与编译中间产物
mkdir -p "$SRC_ROOT" "$TMP_ROOT"

# 查找 src/ 下已有的 busybox 压缩包，取最新
EXISTING_TARBALL=$(ls "$SRC_ROOT"/busybox-*.tar.bz2 2>/dev/null | sort -V | tail -1)

# 查询线上最新版本（失败不阻塞，可回退使用本地已有版本）
LATEST=$(curl -fsSL https://busybox.net/downloads/ \
    | grep -o 'busybox-[0-9]\+\.[0-9]\+\.[0-9]\+\.tar\.bz2' \
    | sort -t- -k2 -V | tail -1) || LATEST=""

if [ -n "$BUSYBOX_DIR" ]; then
    [ -d "$BUSYBOX_DIR" ] || die "BUSYBOX_DIR 不存在: $BUSYBOX_DIR"
    SRC_DIR="$(cd "$BUSYBOX_DIR" && pwd)"
    log "使用 BUSYBOX_DIR 指定的源码: $SRC_DIR"
elif [ -n "$EXISTING_TARBALL" ]; then
    EXISTING_VER=$(basename "$EXISTING_TARBALL"); EXISTING_VER="${EXISTING_VER#busybox-}"; EXISTING_VER="${EXISTING_VER%.tar.bz2}"
    if [ -z "$LATEST" ]; then
        log "无法访问 busybox.net，直接使用本地最新版本: busybox-$EXISTING_VER"
        TARBALL="busybox-$EXISTING_VER.tar.bz2"
    elif [ -t 0 ]; then
        LATEST_VER="${LATEST#busybox-}"; LATEST_VER="${LATEST_VER%.tar.bz2}"
        echo "检测到本地已有 busybox: $EXISTING_VER，线上最新: $LATEST_VER"
        echo "  [1] 下载并使用最新版本"
        echo "  [2] 使用本地已有最新版本 ($EXISTING_VER)"
        read -r -p "请选择 [1-2，默认 1]: " CHOICE
        case "$CHOICE" in
            2) TARBALL="busybox-$EXISTING_VER.tar.bz2" ;;
            *) TARBALL="$LATEST" ;;
        esac
    else
        log "非交互模式，默认下载最新版本"
        TARBALL="$LATEST"
    fi
    [ -n "${TARBALL:-}" ] || die "无可用 busybox 版本（本地无存档且网络不可达），可用 BUSYBOX_DIR 指定源码"
    VER="${TARBALL#busybox-}"; VER="${VER%.tar.bz2}"
    SRC_DIR="$TMP_ROOT/busybox-$VER"
    if [ ! -d "$SRC_DIR" ]; then
        if [ ! -f "$SRC_ROOT/$TARBALL" ]; then
            log "下载 https://busybox.net/downloads/$TARBALL ..."
            curl -fSL "https://busybox.net/downloads/$TARBALL" -o "$SRC_ROOT/$TARBALL" \
                || die "下载失败"
        fi
        log "解压 $TARBALL 到 $TMP_ROOT ..."
        tar xjf "$SRC_ROOT/$TARBALL" -C "$TMP_ROOT"
    else
        log "busybox-$VER 源码已存在，跳过下载"
    fi
else
    # src/ 下无已有版本，直接下载最新
    [ -n "$LATEST" ] || die "无法访问 busybox.net 且本地无已有 busybox，请检查网络或使用 BUSYBOX_DIR 指定源码"
    TARBALL="$LATEST"
    VER="${LATEST#busybox-}"; VER="${VER%.tar.bz2}"
    SRC_DIR="$TMP_ROOT/busybox-$VER"
    if [ ! -d "$SRC_DIR" ]; then
        log "下载 https://busybox.net/downloads/$TARBALL ..."
        curl -fSL "https://busybox.net/downloads/$TARBALL" -o "$SRC_ROOT/$TARBALL" \
            || die "下载失败"
        log "解压 $TARBALL 到 $TMP_ROOT ..."
        tar xjf "$SRC_ROOT/$TARBALL" -C "$TMP_ROOT"
    fi
fi

# ============================================================
# 2. 选择 busybox 配置（config/ 下自定义 config 或使用 defconfig）
# ============================================================
CONF_DIR="$SCRIPT_DIR/config"
mkdir -p "$CONF_DIR"
CHOSEN_CONFIG=""

shopt -s nullglob
CUSTOM_CONFIGS=("$CONF_DIR"/*.config)
shopt -u nullglob

if [ ${#CUSTOM_CONFIGS[@]} -gt 0 ]; then
    if [ -n "$BB_CONFIG" ]; then
        # 支持传文件名(config/ 下)或完整路径
        if [ -f "$CONF_DIR/$BB_CONFIG" ]; then
            CHOSEN_CONFIG="$CONF_DIR/$BB_CONFIG"
        elif [ -f "$BB_CONFIG" ]; then
            CHOSEN_CONFIG="$BB_CONFIG"
        else
            die "BB_CONFIG 指定的配置不存在: config/$BB_CONFIG"
        fi
    elif [ -t 0 ]; then
        echo "检测到 config/ 下有自定义 busybox 配置:"
        echo "  [0] 使用默认 defconfig + 默认裁剪"
        i=1
        for c in "${CUSTOM_CONFIGS[@]}"; do
            echo "  [$i] $(basename "$c")"
            i=$((i+1))
        done
        read -r -p "请选择 [0-$((i-1))，默认 0]: " CFG_CHOICE
        if [ -n "$CFG_CHOICE" ] && [ "$CFG_CHOICE" -ge 1 ] 2>/dev/null \
           && [ "$CFG_CHOICE" -le $((i-1)) ]; then
            CHOSEN_CONFIG="${CUSTOM_CONFIGS[$((CFG_CHOICE-1))]}"
        fi
    else
        log "非交互模式且未指定 BB_CONFIG，使用默认 defconfig"
    fi
fi

if [ -n "$CHOSEN_CONFIG" ]; then
    log "将使用自定义配置: $CHOSEN_CONFIG"
else
    log "使用默认 defconfig + 默认裁剪"
fi

# ============================================================
# 3~6. 按架构构建: 配置 -> 编译 -> 安装 -> 骨架 -> 打包
# ============================================================
set_cfg() { # set_cfg <config文件> CONFIG_XXX y|n（兼容 "is not set" 与 "=y" 两种形式）
    local conf=$1 k=$2 v=$3
    if [ "$v" = y ]; then
        sed -i "s/^# ${k} is not set/${k}=y/; s/^${k}=.*/${k}=y/" "$conf"
    else
        sed -i "s/^${k}=.*/# ${k} is not set/" "$conf"
    fi
}

gen_skeleton() { # gen_skeleton <rootfs目录>
    local ROOTFS=$1
    mkdir -p "$ROOTFS"/{etc/init.d,dev,proc,sys,tmp,root,usr/{bin,sbin},var}
    chmod 1777 "$ROOTFS/tmp"

    cat > "$ROOTFS/etc/passwd" <<'EOF'
root::0:0:root:/root:/bin/sh
EOF
    cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

    cat > "$ROOTFS/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
::respawn:/sbin/getty -L 0 console 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

    cat > "$ROOTFS/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mount -t proc  none  /proc
mount -t sysfs none  /sys
mount -t devtmpfs none /dev 2>/dev/null || mdev -s
mount -t tmpfs none /tmp
echo "Mini rootfs ready."
EOF
    chmod +x "$ROOTFS/etc/init.d/rcS"

    cat > "$ROOTFS/init" <<'EOF'
#!/bin/sh
exec /sbin/init
EOF
    chmod +x "$ROOTFS/init"
}

build_rootfs() { # build_rootfs <rv32|rv64> <交叉编译器前缀> [额外CFLAGS]
    local ARCH=$1 CC_PREFIX=$2 EXTRA_CFLAGS=$3
    local BUILDDIR="$TMP_ROOT/busybox-build-$ARCH"
    local ROOTFS="$SCRIPT_DIR/rootfs_$ARCH"
    local OUT="$SCRIPT_DIR/rootfs_$ARCH.cpio.gz"

    # O= 外部构建要求源码树干净，清理历史 in-tree 构建残留（仅首个架构时生效）
    if [ -f "$SRC_DIR/.config" ]; then
        log "清理源码树中的历史构建残留 (make mrproper) ..."
        make -C "$SRC_DIR" mrproper >/dev/null 2>&1 || rm -f "$SRC_DIR/.config"
    fi

    if [ -n "$CHOSEN_CONFIG" ]; then
        log "==== [$ARCH] 配置 busybox (自定义配置 $(basename "$CHOSEN_CONFIG")) ===="
    else
        log "==== [$ARCH] 配置 busybox (defconfig + 静态链接) ===="
    fi
    rm -rf "$BUILDDIR"
    mkdir -p "$BUILDDIR"

    local CONF="$BUILDDIR/.config"
    if [ -n "$CHOSEN_CONFIG" ]; then
        cp "$CHOSEN_CONFIG" "$CONF"
        # 自定义配置仍强制静态链接（initrd 不依赖共享库）
        set_cfg "$CONF" CONFIG_STATIC y
    else
        make -C "$SRC_DIR" O="$BUILDDIR" defconfig >/dev/null
        set_cfg "$CONF" CONFIG_STATIC y           # 静态链接，initrd 不依赖共享库
        set_cfg "$CONF" CONFIG_TC n               # 依赖 libnetlink 头文件，最小系统不需要
        set_cfg "$CONF" CONFIG_FEATURE_SUID n     # 最小系统不需要 setuid
        set_cfg "$CONF" CONFIG_FEATURE_INSTALLER n
        set_cfg "$CONF" CONFIG_IFPLUGD n
        set_cfg "$CONF" CONFIG_FEATURE_IPV6 n     # 按需保留可改回 y
    fi
    if [ -n "$EXTRA_CFLAGS" ]; then
        sed -i "s|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS=\"$EXTRA_CFLAGS\"|" "$CONF"
        # 链接阶段也需要 arch/abi 标志，否则 multilib 工具链默认按 64 位仿真链接
        sed -i "s|^CONFIG_EXTRA_LDFLAGS=.*|CONFIG_EXTRA_LDFLAGS=\"$EXTRA_CFLAGS\"|" "$CONF"
    fi

    yes "" | make -C "$SRC_DIR" O="$BUILDDIR" oldconfig >/dev/null 2>&1 || true

    log "==== [$ARCH] 编译 busybox (CROSS_COMPILE=$CC_PREFIX, -j$JOBS) ===="
    make -C "$SRC_DIR" O="$BUILDDIR" CROSS_COMPILE="$CC_PREFIX" -j"$JOBS" || die "[$ARCH] 编译失败"

    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"
    log "==== [$ARCH] 安装到 $ROOTFS ===="
    make -C "$SRC_DIR" O="$BUILDDIR" CROSS_COMPILE="$CC_PREFIX" CONFIG_PREFIX="$ROOTFS" install

    log "==== [$ARCH] 生成 rootfs 骨架 ===="
    gen_skeleton "$ROOTFS"

    log "==== [$ARCH] 打包 $OUT ===="
    ( cd "$ROOTFS" && find . | LC_ALL=C sort | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT" )
    log "[$ARCH] 完成: $OUT ($(du -h "$OUT" | cut -f1))，busybox: $(file -b "$ROOTFS/bin/busybox" | cut -d, -f1-3)"
}

build_rootfs rv64 "$CROSS_COMPILE_64"
build_rootfs rv32 "$CROSS_COMPILE_32" "$RV32_CFLAGS"

log "全部完成！产物:"
log "  rv64: $SCRIPT_DIR/rootfs_rv64.cpio.gz"
log "  rv32: $SCRIPT_DIR/rootfs_rv32.cpio.gz"
