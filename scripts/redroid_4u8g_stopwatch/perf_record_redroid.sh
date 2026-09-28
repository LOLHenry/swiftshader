#!/usr/bin/env bash
# 对正在跑的 redroid 采用户态 perf，同时按秒记下可执行 maps（给 JIT 地址对时段，不要事后 grep 当前 maps）。
# 每次输出到带时间戳的新目录，不会覆盖上次。
#
# 用法（秒表继续走）：
#   NAME=redroid-4c8g RECORD_SECONDS=60 ./perf_record_redroid.sh

set -euo pipefail

NAME="${NAME:-${REDROID_NAME:-redroid-4c8g}}"
RECORD_SECONDS="${RECORD_SECONDS:-60}"
MAP_INTERVAL="${MAP_INTERVAL:-1}"
FREQ="${FREQ:-99}"
FG="${FG:-/home/f00589393/redroid-build/FlameGraph-master}"
OUT="${OUT:-/home/f00589393/perf-redroid/$(date +%Y%m%d-%H%M%S)}"

if ! docker inspect "${NAME}" >/dev/null 2>&1; then
	echo "没有容器 ${NAME}。docker ps 看名字，或 NAME=... $0" >&2
	exit 1
fi
if ! command -v perf >/dev/null 2>&1; then
	echo "未找到 perf。openEuler：yum install -y perf OpenCSD babeltrace" >&2
	exit 1
fi
missing="$(ldd "$(command -v perf)" 2>/dev/null | awk '/not found/' || true)"
if [[ -n "${missing}" ]]; then
	echo "perf 缺共享库：yum install -y OpenCSD babeltrace" >&2
	echo "${missing}" >&2
	exit 1
fi

mkdir -p "${OUT}/maps"
echo "输出目录：${OUT}"
echo "容器：${NAME}  时长：${RECORD_SECONDS}s  maps 间隔：${MAP_INTERVAL}s"

sysctl -w kernel.kptr_restrict=0 kernel.perf_event_paranoid=-1 >/dev/null

PIDS="$(docker top "${NAME}" -eo pid | awk 'NR>1{printf "%s%s", (n++?",":""), $1}')"
if [[ -z "${PIDS}" ]]; then
	echo "docker top 没有 pid" >&2
	exit 1
fi
echo "${PIDS}" | tr ',' '\n' >"${OUT}/pids.txt"
echo "进程数：$(wc -l <"${OUT}/pids.txt")"

dump_maps() {
	local tag="$1"
	local dest="${OUT}/maps/${tag}.txt"
	{
		echo "==== ${tag} $(date -Is) ===="
		tr ',' '\n' <"${OUT}/pids.txt" | while read -r pid; do
			[[ -r "/proc/${pid}/maps" ]] || continue
			comm="$(tr -d '\0' <"/proc/${pid}/comm" 2>/dev/null || echo '?')"
			echo "----- pid=${pid} comm=${comm} -----"
			# 只记可执行映射，完整 maps 太大。JIT 是 r-xp 匿名页。
			awk '$2 ~ /x/' "/proc/${pid}/maps"
		done
	} >"${dest}"
}

dump_maps "t0"
(
	n=1
	while sleep "${MAP_INTERVAL}"; do
		dump_maps "$(printf 't%02d' "${n}")"
		n=$((n + 1))
	done
) &
MAP_PID=$!
cleanup() {
	kill "${MAP_PID}" 2>/dev/null || true
	wait "${MAP_PID}" 2>/dev/null || true
	dump_maps "tend"
}
trap cleanup EXIT

echo "开始 perf record ${RECORD_SECONDS}s（用户态 + fp，不采内核）"
perf record --call-graph fp -e cpu-clock:u -F "${FREQ}" -p "${PIDS}" \
	-o "${OUT}/perf.data" -- sleep "${RECORD_SECONDS}"

# EXIT trap 会停 maps 循环并再写一份 tend

SF=""
while read -r pid; do
	comm="$(tr -d '\0' <"/proc/${pid}/comm" 2>/dev/null || true)"
	if [[ "${comm}" == "surfaceflinger" ]]; then
		SF="${pid}"
		break
	fi
done <"${OUT}/pids.txt"

SYM=()
if [[ -n "${SF}" && -d "/proc/${SF}/root/system" ]]; then
	SYM=(--symfs "/proc/${SF}/root")
	echo "SYMFS=/proc/${SF}/root"
fi

{
	echo "容器：${NAME}"
	echo "时间：$(date -Is)"
	echo "秒数：${RECORD_SECONDS}  频率：${FREQ}  maps间隔：${MAP_INTERVAL}"
	echo "CpusetCpus=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "${NAME}")"
	echo "NanoCpus=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${NAME}")"
	docker exec "${NAME}" nproc 2>/dev/null | awk '{print "nproc="$1}' || true
} >"${OUT}/meta.txt"

perf report -i "${OUT}/perf.data" --stdio --no-children --percent-limit 0.5 \
	--sort comm,dso "${SYM[@]}" 2>/dev/null | head -80 >"${OUT}/report-dso.txt" || true
perf report -i "${OUT}/perf.data" --stdio --no-children --percent-limit 0.5 \
	--sort comm "${SYM[@]}" 2>/dev/null | head -40 >"${OUT}/report-comm.txt" || true
perf script -i "${OUT}/perf.data" --show-mmap-events 2>/dev/null \
	>"${OUT}/mmap-events.txt" || true

if [[ -f "${FG}/stackcollapse-perf.pl" && -f "${FG}/flamegraph.pl" ]]; then
	perf script -i "${OUT}/perf.data" "${SYM[@]}" 2>/dev/null \
		| perl "${FG}/stackcollapse-perf.pl" \
		| perl "${FG}/flamegraph.pl" --title "${NAME} cpu-clock:u" \
		>"${OUT}/flame.svg" || true
	echo "火焰图：${OUT}/flame.svg"
fi

echo "maps：${OUT}/maps/   （t0 … tend，和采样同时段）"
echo "对 JIT 地址：grep -i <地址前几位> ${OUT}/maps/*.txt ${OUT}/mmap-events.txt"
ls -lh "${OUT}/perf.data" "${OUT}/maps" | sed -n '1,20p'
