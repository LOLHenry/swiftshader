#!/usr/bin/env bash
# 删掉之前 grubby 加的 Binder 试验内核。不动正在跑的 323。
# 先看列表，再删名字里带 binder 的 vmlinuz / initramfs / 模块。

set -eu
KNOW=5.10.0-323.0.0.224.oe2203sp4.aarch64
KEEP=/boot/vmlinuz-${KNOW}

if [ "$(id -u)" -ne 0 ]; then
	echo "要用 root 跑。"
	exit 1
fi
test -f "$KEEP"
grubby --set-default "$KEEP"

echo "==== 删除前 ===="
echo "默认启动：$(grubby --default-kernel)"
grubby --info=ALL
ls -l /boot/vmlinuz-* /boot/initramfs-*.img 2>/dev/null || true
echo "模块目录："
ls /lib/modules

echo "==== 删除名字里带 binder 的内核 ===="
shopt -s nullglob
for k in /boot/vmlinuz-*binder*; do
	if [ "$k" = "$KEEP" ]; then
		continue
	fi
	echo "删除 $k"
	grubby --remove-kernel="$k" || true
	ver=${k#/boot/vmlinuz-}
	rm -f /boot/vmlinuz-"$ver" \
		/boot/initramfs-"$ver".img \
		/boot/System.map-"$ver" \
		/boot/config-"$ver"
	rm -rf /lib/modules/"$ver"
done

echo "==== 删除后 ===="
echo "默认启动：$(grubby --default-kernel)"
grubby --info=ALL
ls -l /boot/vmlinuz-*
ls /lib/modules
if [ "$(grubby --default-kernel)" != "$KEEP" ]; then
	echo "默认启动不是 323，拉回。"
	grubby --set-default "$KEEP"
fi
echo "结论：只保留 $KEEP。其他带 binder 的启动项已删。"
