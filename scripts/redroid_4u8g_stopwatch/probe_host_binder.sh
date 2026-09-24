#!/usr/bin/env bash
# 在宿主机上先测 Android Binder：只诊断，必要时尝试加载已有模块。
# 不换内核、不编模块。把整段输出留下来即可。

set +e

echo "======== 1. 机器 ========"
echo "内核：$(uname -r)"
if [[ -r /etc/os-release ]]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	echo "发行版：${PRETTY_NAME:-${NAME:-未知}}"
fi
echo "架构：$(uname -m)"
date -Is 2>/dev/null || date

echo
echo "======== 2. 现在有没有 Binder ========"
if grep -E '[[:space:]]binder$' /proc/filesystems; then
	echo "结果：内核已经提供 Binder 文件系统。"
	already=1
else
	echo "结果：还没有 binder。下面会尝试加载模块。"
	already=0
fi

echo
echo "======== 3. 已加载模块 / 磁盘上的模块文件 ========"
if command -v lsmod >/dev/null 2>&1; then
	lsmod | grep -E 'binder|ashmem' || echo "当前没有加载 binder / ashmem 模块。"
else
	echo "没有 lsmod 命令。"
fi
if [[ -d /lib/modules/$(uname -r) ]]; then
	find /lib/modules/"$(uname -r)" \( -iname '*binder*' -o -iname '*ashmem*' \) -print
	if ! find /lib/modules/"$(uname -r)" \( -iname '*binder*' -o -iname '*ashmem*' \) -print -quit | grep -q .; then
		echo "磁盘上没有名字里带 binder 或 ashmem 的模块文件。"
	fi
else
	echo "没有 /lib/modules/$(uname -r)"
fi

echo
echo "======== 4. 这颗内核当初有没有把 Binder 编进去 ========"
if [[ -r /proc/config.gz ]]; then
	echo "读 /proc/config.gz"
	zgrep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /proc/config.gz || echo "这份配置里没有相关行。"
elif [[ -r /boot/config-$(uname -r) ]]; then
	echo "读 /boot/config-$(uname -r)"
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /boot/config-"$(uname -r)" || echo "这份配置里没有相关行。"
elif [[ -r /usr/src/kernels/$(uname -r)/.config ]]; then
	echo "读 /usr/src/kernels/$(uname -r)/.config"
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /usr/src/kernels/"$(uname -r)"/.config || echo "这份配置里没有相关行。"
else
	echo "找不到本机内核配置。"
fi

if [[ "${already}" -eq 0 ]]; then
	echo
	echo "======== 5. 尝试加载已有模块（没有模块时失败是正常的） ========"
	if command -v sudo >/dev/null 2>&1; then
		SUDO=sudo
	else
		SUDO=
	fi
	if command -v modprobe >/dev/null 2>&1; then
		${SUDO} modprobe binder_linux devices="binder,hwbinder,vndbinder"
		echo "modprobe binder_linux 退出码：$?"
		${SUDO} modprobe binder
		echo "modprobe binder 退出码：$?"
	else
		echo "没有 modprobe 命令。"
	fi
	echo
	echo "加载后再看一次："
	grep -E '[[:space:]]binder$' /proc/filesystems || echo "仍然没有 binder。"
	if command -v lsmod >/dev/null 2>&1; then
		lsmod | grep -E 'binder|ashmem' || echo "仍然没有相关模块挂着。"
	fi
fi

echo
echo "======== 6. 匿名共享内存 ashmem（秒表环境不强制） ========"
grep ashmem /proc/misc || echo "没有 ashmem。可继续用 androidboot.use_memfd=true。"

echo
echo "======== 7. 安全增强型 Linux ========"
if command -v getenforce >/dev/null 2>&1; then
	echo "getenforce：$(getenforce)"
else
	echo "没有 getenforce 命令。"
fi

echo
echo "======== 结论 ========"
if grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo "Binder 已经可用。下一步可以跑 redroid；若容器仍起不来，测试机先执行：sudo setenforce 0"
	exit 0
fi
echo "Binder 仍然不可用。发行版内核多半没编这项，不是服务没启动。"
echo "下一步按 docs/OpenEuler22Binder.zh.md 换一颗打开了 Binder 的内核，或对着 uname -r 一致的 kernel-devel 编模块。"
echo "不要在 5.10 上使用 redroid-modules 的 openEuler 20.03 / 4.19 分支。"
exit 1
