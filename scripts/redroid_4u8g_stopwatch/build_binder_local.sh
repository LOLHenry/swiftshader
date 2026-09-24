#!/usr/bin/env bash
# 完整内核源码已在 /usr/src/linux-$(uname -r) 时使用。
# .c 拷到 /home 再对着 kernel-devel 编成一个 binder_linux.ko，当场加载。
# 必须用：bash /path/to/build_binder_local.sh
# 不要把本文件内容直接贴进登录 shell。

set -eu
KVER="$(uname -r)"
EXPECT_KVER="${EXPECT_KVER:-5.10.0-323.0.0.224.oe2203sp4.aarch64}"
LINUX="${LINUX:-/usr/src/linux-${KVER}}"
KDIR="${KDIR:-/usr/src/kernels/${KVER}}"
WORK="${WORK:-/home/redroid-binder-build}"
SRC="${WORK}/src"

echo "内核：${KVER}"
echo "源码：${LINUX}/drivers/android"
echo "编译目录：${KDIR}"

if [[ "${KVER}" != "${EXPECT_KVER}" ]]; then
	echo "uname -r 是 ${KVER}，和约定的 ${EXPECT_KVER} 不一致，停。"
	exit 1
fi

test -f "${LINUX}/drivers/android/binder.c"
test -f "${LINUX}/drivers/android/binder_alloc.c"
test -f "${LINUX}/drivers/android/binderfs.c"
test -f "${KDIR}/Makefile"

if ! grep -qE '[[:space:]]binder$' /proc/filesystems; then
	rm -rf "${SRC}"
	mkdir -p "${SRC}"
	cp -a "${LINUX}/drivers/android/." "${SRC}/"
	cd "${SRC}"
	# 只改副本。不要用含 */ 的替换，避免粘贴或注释把后面的 do 吃掉。
	find . -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) -print | while read -r f; do
		sed -i \
			-e 's/CONFIG_ANDROID_BINDER_DEVICES/CONFIG_BINDER_DEVICES_OOT/g' \
			-e 's/#ifdef CONFIG_ANDROID_BINDERFS/#if 1/g' \
			"${f}"
	done
	{
		echo 'ccflags-y += -I$(src)'
		echo 'ccflags-y += -DCONFIG_BINDER_DEVICES_OOT=\"binder,hwbinder,vndbinder\"'
		echo 'obj-m := binder_linux.o'
		echo 'binder_linux-y := binder.o binder_alloc.o binderfs.o'
	} > Makefile
	make -C "${KDIR}" M="${SRC}" modules
	test -f "${SRC}/binder_linux.ko"
	modinfo "${SRC}/binder_linux.ko" | sed -n '1,12p'
	sudo mkdir -p "/lib/modules/${KVER}/extra"
	sudo cp -f "${SRC}/binder_linux.ko" "/lib/modules/${KVER}/extra/"
	sudo depmod -a
	sudo insmod "${SRC}/binder_linux.ko" \
		|| sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
fi

echo "======== 验收文件系统 ========"
if ! grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo "仍然没有 binder 文件系统。不要关版本检查硬装。"
	dmesg | tail -n 30
	exit 1
fi
grep binder /proc/filesystems

echo "======== 挂 binderfs 并补设备节点 ========"
sudo mkdir -p /dev/binderfs
if ! mountpoint -q /dev/binderfs; then
	sudo mount -t binder binder /dev/binderfs
fi

if [[ ! -e /dev/binder || ! -e /dev/hwbinder || ! -e /dev/vndbinder ]]; then
	{
		echo '#include <fcntl.h>'
		echo '#include <stdio.h>'
		echo '#include <string.h>'
		echo '#include <unistd.h>'
		echo '#include <sys/ioctl.h>'
		echo '#include <linux/android/binderfs.h>'
		echo 'int main(int argc, char **argv) {'
		echo '	struct binderfs_device dev;'
		echo '	int fd, i;'
		echo '	if (argc < 3) return 2;'
		echo '	fd = open(argv[1], O_RDONLY);'
		echo '	if (fd < 0) { perror("open"); return 1; }'
		echo '	for (i = 2; i < argc; i++) {'
		echo '		memset(&dev, 0, sizeof(dev));'
		echo '		snprintf(dev.name, sizeof(dev.name), "%s", argv[i]);'
		echo '		if (ioctl(fd, BINDER_CTL_ADD, &dev) < 0) perror(argv[i]);'
		echo '		else printf("added %s %u:%u\\n", dev.name, dev.major, dev.minor);'
		echo '	}'
		echo '	return close(fd);'
		echo '}'
	} > /tmp/add_binder_node.c
	gcc -O2 -o /tmp/add_binder_node /tmp/add_binder_node.c
	sudo /tmp/add_binder_node /dev/binderfs/binder-control binder hwbinder vndbinder
	sudo ln -sfn /dev/binderfs/binder /dev/binder
	sudo ln -sfn /dev/binderfs/hwbinder /dev/hwbinder
	sudo ln -sfn /dev/binderfs/vndbinder /dev/vndbinder
fi
sudo chmod 666 /dev/binder /dev/hwbinder /dev/vndbinder 2>/dev/null || true

echo "======== 最终检查 ========"
grep binder /proc/filesystems
mount | grep binder || true
ls -l /dev/binder /dev/hwbinder /dev/vndbinder /dev/binderfs

if [[ -e /dev/binder && -e /dev/hwbinder && -e /dev/vndbinder ]] && grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo binder_linux | sudo tee /etc/modules-load.d/binder.conf >/dev/null
	echo 'options binder_linux devices=binder,hwbinder,vndbinder' | sudo tee /etc/modprobe.d/binder.conf >/dev/null
	echo "结论：Binder 已可用，可以起 redroid。不需要重启。"
	exit 0
fi
echo "结论：文件系统或设备节点未齐。把上面输出留下来。"
exit 1
