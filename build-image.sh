#!/bin/bash
#
# build-image-w737.sh – 为 samsung Galaxy Book2 W737 / SDM850 生成 Arch Linux ARM 镜像
#
# 依照教程整理并修正：
# 1. 先安装基础系统与 grub，再补丁 grub 脚本
# 2. 再安装内核、模块、固件
# 3. 最后生成 initramfs、组装镜像并安装 grub
#
# 使用方法（需要 root）：
#   sudo ./build-image-w737.sh
#
set -euo pipefail

###########################
# 配置（按需修改）
###########################
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    HOME_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    HOME_DIR="${HOME:-/root}"
fi

WORKDIR="$HOME_DIR/depot/w737"
ROOTFS_DIR="$WORKDIR/rootfs"
IMAGE_FILE="$WORKDIR/w737-arch.img"
TARBALL="$WORKDIR/ArchLinuxARM-aarch64-latest.tar.gz"

USERNAME="w737user"
USER_PASS="w737user"
ROOT_PASS="root"
HOSTNAME="samsung-w737"

KERNEL_IMAGE="$WORKDIR/vmlinuz"
KERNEL_DTB="$WORKDIR/sdm850-samsung-w737.dtb"
KERNEL_MODULES_DIR="$WORKDIR/modules"
KERNEL_RELEASE=""

# 既支持“目录内含 lib/firmware/...”的固件树，也支持直接放文件
FIRMWARE_SRC="$WORKDIR/firmware"

IMAGE_SIZE="12G"
LOOPDEV=""

cleanup() {
    set +e
    if mountpoint -q /mnt/boot 2>/dev/null; then
        umount -R /mnt/boot 2>/dev/null || true
    fi
    if mountpoint -q /mnt 2>/dev/null; then
        umount -R /mnt 2>/dev/null || true
    fi
    if [ -n "$LOOPDEV" ] && losetup "$LOOPDEV" >/dev/null 2>&1; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ "${EUID:-0}" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f "$TARBALL" ]; then
    echo "错误：找不到根文件系统包 $TARBALL"
    exit 1
fi

if [ ! -f "$KERNEL_IMAGE" ]; then
    echo "错误：找不到内核镜像 $KERNEL_IMAGE"
    exit 1
fi

if [ ! -f "$KERNEL_DTB" ]; then
    echo "错误：找不到设备树文件 $KERNEL_DTB"
    exit 1
fi

###########################
# 1. 准备根文件系统
###########################
echo "=== 准备根文件系统 ==="
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"
bsdtar -xpf "$TARBALL" -C "$ROOTFS_DIR"

mkdir -p "$ROOTFS_DIR/etc/pacman.d"
cat > "$ROOTFS_DIR/etc/pacman.d/mirrorlist" <<'EOF'
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
EOF

###########################
# 2. 先安装基础系统与 grub
###########################
echo "=== 安装基础包并配置系统 ==="
cat > "$ROOTFS_DIR/bootstrap.sh" <<'SETUPEOF'
#!/bin/bash
set -euo pipefail

echo "root:ROOT_PASS_PLACEHOLDER" | chpasswd

sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
sed -i 's/^CheckSpace/#CheckSpace/g' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
pacman-key --refresh-keys || true
pacman-key --lsign-key 77193F152BDBE6A6 || true

# 依照教程移除默认内核，避免后续 grub 生成错误条目
pacman -Rdd --noconfirm linux-aarch64 || true

pacman -Syyu --noconfirm \
    fastfetch htop vim terminus-font sudo grub linux-firmware-qcom \
    arch-install-scripts efibootmgr rmtfs wget iwd

wget -O /tmp/tqftpserv-git.pkg.tar.xz \
  https://gitlab.com/kupfer/packages/prebuilts/-/raw/main/aarch64/main/tqftpserv-git-r12.783425b-2-aarch64.pkg.tar.xz
wget -O /tmp/pd-mapper-git.pkg.tar.xz \
  https://gitlab.com/kupfer/packages/prebuilts/-/raw/main/aarch64/main/pd-mapper-git-r13.d7fe25f-2-aarch64.pkg.tar.xz
pacman -U --noconfirm /tmp/tqftpserv-git.pkg.tar.xz /tmp/pd-mapper-git.pkg.tar.xz
rm -f /tmp/tqftpserv-git.pkg.tar.xz /tmp/pd-mapper-git.pkg.tar.xz

