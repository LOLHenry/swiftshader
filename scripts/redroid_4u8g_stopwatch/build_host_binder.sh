#!/usr/bin/env bash
# 探测已确认没有 Binder 之后：对着正在跑的内核，在树外编 binder_linux.ko 并尝试加载。
# Linux 5.10 上游把 Android Binder 写成 bool，不能 make M=drivers/android 当模块。
# 本脚本把 binder.c / binder_alloc.c / binderfs.c 拼成一个外部模块。
# 日志：${LOG:-$HOME/redroid-binder-build/build.log}

set -u
umask 022

WORK="${WORK:-$HOME/redroid-binder-build}"
LOG="${LOG:-${WORK}/build.log}"
KVER="$(uname -r)"
KDIR="${KDIR:-/lib/modules/${KVER}/build}"
SRC="${WORK}/src"
mkdir -p "${SRC}"
exec > >(tee -a "${LOG}") 2>&1

echo "======== 树外编 Binder ========"
echo "时间：$(date -Is 2>/dev/null || date)"
echo "内核：${KVER}  架构：$(uname -m)"
echo "工作目录：${WORK}"
echo "内核开发树：${KDIR}"

if grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo "已经有 binder 文件系统，不必再编。"
	exit 0
fi

if [[ -r /boot/config-${KVER} ]] && grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' /boot/config-"${KVER}"; then
	echo "正在跑的内核把 Binder 编成了内置，却没有文件系统登记。先核对是否跑错了内核，不要再叠模块。"
	exit 1
fi

echo
echo "======== 安装和 ${KVER} 一致的编译依赖 ========"
if ! command -v yum >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
	echo "没有 yum / dnf。这套命令针对 openEuler。"
	exit 1
fi
PKG=yum
command -v dnf >/dev/null 2>&1 && PKG=dnf
sudo "${PKG}" install -y gcc make tar findutils elfutils-libelf-devel openssl-devel \
	"kernel-devel-uname-r == ${KVER}"
echo "kernel-devel 安装退出码：$?"

if [[ ! -d "${KDIR}" ]]; then
	if [[ -d /usr/src/kernels/${KVER} ]]; then
		KDIR="/usr/src/kernels/${KVER}"
		echo "改用 ${KDIR}"
	else
		echo "找不到与 ${KVER} 一致的 kernel-devel。"
		echo "请：yum search kernel-devel --showduplicates | grep ${KVER}"
		echo "或到 https://repo.openeuler.org/ 对应版本的 update 目录下载同名 rpm。"
		exit 1
	fi
fi
echo "KDIR=${KDIR}"
test -f "${KDIR}/Makefile" || { echo "KDIR 里没有 Makefile"; exit 1; }

echo
echo "======== 收集 5.10 的 Binder 源文件 ========"
need_files="binder.c binder_alloc.c binder_alloc.h binder_internal.h binder_trace.h binderfs.c"
have_all=1
for f in ${need_files}; do
	if [[ ! -s "${SRC}/${f}" ]]; then
		have_all=0
		break
	fi
done

if [[ "${have_all}" -eq 0 ]]; then
	found="$(find "${KDIR}" /usr/src/kernels /usr/src/linux-"${KVER}" \
		-path '*drivers/android/binder.c' 2>/dev/null | head -n 1 || true)"
	if [[ -n "${found}" ]]; then
		echo "从本机内核树拷贝：$(dirname "${found}")"
		cp -a "$(dirname "${found}")/." "${SRC}/"
	fi
fi

have_all=1
for f in ${need_files}; do
	if [[ ! -s "${SRC}/${f}" ]]; then
		have_all=0
		break
	fi
done

if [[ "${have_all}" -eq 0 ]]; then
	echo "本机没有完整源文件，尝试拉取与正在跑的内核匹配的源码包。"
	sudo "${PKG}" install -y yum-utils rpm-build 2>/dev/null || true
	cd "${WORK}"
	if command -v yumdownloader >/dev/null 2>&1; then
		yumdownloader --source "kernel-${KVER%.*}" 2>/dev/null \
			|| yumdownloader --source kernel || true
	fi
	if command -v dnf >/dev/null 2>&1; then
		dnf download --source "kernel-${KVER}" 2>/dev/null \
			|| dnf download --source kernel || true
	fi
	srpm="$(ls -1 "${WORK}"/kernel-*.src.rpm 2>/dev/null | head -n 1 || true)"
	if [[ -n "${srpm}" ]]; then
		echo "解开 ${srpm}"
		mkdir -p "${WORK}/srpm"
		(cd "${WORK}/srpm" && rpm2cpio "${srpm}" | cpio -idm)
		tarball="$(find "${WORK}/srpm" -name 'linux-*.tar.*' | head -n 1 || true)"
		if [[ -n "${tarball}" ]]; then
			mkdir -p "${WORK}/ksrc"
			tar -xf "${tarball}" -C "${WORK}/ksrc" --wildcards '*/drivers/android/*' --strip-components=1 || \
				tar -xf "${tarball}" -C "${WORK}/ksrc"
			if [[ -f "${WORK}/ksrc/drivers/android/binder.c" ]]; then
				cp -a "${WORK}/ksrc/drivers/android/." "${SRC}/"
			fi
		fi
	fi
