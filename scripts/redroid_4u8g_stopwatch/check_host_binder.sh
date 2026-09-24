#!/usr/bin/env bash
# 在宿主机上检查 Android Binder 是否已经可用。
# 不修改系统，只打印诊断。退出码 0 表示 /proc/filesystems 里已有 binder。

set -euo pipefail

echo "内核：$(uname -r)"
if [[ -r /etc/os-release ]]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	echo "发行版：${PRETTY_NAME:-${NAME:-未知}}"
fi

echo
echo "=== Binder 文件系统 ==="
if grep -q '[[:space:]]binder$' /proc/filesystems 2>/dev/null; then
	grep binder /proc/filesystems
	binder_ok=1
else
	echo "还没有 binder。redroid 起不来。"
	echo "openEuler 22 的处理步骤见 docs/OpenEuler22Binder.zh.md"
	binder_ok=0
fi

echo
echo "=== 已加载的相关模块 ==="
if lsmod 2>/dev/null | grep -E 'binder|ashmem'; then
	true
else
	echo "当前没有加载 binder / ashmem 模块（内置进内核时这里也会是空的，只要上面有 binder 文件系统即可）。"
fi

echo
echo "=== 磁盘上的模块文件 ==="
if [[ -d /lib/modules/$(uname -r) ]]; then
	find /lib/modules/"$(uname -r)" \( -iname '*binder*' -o -iname '*ashmem*' \) -print 2>/dev/null | sed 's/^/  /' || true
	if ! find /lib/modules/"$(uname -r)" \( -iname '*binder*' -o -iname '*ashmem*' \) -print -quit 2>/dev/null | grep -q .; then
		echo "  （没有找到名字里带 binder 或 ashmem 的模块文件）"
	fi
else
	echo "没有 /lib/modules/$(uname -r)"
fi

echo
echo "=== 内核配置里的 Android / Binder / ashmem ==="
config=""
if [[ -r /proc/config.gz ]]; then
	config="/proc/config.gz"
	zgrep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' "${config}" || echo "这份配置里没有相关行"
elif [[ -r /boot/config-$(uname -r) ]]; then
	config="/boot/config-$(uname -r)"
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' "${config}" || echo "这份配置里没有相关行"
elif [[ -r /usr/src/kernels/$(uname -r)/.config ]]; then
	config="/usr/src/kernels/$(uname -r)/.config"
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' "${config}" || echo "这份配置里没有相关行"
else
	echo "找不到本机内核配置。"
fi
if [[ -n "${config}" ]]; then
	echo "（读自 ${config}）"
fi

echo
echo "=== 匿名共享内存 ashmem（秒表环境不强制） ==="
if grep -q ashmem /proc/misc 2>/dev/null; then
	grep ashmem /proc/misc
else
	echo "没有 ashmem。本仓库脚本使用 androidboot.use_memfd=true，可以没有这项。"
fi

echo
echo "=== 安全增强型 Linux ==="
if command -v getenforce >/dev/null 2>&1; then
	echo "getenforce：$(getenforce)"
	echo "若 Binder 已有而 redroid 仍起不来，测试机可先 setenforce 0，见文档第 6 节。"
else
	echo "没有 getenforce 命令。"
fi

if [[ "${binder_ok}" -eq 1 ]]; then
	echo
	echo "结论：宿主机已经提供 Binder，可以继续跑 scripts/redroid_4u8g_stopwatch/run.sh"
	exit 0
fi

echo
echo "结论：宿主机还没有 Binder。不要急着 docker run，先按 docs/OpenEuler22Binder.zh.md 处理。"
exit 1
