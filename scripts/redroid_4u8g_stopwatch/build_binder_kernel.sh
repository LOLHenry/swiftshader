#!/usr/bin/env bash
# 用已安装的 kernel-source 编一颗带 Binder 的内核并加启动项。
# 不在 /usr/src 里编译，不重启，不改默认启动（仍指向正在跑的 323）。
# tmux 里执行：bash /path/to/build_binder_kernel.sh

set -eu
KNOW=5.10.0-323.0.0.224.oe2203sp4.aarch64
PKG=/usr/src/linux-${KNOW}
SRC=/home/linux-${KNOW}
OUT=/home/kbuild
LOG=/home/kbuild/rebuild.log
OLD_VMLINUZ=/boot/vmlinuz-${KNOW}
CC=/usr/bin/gcc
test -x "$CC" || CC=$(command -v gcc)

if [ "$(id -u)" -ne 0 ]; then
	echo "要用 root 跑。"
	exit 1
fi
if [ "$(uname -r)" != "$KNOW" ]; then
	echo "当前内核不是 $KNOW，停。现在是 $(uname -r)"
	exit 1
fi
test -f "$OLD_VMLINUZ"
test -f /boot/config-${KNOW}
test -f "$PKG/Makefile"
test -f "$PKG/drivers/android/binder.c"

echo "==== 磁盘 ===="
df -hT / /boot /home /usr
avail_home=$(df -P /home | awk 'NR==2 { print $4 }')
if [ "${avail_home}" -lt $((20 * 1024 * 1024)) ]; then
	echo "/home 空闲不足 20G，停。"
	exit 1
fi

dnf --setopt=cachedir=/home/dnf-cache install -y gcc make flex bison \
	elfutils-libelf-devel openssl-devel bc rsync dwarves dracut || \
	yum install -y gcc make flex bison elfutils-libelf-devel openssl-devel \
		bc rsync dwarves dracut

mkdir -p "$OUT"
# 不要沿用上次失败的目标文件
find "$OUT" -mindepth 1 -maxdepth 1 ! -name rebuild.log -exec rm -rf {} +
exec > >(tee -a "$LOG") 2>&1

echo "编译器：$CC $($CC -dumpversion)"
echo "软件包源码：$PKG"
echo "工作源码：$SRC"
echo "输出：$OUT"

echo "==== 拷贝 kernel-source 到 /home（不在 /usr/src 里 make）===="
mkdir -p "$SRC"
rsync -a --delete "$PKG/" "$SRC/"

# 还原 5.10 内置编法。现场若把 Makefile 改成了 binder_linux，内置编译会缺 .o
cat > "$SRC/drivers/android/Makefile" <<'MK'
# SPDX-License-Identifier: GPL-2.0-only
ccflags-y := -I$(src)

obj-$(CONFIG_ANDROID_BINDERFS)			+= binderfs.o
obj-$(CONFIG_ANDROID_BINDER_IPC)		+= binder.o binder_alloc.o
obj-$(CONFIG_ANDROID_BINDER_IPC_SELFTEST)	+= binder_alloc_selftest.o
MK

if [ -e "$SRC/.config" ] || [ -e "$SRC/include/config/auto.conf" ]; then
	echo "工作源码树不干净，mrproper（只清 $SRC，不动 $PKG）"
	make -C "$SRC" mrproper
fi

# 版本号必须带 323 和 binder，避免再变成 5.10.0-binder
rm -f "$SRC"/localversion "$SRC"/localversion-*
EV=$(sed -n 's/^EXTRAVERSION[[:space:]]*=[[:space:]]*//p' "$SRC/Makefile" | tr -d '[:space:]')
echo "Makefile EXTRAVERSION='${EV}'"
if echo "x${EV}" | grep -q 323; then
	echo '-binder' > "$SRC/localversion"
else
	echo '-323.0.0.224.oe2203sp4-binder.aarch64' > "$SRC/localversion"
fi
echo "localversion=$(cat "$SRC/localversion")"
if [ -f "$SRC/.scmversion" ]; then
	echo "scmversion=$(cat "$SRC/.scmversion")"
fi

