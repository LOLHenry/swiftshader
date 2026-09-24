#!/usr/bin/env bash
# 下载与正在跑的 323 配套的 openEuler 内核源码包，在 /home 解开并按发行版方式编 rpm。
# 不重启，不改默认启动。
# tmux 里执行：bash rebuild_oe_kernel_rpm.sh

set -eu
KNOW=5.10.0-323.0.0.224.oe2203sp4.aarch64
TOP=/home/kernel-rpm
SRPM=kernel-5.10.0-323.0.0.224.oe2203sp4.src.rpm
URL="https://repo.openeuler.org/openEuler-22.03-LTS-SP4/update/source/Packages/${SRPM}"
OLD_VMLINUZ=/boot/vmlinuz-${KNOW}
LOG=${TOP}/rebuild-rpm.log

if [ "$(uname -r)" != "$KNOW" ]; then
	echo "当前内核不是 ${KNOW}，停。"
	exit 1
fi
test -f "$OLD_VMLINUZ"
mkdir -p "${TOP}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
exec > >(tee -a "$LOG") 2>&1

echo "==== 1. 下载源码包（约 185 兆，写到 /home）===="
if [ ! -f "${TOP}/${SRPM}" ]; then
	curl -fL --max-time 600 -o "${TOP}/${SRPM}.part" "$URL"
	mv "${TOP}/${SRPM}.part" "${TOP}/${SRPM}"
fi
ls -lh "${TOP}/${SRPM}"

echo "==== 2. 安装编 rpm 的依赖 ===="
dnf --setopt=cachedir=/home/dnf-cache install -y rpm-build yum-utils gcc make flex bison \
	elfutils-libelf-devel openssl-devel bc rsync dwarves perl hostname
dnf --setopt=cachedir=/home/dnf-cache builddep -y "${TOP}/${SRPM}" || \
	yum-builddep -y "${TOP}/${SRPM}" || true

echo "==== 3. 解开并打上发行版补丁 ===="
rpm -ivh --define "_topdir ${TOP}" "${TOP}/${SRPM}"
rpmbuild --define "_topdir ${TOP}" -bp "${TOP}/SPECS/kernel.spec"

echo "==== 4. 找到解开后的源码和配置 ===="
find "${TOP}/BUILD" -name Makefile -path '*linux*' | head
find "${TOP}/BUILD" "${TOP}/SOURCES" -name 'kernel-*.config' -o -name '*aarch64*.config' | head -n 20

echo "接下来要在这份干净源码的配置里只打开 ANDROID Binder，再 rpmbuild -bb。"
echo "源码包已就绪。日志：${LOG}"
echo "默认启动不要动。编完 rpm 后用 rpm -ivh 加装，不要 -U 覆盖 323。"