sed -e '0,/^#en_US/s//en_US/' -i /etc/locale.gen
locale-gen
cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_COLLATE=C
EOF
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=us
EOF

userdel -r alarm 2>/dev/null || true
useradd -g users -G wheel,storage,disk,rfkill,network,input,log -m USERNAME_PLACEHOLDER
echo "USERNAME_PLACEHOLDER:USER_PASS_PLACEHOLDER" | chpasswd

echo "HOSTNAME_PLACEHOLDER" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF

if grep -q '^# %wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
else
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
fi

cat > /etc/systemd/network/20-wifi.network <<'EOF'
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF

cat > /etc/default/grub <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="ignore_loglevel earlycon=qcom_geni clk_ignore_unused console=ttyMSM0,115200 console=tty2"
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="gfxterm serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DEVICETREE="sdm850-samsung-w737"
EOF

systemctl enable rmtfs pd-mapper tqftpserv iwd
SETUPEOF

sed -i "s/ROOT_PASS_PLACEHOLDER/$ROOT_PASS/g" "$ROOTFS_DIR/bootstrap.sh"
sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" "$ROOTFS_DIR/bootstrap.sh"
sed -i "s/USER_PASS_PLACEHOLDER/$USER_PASS/g" "$ROOTFS_DIR/bootstrap.sh"
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/g" "$ROOTFS_DIR/bootstrap.sh"
chmod +x "$ROOTFS_DIR/bootstrap.sh"
arch-chroot "$ROOTFS_DIR" /bootstrap.sh
rm -f "$ROOTFS_DIR/bootstrap.sh"

###########################
# 3. 补丁 grub 相关脚本
###########################
echo "=== 修补 grub 脚本 ==="
python3 - "$ROOTFS_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

# 1) 在 grub-mkconfig 导出变量列表中加入 GRUB_DEVICETREE
mkconfig = root / "usr/bin/grub-mkconfig"
text = mkconfig.read_text()
if "GRUB_DEVICETREE" not in text:
    needle = "GRUB_DEFAULT \\\n"
    replacement = "GRUB_DEFAULT \\\n  GRUB_DEVICETREE \\\n"
    if needle in text:
        text = text.replace(needle, replacement, 1)
        mkconfig.write_text(text)
    else:
        raise SystemExit("无法在 /usr/bin/grub-mkconfig 中找到 GRUB_DEFAULT 列表位置")

# 2) 在 /etc/grub.d/10_linux 中插入 devicetree 段
linux10 = root / "etc/grub.d/10_linux"
text = linux10.read_text()
snippet = """  if [ -n "${GRUB_DEVICETREE}" ]; then
    message="$(gettext_printf "Loading devicetree ...")"
    sed "s/^/$submenu_indentation/" << EOF
        echo    '$(echo "$message" | grub_quote)'
        devicetree ${rel_dirname}/dtbs/${GRUB_DEVICETREE}.dtb
EOF
  fi
"""
needle = 'if test -n "${initrd}" ; then'
if "devicetree ${rel_dirname}/dtbs/${GRUB_DEVICETREE}.dtb" not in text:
    if needle not in text:
        raise SystemExit("无法在 /etc/grub.d/10_linux 中找到 initrd 条件")
    text = text.replace(needle, snippet + needle, 1)
    linux10.write_text(text)
PY

###########################
# 4. 安装内核、模块与固件
###########################
echo "=== 安装内核、模块与固件 ==="
install -d "$ROOTFS_DIR/boot/dtbs"
install -m 644 "$KERNEL_IMAGE" "$ROOTFS_DIR/boot/vmlinuz-w737"
install -m 644 "$KERNEL_DTB" "$ROOTFS_DIR/boot/dtbs/sdm850-samsung-w737.dtb"

if [ -d "$KERNEL_MODULES_DIR/lib/modules" ]; then
    mkdir -p "$ROOTFS_DIR/usr/lib/modules"
    rsync -a "$KERNEL_MODULES_DIR/lib/modules/" "$ROOTFS_DIR/usr/lib/modules/"
elif [ -d "$KERNEL_MODULES_DIR" ]; then
    mkdir -p "$ROOTFS_DIR/usr/lib/modules"
    rsync -a "$KERNEL_MODULES_DIR/" "$ROOTFS_DIR/usr/lib/modules/"
else
    echo "错误：找不到模块目录 $KERNEL_MODULES_DIR"
    exit 1
fi

