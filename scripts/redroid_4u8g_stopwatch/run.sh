#!/usr/bin/env bash
# 在宿主机上启动一份钉死的 redroid 环境：4 颗处理器、8 吉字节内存、秒表走时 60 秒。
# 请先填写镜像摘要。不要使用会移动的 latest 标签做对比实验。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/out/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "${OUT_DIR}"

# 把下面换成 docker image inspect 得到的完整摘要，例如 redroid/redroid@sha256:....
IMAGE="${REDROID_IMAGE:-redroid/redroid:16.0.0_64only-latest}"
NAME="${REDROID_NAME:-redroid-4u8g-stopwatch}"
CPUSET="${CPUSET:-}"
RECORD_SECONDS="${RECORD_SECONDS:-60}"
ADB_PORT="${ADB_PORT:-5555}"
COLLECT_PERF="${COLLECT_PERF:-0}"

WIDTH=1280
HEIGHT=720
DPI=320
FPS=30

echo "输出目录：${OUT_DIR}"
echo "镜像：${IMAGE}"
if [[ "${IMAGE}" == *latest* ]]; then
	echo "警告：当前仍在使用会移动的标签。请改成带 sha256 的摘要后再做正式对比。" >&2
fi

if docker inspect "${NAME}" >/dev/null 2>&1; then
	echo "删除已有同名容器 ${NAME}"
	docker rm -f "${NAME}" >/dev/null
fi

echo "启动容器"
CPUSET_ARGS=()
if [[ -n "${CPUSET}" ]]; then
	CPUSET_ARGS=(--cpuset-cpus="${CPUSET}")
fi

docker run -d --name "${NAME}" --privileged \
	--cpus=4 \
	"${CPUSET_ARGS[@]}" \
	--memory=8g \
	--memory-swap=8g \
	--pull=never \
	-p "${ADB_PORT}:5555" \
	-v "${SCRIPT_DIR}/SwiftShader.ini:/data/local/tmp/SwiftShader.ini:ro" \
	"${IMAGE}" \
	androidboot.redroid_gpu_mode=guest \
	androidboot.use_memfd=true \
	"androidboot.redroid_width=${WIDTH}" \
	"androidboot.redroid_height=${HEIGHT}" \
	"androidboot.redroid_dpi=${DPI}" \
	"androidboot.redroid_fps=${FPS}"

echo "等待 adb 和开机（最多约 3 分钟）"
adb disconnect "127.0.0.1:${ADB_PORT}" >/dev/null 2>&1 || true
for _ in $(seq 1 90); do
	if adb connect "127.0.0.1:${ADB_PORT}" >/dev/null 2>&1; then
		boot="$(adb -s "127.0.0.1:${ADB_PORT}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
		if [[ "${boot}" == "1" ]]; then
			break
		fi
	fi
	sleep 2
done

ADB=(adb -s "127.0.0.1:${ADB_PORT}")
if [[ "$("${ADB[@]}" shell getprop sys.boot_completed | tr -d '\r')" != "1" ]]; then
	echo "开机超时。请查看：docker logs ${NAME}" >&2
	exit 1
fi

echo "把配置文件复制到窗口合成器的当前工作目录（若复制失败，请根据 /proc/<进程号>/cwd 手工放置）"
sf_pid="$("${ADB[@]}" shell pidof surfaceflinger | tr -d '\r' | awk '{print $1}')"
if [[ -n "${sf_pid}" ]]; then
	sf_cwd="$("${ADB[@]}" shell readlink "/proc/${sf_pid}/cwd" | tr -d '\r')"
	"${ADB[@]}" shell "cp /data/local/tmp/SwiftShader.ini '${sf_cwd}/SwiftShader.ini'" || true
fi

if [[ -f "${SCRIPT_DIR}/stopwatch.apk" ]]; then
	echo "安装 scripts/redroid_4u8g_stopwatch/stopwatch.apk"
	"${ADB[@]}" install -r "${SCRIPT_DIR}/stopwatch.apk"
fi

echo "启动秒表并开始走时"
# 较新的系统时钟使用这两个动作。若失败，请把 resolve-activity 输出留给脚本维护者。
"${ADB[@]}" shell am start -a com.android.deskclock.action.SHOW_STOPWATCH || \
	"${ADB[@]}" shell am start -n com.android.deskclock/.DeskClock || \
	"${ADB[@]}" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.android.deskclock
