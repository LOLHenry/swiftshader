#!/usr/bin/env bash
# 在 openEuler 22 / 鲲鹏上编一颗带 Binder 的内核并装好启动项。
# 不重启、不改默认启动（仍指向正在跑的 323）。
# 用法：tmux 里  bash /path/to/build_binder_kernel.sh

set -eu
KNOW=5.10.0-323.0.0.224.oe2203sp4.aarch64
SRC=/usr/src/linux-$(uname -r)
OUT=/home/kbuild
LOG=/home/kbuild/rebuild.log
OLD_VMLINUZ=/boot/vmlinuz-${KNOW}
CC=/usr/bin/gcc
test -x "$CC" || CC=$(command -v gcc)

if [ "$(uname -r)" != "$KNOW" ]; then
	echo "当前内核不是 $KNOW，停。现在是 $(uname -r)"
	exit 1
fi
test -f "$OLD_VMLINUZ"
test -f /boot/config-${KNOW}
test -f "$SRC/Makefile"
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1

echo "编译器：$CC $($CC -dumpversion)"
echo "源码：$SRC"
echo "输出：$OUT"

# 版本号跟 323 对齐，只加 -binder，避免再变成 5.10.0-binder
echo '-323.0.0.224.oe2203sp4-binder.aarch64' > "$SRC/localversion"
# 不要在 make 命令行再传 LOCALVERSION

cp -f /boot/config-${KNOW} "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" --enable ANDROID --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS
"$SRC/scripts/config" --file "$OUT/.config" --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
"$SRC/scripts/config" --file "$OUT/.config" --disable ANDROID_BINDER_IPC_SELFTEST
"$SRC/scripts/config" --file "$OUT/.config" --disable GCC_PLUGINS

make -C "$SRC" O="$OUT" CC="$CC" olddefconfig
"$SRC/scripts/config" --file "$OUT/.config" --disable GCC_PLUGINS
make -C "$SRC" O="$OUT" CC="$CC" olddefconfig

echo "---- 关键配置 ----"
grep -E 'CONFIG_ANDROID|GCC_PLUGINS|LOCALVERSION' "$OUT/.config"

if ! grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' "$OUT/.config"; then
	echo "Binder 没有编进内核，停。"
	exit 1
fi

# 源码树必须干净，否则 O= 会失败
if [ -e "$SRC/.config" ] || [ -e "$SRC/include/config/auto.conf" ]; then
	echo "源码树不干净，做 mrproper（只清源码树，不清 $OUT）"
	make -C "$SRC" mrproper
	echo '-323.0.0.224.oe2203sp4-binder.aarch64' > "$SRC/localversion"
fi

# 若 Makefile 被改成缺 .o 的 binder_linux，补上
if grep -q 'binder_linux$' "$SRC/drivers/android/Makefile" 2>/dev/null; then
	sed -i 's/obj-\$(CONFIG_ANDROID_BINDER_IPC) += binder_linux$/obj-$(CONFIG_ANDROID_BINDER_IPC) += binder_linux.o/' "$SRC/drivers/android/Makefile"
fi

echo "---- 编译 Image + 模块 ----"
make -C "$SRC" O="$OUT" CC="$CC" -j64 Image modules
test -f "$OUT/arch/arm64/boot/Image"

KREL=$(cat "$OUT/include/config/kernel.release")
echo "内核发布名：$KREL"
case "$KREL" in
	*323*binder*) ;;
	*) echo "发布名不像 323-binder，停。不要装。"; exit 1 ;;
esac

echo "---- 安装模块 ----"
make -C "$SRC" O="$OUT" CC="$CC" modules_install
test -d "/lib/modules/$KREL"

echo "---- 按发行版方式打 gzip vmlinuz ----"
NEW_VMLINUZ=/boot/vmlinuz-${KREL}
gzip -9 -c "$OUT/arch/arm64/boot/Image" > "$NEW_VMLINUZ"
chmod 755 "$NEW_VMLINUZ"
file "$NEW_VMLINUZ" | grep -q 'gzip compressed' || { echo "vmlinuz 不是 gzip，停。"; exit 1; }

echo "---- 生成初始化内存盘 ----"
NEW_INITRD=/boot/initramfs-${KREL}.img
if command -v dracut >/dev/null; then
	dracut -f --kver "$KREL" "$NEW_INITRD"
else
	echo "没有 dracut，停。"
	exit 1
fi
test -s "$NEW_INITRD"

echo "---- 写启动项，默认仍指向 323 ----"
grubby --remove-kernel="$NEW_VMLINUZ" 2>/dev/null || true
grubby --add-kernel="$NEW_VMLINUZ" --title="openEuler ${KREL} (binder gzip)" --initrd="$NEW_INITRD" --copy-default
grubby --set-default "$OLD_VMLINUZ"

echo "==== 验收（未重启）===="
uname -r
file "$NEW_VMLINUZ"
ls -l "$NEW_VMLINUZ" "$OLD_VMLINUZ" "$NEW_INITRD"
echo "默认启动：$(grubby --default-kernel)"
grubby --info="$NEW_VMLINUZ"
if [ "$(grubby --default-kernel)" != "$OLD_VMLINUZ" ]; then
	echo "默认启动不是 323，已尝试拉回。请人工确认。"
	grubby --set-default "$OLD_VMLINUZ"
fi
echo "结论：装好了，默认仍是 323。要试新内核：BMC 控制台打开后，grubby --set-default $NEW_VMLINUZ && reboot"
echo "失败则 BMC 选回 $KNOW，再 grubby --set-default $OLD_VMLINUZ"