cp -f /boot/config-${KNOW} "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" --enable ANDROID --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS
"$SRC/scripts/config" --file "$OUT/.config" --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
"$SRC/scripts/config" --file "$OUT/.config" --disable ANDROID_BINDER_IPC_SELFTEST
"$SRC/scripts/config" --file "$OUT/.config" --disable GCC_PLUGINS

make -C "$SRC" O="$OUT" CC="$CC" olddefconfig
"$SRC/scripts/config" --file "$OUT/.config" --disable GCC_PLUGINS
"$SRC/scripts/config" --file "$OUT/.config" --enable ANDROID --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS
"$SRC/scripts/config" --file "$OUT/.config" --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
make -C "$SRC" O="$OUT" CC="$CC" olddefconfig

echo "---- 关键配置 ----"
grep -E 'CONFIG_ANDROID|GCC_PLUGINS|LOCALVERSION' "$OUT/.config"

if ! grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$OUT/.config"; then
	echo "Binder 没有编进内核，停。"
	exit 1
fi
if ! grep -q '^CONFIG_ANDROID_BINDERFS=y$' "$OUT/.config"; then
	echo "BINDERFS 没打开，停。"
	exit 1
fi

KREL=$(make -s -C "$SRC" O="$OUT" CC="$CC" kernelrelease)
echo "内核发布名：$KREL"
case "$KREL" in
	*323*binder*) ;;
	*)
		echo "发布名不像 323-binder（得到 $KREL），停。不要装。"
		exit 1
		;;
esac

echo "---- 编译 Image + 模块 ----"
make -C "$SRC" O="$OUT" CC="$CC" -j64 Image modules
test -f "$OUT/arch/arm64/boot/Image"

KREL=$(cat "$OUT/include/config/kernel.release")
echo "编译后发布名：$KREL"
case "$KREL" in
	*323*binder*) ;;
	*)
		echo "发布名不像 323-binder，停。不要装。"
		exit 1
		;;
esac

echo "---- 安装模块 ----"
make -C "$SRC" O="$OUT" CC="$CC" modules_install
test -d "/lib/modules/$KREL"

echo "---- 对照发行版 vmlinuz 格式，打 gzip ----"
echo "发行版：$(file "$OLD_VMLINUZ")"
NEW_VMLINUZ=/boot/vmlinuz-${KREL}
if [ -f "$OUT/arch/arm64/boot/Image.gz" ]; then
	cp -f "$OUT/arch/arm64/boot/Image.gz" "$NEW_VMLINUZ"
else
	gzip -9 -c "$OUT/arch/arm64/boot/Image" > "$NEW_VMLINUZ"
fi
chmod 755 "$NEW_VMLINUZ"
echo "新品：$(file "$NEW_VMLINUZ")"
file "$NEW_VMLINUZ" | grep -q 'gzip compressed' || {
	echo "vmlinuz 不是 gzip，停。"
	exit 1
}

echo "---- 生成初始化内存盘 ----"
NEW_INITRD=/boot/initramfs-${KREL}.img
dracut -f --kver "$KREL" "$NEW_INITRD"
test -s "$NEW_INITRD"

echo "---- 写启动项，默认仍指向 323 ----"
grubby --remove-kernel="$NEW_VMLINUZ" 2>/dev/null || true
grubby --add-kernel="$NEW_VMLINUZ" \
	--title="openEuler ${KREL} (binder gzip)" \
	--initrd="$NEW_INITRD" \
	--copy-default
grubby --set-default "$OLD_VMLINUZ"

echo "==== 验收（未重启）===="
uname -r
file "$NEW_VMLINUZ"
file "$OLD_VMLINUZ"
ls -l "$NEW_VMLINUZ" "$OLD_VMLINUZ" "$NEW_INITRD"
echo "默认启动：$(grubby --default-kernel)"
grubby --info="$NEW_VMLINUZ"
echo "当前内核启动参数：$(cat /proc/cmdline)"
if [ "$(grubby --default-kernel)" != "$OLD_VMLINUZ" ]; then
	echo "默认启动不是 323，已尝试拉回。请人工确认。"
	grubby --set-default "$OLD_VMLINUZ"
fi
echo "结论：装好了，默认仍是 323。要试新内核：BMC 控制台打开后，grubby --set-default $NEW_VMLINUZ && reboot"
echo "失败则 BMC 选回 $KNOW，再 grubby --set-default $OLD_VMLINUZ"
echo "日志：$LOG"