if [ -z "$KERNEL_RELEASE" ]; then
    KERNEL_RELEASE="$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1 | xargs -r basename)"
fi
if [ -z "$KERNEL_RELEASE" ]; then
    echo "错误：无法探测内核版本号"
    exit 1
fi
echo "内核版本：$KERNEL_RELEASE"
echo "$KERNEL_RELEASE" > "$ROOTFS_DIR/boot/kernel-release"

#mkdir -p "$ROOTFS_DIR/usr/lib/firmware"
if [ -d "$FIRMWARE_SRC/qcom" ]; then
    mkdir -p "$ROOTFS_DIR/usr/lib/firmware/qcom/sdm850/samsung/w737"
    rsync -a "$FIRMWARE_SRC/qcom/" "$ROOTFS_DIR/usr/lib/firmware/qcom/sdm850/samsung/w737/"
fi
#if [ -d "$FIRMWARE_SRC/lib/firmware/postmarketos" ]; then
#    mkdir -p "$ROOTFS_DIR/usr/lib/firmware/postmarketos"
#    rsync -a "$FIRMWARE_SRC/lib/firmware/postmarketos/" "$ROOTFS_DIR/usr/lib/firmware/postmarketos/"
#fi

if [ -f "$FIRMWARE_SRC/ipa_fws.elf" ]; then
    cp "$FIRMWARE_SRC/ipa_fws.elf" "$ROOTFS_DIR/usr/lib/firmware/"
else
    echo "警告：未找到 ipa_fws.elf"
fi

###########################
# 5. 创建 mkinitcpio 钩子并生成 initramfs
###########################
echo "=== 配置 mkinitcpio ==="
cat > "$ROOTFS_DIR/etc/mkinitcpio.d/linux-w737.preset" <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="$KERNEL_RELEASE"

PRESETS=('default')

default_image="/boot/initramfs-w737.img"
EOF

cat > "$ROOTFS_DIR/usr/lib/initcpio/install/w737" <<'HOOKEOF'
#!/bin/bash

build() {
    add_module ufs_qcom
    add_module ti_sn65dsi86

    add_file /usr/lib/firmware/qcom/sdm850/samsung/w737/qcdxkmsuc850.mbn
    add_file /usr/lib/firmware/qcom/a630_gmu.bin
    add_file /usr/lib/firmware/qcom/a630_sqe.fw
    add_file /usr/lib/firmware/ipa_fws.elf
    #add_file /usr/lib/firmware/ipa_fws.mdt
}

help() {
    cat <<HELPEOF
samsung W737 启动所需固件与内核模块
HELPEOF
}
HOOKEOF
chmod +x "$ROOTFS_DIR/usr/lib/initcpio/install/w737"

if ! grep -q ' w737' "$ROOTFS_DIR/etc/mkinitcpio.conf"; then
    sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 w737)/' "$ROOTFS_DIR/etc/mkinitcpio.conf"
fi

cat > "$ROOTFS_DIR/finalize.sh" <<'FINALEOF'
#!/bin/bash
set -euo pipefail
mkinitcpio -p linux-w737
FINALEOF
chmod +x "$ROOTFS_DIR/finalize.sh"
arch-chroot "$ROOTFS_DIR" /finalize.sh
rm -f "$ROOTFS_DIR/finalize.sh"

###########################
# 6. 生成最终镜像
###########################
echo "=== 生成最终镜像 ==="
rm -f "$IMAGE_FILE"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"

parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart primary fat32 1MiB 257MiB
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart primary ext4 257MiB 100%

LOOPDEV="$(losetup --show -fP "$IMAGE_FILE")"
mkfs.vfat -F32 "${LOOPDEV}p1"
mkfs.ext4 -F "${LOOPDEV}p2"

#mkdir -p /mnt
mount "${LOOPDEV}p2" /mnt
mkdir -p /mnt/boot/efi
mount "${LOOPDEV}p1" /mnt/boot/efi

echo "复制根文件系统到目标镜像..."
rsync -aHAX --info=progress2 "$ROOTFS_DIR"/ /mnt/

echo "安装 GRUB..."
arch-chroot /mnt grub-install --efi-directory=/boot/efi --removable --no-nvram
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

sync
umount -R /mnt
losetup -d "$LOOPDEV"
LOOPDEV=""

echo "=== 镜像构建完成 ==="
echo "输出文件：$IMAGE_FILE"
echo "临时根文件系统目录：$ROOTFS_DIR"