sleep 3
"${ADB[@]}" shell am start -a com.android.deskclock.action.START_STOPWATCH || \
	"${ADB[@]}" shell am startservice -a com.android.deskclock.action.START_STOPWATCH || true

echo "预热 ${RECORD_SECONDS} 秒（第一次即时编译，数字不记入对比）"
sleep "${RECORD_SECONDS}"

echo "重置后第二次走时，开始记数"
"${ADB[@]}" shell am start -a com.android.deskclock.action.PAUSE_STOPWATCH || true
"${ADB[@]}" shell am start -a com.android.deskclock.action.RESET_STOPWATCH || true
sleep 1
"${ADB[@]}" shell am start -a com.android.deskclock.action.START_STOPWATCH || \
	"${ADB[@]}" shell am startservice -a com.android.deskclock.action.START_STOPWATCH || true

if [[ "${COLLECT_PERF}" == "1" ]]; then
	# 宿主机上的窗口合成器进程号，不是容器内的进程号。
	host_sf="$(ps -eo pid,args | awk '/surfaceflinger/ && !/awk/ {print $1; exit}')"
	if [[ -n "${host_sf}" ]]; then
		echo "在宿主机上对窗口合成器进程 ${host_sf} 采集 ${RECORD_SECONDS} 秒"
		perf record -g -p "${host_sf}" -o "${OUT_DIR}/perf-surfaceflinger.data" -- sleep "${RECORD_SECONDS}" || true
	else
		echo "未在宿主机进程表里找到 surfaceflinger，跳过 perf。"
		sleep "${RECORD_SECONDS}"
	fi
else
	sleep "${RECORD_SECONDS}"
fi

"${ADB[@]}" shell dumpsys gfxinfo com.android.deskclock >"${OUT_DIR}/gfxinfo-deskclock.txt" || true
"${ADB[@]}" shell dumpsys SurfaceFlinger --latency >"${OUT_DIR}/sf-latency.txt" || true

{
	echo "记录时间：$(date -Is)"
	echo "容器名：${NAME}"
	echo "镜像参数：${IMAGE}"
	docker image inspect --format '镜像标识：{{.Id}} 摘要：{{json .RepoDigests}}' "${IMAGE}" 2>/dev/null || true
	echo "处理器上限：4    内存上限：8 吉字节    绑核：${CPUSET:-未指定}"
	echo "画面：${WIDTH}x${HEIGHT}  每英寸点数 ${DPI}  目标帧率 ${FPS}"
	echo "录制秒数：${RECORD_SECONDS}"
	echo "nproc：$("${ADB[@]}" shell nproc | tr -d '\r')"
	echo "MemTotal：$("${ADB[@]}" shell grep MemTotal /proc/meminfo | tr -d '\r')"
	echo "ro.hardware.vulkan：$("${ADB[@]}" shell getprop ro.hardware.vulkan | tr -d '\r')"
	echo "ro.hardware.egl：$("${ADB[@]}" shell getprop ro.hardware.egl | tr -d '\r')"
	echo "ro.build.fingerprint：$("${ADB[@]}" shell getprop ro.build.fingerprint | tr -d '\r')"
	echo "ro.build.version.incremental：$("${ADB[@]}" shell getprop ro.build.version.incremental | tr -d '\r')"
	echo "SwiftShader.ini 原文："
	cat "${SCRIPT_DIR}/SwiftShader.ini"
	if "${ADB[@]}" shell ls /vendor/lib64/hw/vulkan.pastel.so >/dev/null 2>&1; then
		"${ADB[@]}" pull /vendor/lib64/hw/vulkan.pastel.so "${OUT_DIR}/vulkan.pastel.so" >/dev/null
		echo "vulkan.pastel.so 校验和：$(sha256sum "${OUT_DIR}/vulkan.pastel.so" | awk '{print $1}')"
	fi
	if [[ -f "${SCRIPT_DIR}/stopwatch.apk" ]]; then
		echo "stopwatch.apk 校验和：$(sha256sum "${SCRIPT_DIR}/stopwatch.apk" | awk '{print $1}')"
	fi
} >"${OUT_DIR}/environment-fingerprint.txt"

echo "指纹已写入 ${OUT_DIR}/environment-fingerprint.txt"
echo "请把帧率与处理器占用填进第 0 个工作包的表格。对比换库时，指纹里除库文件校验和以外都应相同。"