fi

have_all=1
for f in ${need_files}; do
	if [[ ! -s "${SRC}/${f}" ]]; then
		echo "仍缺 ${f}"
		have_all=0
	fi
done

if [[ "${have_all}" -eq 0 ]]; then
	echo "最后一招：从 Linux 5.10 官方树下载同名文件。这和 openEuler 补丁可能不完全一致，编不过就改换整颗内核。"
	base="https://raw.githubusercontent.com/torvalds/linux/v5.10/drivers/android"
	cd "${SRC}"
	for f in ${need_files}; do
		if [[ ! -s "${f}" ]]; then
			curl -fsSL -o "${f}" "${base}/${f}" || wget -q -O "${f}" "${base}/${f}" || true
		fi
	done
fi

echo "源文件清单："
ls -l "${SRC}"

for f in binder.c binder_alloc.c binderfs.c; do
	if [[ ! -s "${SRC}/${f}" ]]; then
		echo "没有 ${f}，无法继续。把 ${LOG} 留下来。"
		exit 1
	fi
done

echo
echo "======== 改成可当外部模块编译（避开 autoconf.h 里的 #undef） ========"
# 正在跑的内核没打开 ANDROID_*，autoconf.h 会 #undef 这些宏，-D 会被冲掉。
# 换成我们自己的宏名，并把 binderfs 的条件编译打开。
cd "${SRC}"
for f in *.c *.h; do
	[[ -f "${f}" ]] || continue
	sed -i \
		-e 's/CONFIG_ANDROID_BINDER_DEVICES/CONFIG_BINDER_DEVICES_OOT/g' \
		-e 's/#ifdef CONFIG_ANDROID_BINDERFS/#if 1 \/* CONFIG_ANDROID_BINDERFS *\//g' \
		-e 's/#ifndef CONFIG_ANDROID_BINDERFS/#if 0 \/* !CONFIG_ANDROID_BINDERFS *\//g' \
		"${f}"
done

cat > "${SRC}/Makefile" <<'MAKE'
ccflags-y += -I$(src)
ccflags-y += -DCONFIG_BINDER_DEVICES_OOT=\"binder,hwbinder,vndbinder\"
obj-m := binder_linux.o
binder_linux-y := binder.o binder_alloc.o binderfs.o
MAKE

echo
echo "======== 编译 ========"
make -C "${KDIR}" M="${SRC}" modules
echo "make 退出码：$?"
if [[ ! -f "${SRC}/binder_linux.ko" ]]; then
	echo "没有生成 binder_linux.ko。到这里就停，不要硬装。把 ${LOG} 留下来，下一步换整颗内核。"
	exit 1
fi
modinfo "${SRC}/binder_linux.ko" || true

echo
echo "======== 加载 ========"
sudo mkdir -p "/lib/modules/${KVER}/extra"
sudo cp -f "${SRC}/binder_linux.ko" "/lib/modules/${KVER}/extra/"
sudo depmod -a
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" \
	|| sudo insmod "${SRC}/binder_linux.ko"

echo
echo "======== 验收 ========"
grep -E '[[:space:]]binder$' /proc/filesystems || echo "仍然没有 binder。"
lsmod | grep binder || echo "lsmod 里没有 binder。"
dmesg | tail -n 30

if grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo "binder_linux" | sudo tee /etc/modules-load.d/binder.conf
	echo 'options binder_linux devices=binder,hwbinder,vndbinder' | sudo tee /etc/modprobe.d/binder.conf
	echo
	echo "结论：Binder 已经可用。可以去起 redroid。若容器仍失败，测试机先：sudo setenforce 0"
	exit 0
fi

echo
echo "结论：模块没能让内核提供 Binder。不要关版本检查硬装。"
echo "日志：${LOG}"
echo "下一步：按 docs/OpenEuler22Binder.zh.md 第 3 节，用打开了 CONFIG_ANDROID_BINDER_IPC=y 的 5.10 内核替换当前内核。"
exit 1
