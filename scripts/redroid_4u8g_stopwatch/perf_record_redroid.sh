#!/usr/bin/env bash
# 对正在跑的 redroid 采用户态 perf，同时按秒记下可执行 maps（给 JIT 地址对时段，不要事后 grep 当前 maps）。
# 每次输出到带时间戳的新目录，不会覆盖上次。
#
# 用法（秒表继续走）：
#   NAME=redroid-4c8g RECORD_SECONDS=60 ./perf_record_redroid.sh
#
# 默认仍是 cpu-clock:u（只用户态）。系统态对照看 cpu-time-delta.txt，不要和火焰图百分比直接相加。
# 想连内核栈一起采（自编译内核上可能再段错误）：INCLUDE_KERNEL=1 ./perf_record_redroid.sh
#
# 官方镜像里的 vulkan.pastel.so 没有 .symtab（函数名表被裁掉），perf 只能看到库名和地址。
# 要让采样尽量齐：先换成未裁剪的 so 再采（见脚本末尾说明），JIT 像素函数仍要 /tmp/perf-PID.map。
# 若已有一份和容器内同构建的未裁剪 so：
#   UNSTRIPPED_PASTEL=/path/to/vulkan.pastel.so ./perf_record_redroid.sh

set -euo pipefail

NAME="${NAME:-${REDROID_NAME:-redroid-4c8g}}"
RECORD_SECONDS="${RECORD_SECONDS:-60}"
MAP_INTERVAL="${MAP_INTERVAL:-1}"
FREQ="${FREQ:-99}"
FG="${FG:-/home/f00589393/redroid-build/FlameGraph-master}"
OUT="${OUT:-/home/f00589393/perf-redroid/$(date +%Y%m%d-%H%M%S)}"
INCLUDE_KERNEL="${INCLUDE_KERNEL:-0}"
if [[ "${INCLUDE_KERNEL}" == "1" ]]; then
	PERF_EVENT="cpu-clock"
else
	PERF_EVENT="cpu-clock:u"
fi

if [[ "$(id -u)" != "0" ]]; then
	echo "需要 root：sysctl 和 perf record 才能改内核限制并采样。" >&2
	exit 1
fi

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

mkdir -p "${OUT}/maps" "${OUT}/symfs"
echo "输出目录：${OUT}"
echo "容器：${NAME}  时长：${RECORD_SECONDS}s  maps 间隔：${MAP_INTERVAL}s  事件：${PERF_EVENT}"

WARN="${OUT}/warnings.txt"
: >"${WARN}"
note() { printf '%s\n' "$*" | tee -a "${WARN}"; }

CPUSET="$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "${NAME}")"
NANOCPUS="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${NAME}")"
INIT_PID="$(docker inspect -f '{{.State.Pid}}' "${NAME}")"
GUEST_NPROC="$(docker exec "${NAME}" nproc 2>/dev/null | tr -d '\r' || true)"

if [[ -z "${CPUSET}" ]]; then
	note "警告：CpusetCpus 为空。--cpus=4 只限配额，容器里 nproc 仍可能是整机核数。"
	note "SwiftShader 默认 ThreadCount=min(看见的逻辑核, 16)。nproc=${GUEST_NPROC:-?} 时，没找到 SwiftShader.ini 就会起最多 16 条 marl worker。"
	note "绑核要在进程起来之前：docker run --cpuset-cpus=...，绑完后重启 surfaceflinger / 容器，线程数才会变。"
fi

# 把容器里正在用的 pastel.so 存档，并看有没有符号表
docker cp "${NAME}:/vendor/lib64/hw/vulkan.pastel.so" "${OUT}/vulkan.pastel.so" 2>/dev/null \
	|| docker cp "${NAME}:/system/lib64/hw/vulkan.pastel.so" "${OUT}/vulkan.pastel.so" 2>/dev/null \
	|| true
if [[ -f "${OUT}/vulkan.pastel.so" ]]; then
	{
		echo "==== file ===="
		file "${OUT}/vulkan.pastel.so" || true
		echo "==== 段（有无 .symtab / .dynsym） ===="
		readelf -S "${OUT}/vulkan.pastel.so" 2>/dev/null | grep -E 'symtab|dynsym|debug' || true
		echo "nm(符号表) 行数：$(nm "${OUT}/vulkan.pastel.so" 2>/dev/null | wc -l)"
		echo "nm -D(动态导出) 行数：$(nm -D "${OUT}/vulkan.pastel.so" 2>/dev/null | wc -l)"
	} | tee "${OUT}/pastel-symbols.txt"
fi

sysctl -w kernel.kptr_restrict=0 kernel.perf_event_paranoid=-1 >/dev/null

refresh_pids() {
	docker top "${NAME}" -eo pid,comm 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $2}' >"${OUT}/pids-comm.txt"
	awk '{print $1}' "${OUT}/pids-comm.txt" >"${OUT}/pids.txt"
	PIDS="$(paste -sd, "${OUT}/pids.txt")"
}

refresh_pids
if [[ -z "${PIDS:-}" ]]; then
	echo "docker top 没有 pid" >&2
	exit 1
fi
echo "进程数（开始）：$(wc -l <"${OUT}/pids.txt")"

dump_cpu_time() {
	local dest="$1"
	python3 - "${OUT}/pids.txt" "${dest}" <<'PY'
import os, sys
pid_file, dest = sys.argv[1], sys.argv[2]
try:
    ticks = os.sysconf("SC_CLK_TCK")
except (ValueError, OSError):
    ticks = 100
rows = ["CLK_TCK=%d" % ticks, "pid comm utime_ticks stime_ticks nthreads"]
for line in open(pid_file):
    pid = line.strip()
    if not pid:
        continue
    path = "/proc/%s/stat" % pid
    try:
        raw = open(path).read()
    except OSError:
        continue
    r = raw.rfind(")")
    if r < 0:
        continue
    comm = raw[raw.find("(") + 1 : r]
    rest = raw[r + 2 :].split()
    # field 14 utime, 15 stime → rest[11], rest[12] (fields 3+)
    if len(rest) < 13:
        continue
    nthreads = 0
    task = "/proc/%s/task" % pid
    try:
        nthreads = len(os.listdir(task))
    except OSError:
        pass
    rows.append("%s %s %s %s %s" % (pid, comm.replace(" ", "_"), rest[11], rest[12], nthreads))
open(dest, "w").write("\n".join(rows) + "\n")
PY
}

dump_render_threads() {
	local dest="$1"
	{
		echo "guest nproc=${GUEST_NPROC:-?}  CpusetCpus=${CPUSET:-空}  NanoCpus=${NANOCPUS}"
		echo "SwiftShader 默认：没读到 cwd/SwiftShader.ini 时 ThreadCount=min(nproc,16)。redroid 不会另起 16 条线程。"
		echo
		while read -r pid comm; do
			[[ -r "/proc/${pid}/maps" ]] || continue
			if ! grep -q 'vulkan\.pastel\.so' "/proc/${pid}/maps" 2>/dev/null; then
				continue
			fi
			cwd="$(readlink "/proc/${pid}/cwd" 2>/dev/null || echo '?')"
			ini="/proc/${pid}/cwd/SwiftShader.ini"
			echo "----- pid=${pid} comm=${comm} threads=$(ls /proc/${pid}/task 2>/dev/null | wc -l) -----"
			echo "cwd=${cwd}"
			if [[ -f "${ini}" ]]; then
				echo "SwiftShader.ini：有"
				grep -E 'ThreadCount|AffinityPolicy' "${ini}" 2>/dev/null || true
			else
				echo "SwiftShader.ini：无（会走默认 min(nproc,16)）"
			fi
			echo "Cpus_allowed_list=$(awk '/Cpus_allowed_list/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
			echo "task comms:"
			for t in /proc/${pid}/task/*/comm; do
				[[ -f "${t}" ]] || continue
				printf '  %s\n' "$(tr -d '\0' <"${t}")"
			done
			echo
		done <"${OUT}/pids-comm.txt"
	} >"${dest}"
}

dump_maps() {
	local tag="$1"
	refresh_pids
	local dest="${OUT}/maps/${tag}.txt"
	{
		echo "==== ${tag} $(date -Is) pids=$(wc -l <"${OUT}/pids.txt") ===="
		while read -r pid comm; do
			[[ -r "/proc/${pid}/maps" ]] || continue
			echo "----- pid=${pid} comm=${comm} -----"
			# 只记可执行映射，完整 maps 太大。JIT 是 r-xp 匿名页。
			awk '$2 ~ /x/' "/proc/${pid}/maps"
		done <"${OUT}/pids-comm.txt"
	} >"${dest}"
}

detect_cgroup() {
	# perf -G 只要 per-cpu 模式（-a 或 --cpu）。成功则可覆盖采样期间新拉起的进程。
	[[ -n "${INIT_PID}" && -r "/proc/${INIT_PID}/cgroup" ]] || return 1
	local rel=""
	if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
		rel="$(awk -F: '$1=="0"{print $3; exit}' "/proc/${INIT_PID}/cgroup")"
		rel="${rel#/}"
		[[ -n "${rel}" && -d "/sys/fs/cgroup/${rel}" ]] || return 1
		echo "${rel}"
		return 0
	fi
	rel="$(awk -F: '$2 ~ /(perf_event|cpuacct|cpu)/ {print $3; exit}' "/proc/${INIT_PID}/cgroup")"
	rel="${rel#/}"
	[[ -n "${rel}" ]] || return 1
	echo "${rel}"
}

CGROUP_NAME="$(detect_cgroup || true)"
PERF_FILTER=()
if [[ -n "${CGROUP_NAME}" ]]; then
	if [[ -n "${CPUSET}" ]]; then
		PERF_FILTER=(--cpu="${CPUSET}" -G "${CGROUP_NAME}")
		note "perf：--cpu=${CPUSET} -G ${CGROUP_NAME}（绑核范围内、该容器 cgroup，含后来新进程）"
	else
		PERF_FILTER=(-a -G "${CGROUP_NAME}")
		note "perf：-a -G ${CGROUP_NAME}（整机扫再按 cgroup 过滤。未绑核时开销更大）"
	fi
else
	PERF_FILTER=(-p "${PIDS}")
	note "perf：退回 -p 开始时的 PID 列表。采样期间新进程不会进入 perf.data；maps 仍每秒刷新名单。"
fi

dump_maps "t0"
dump_cpu_time "${OUT}/cpu-time-t0.txt" || note "cpu-time-t0 失败（需要 python3）"
dump_render_threads "${OUT}/render-threads-t0.txt"
docker stats --no-stream --format "CPU={{.CPUPerc}} MEM={{.MemUsage}}" "${NAME}" >"${OUT}/docker-stats-t0.txt" || true

(
	n=1
	while sleep "${MAP_INTERVAL}"; do
		dump_maps "$(printf 't%02d' "${n}")"
		n=$((n + 1))
	done
) &
MAP_PID=$!
stop_maps() {
	kill "${MAP_PID}" 2>/dev/null || true
	wait "${MAP_PID}" 2>/dev/null || true
}
finish_sample() {
	stop_maps
	refresh_pids
	dump_maps "tend"
	dump_cpu_time "${OUT}/cpu-time-tend.txt" || true
	dump_render_threads "${OUT}/render-threads-tend.txt"
	docker stats --no-stream --format "CPU={{.CPUPerc}} MEM={{.MemUsage}}" "${NAME}" >"${OUT}/docker-stats-tend.txt" || true
	if [[ -f "${OUT}/cpu-time-t0.txt" && -f "${OUT}/cpu-time-tend.txt" ]]; then
		python3 - "${OUT}/cpu-time-t0.txt" "${OUT}/cpu-time-tend.txt" "${OUT}/cpu-time-delta.txt" <<'PY' || true
import sys

def load(path):
    ticks, rows = 100, {}
    for line in open(path):
        line = line.strip()
        if line.startswith("CLK_TCK="):
            ticks = int(line.split("=", 1)[1])
            continue
        if not line or line.startswith("pid"):
            continue
        pid, comm, ut, st, nt = line.split()
        rows[pid] = (comm, int(ut), int(st), int(nt))
    return ticks, rows

ticks, a = load(sys.argv[1])
_, b = load(sys.argv[2])
out = ["CLK_TCK=%d  (秒=ticks/CLK_TCK)" % ticks,
       "pid comm du_ticks ds_ticks user_s sys_s nthreads_end"]
tu = ts = 0
for pid, (comm, ut1, st1, _) in b.items():
    ut0 = st0 = 0
    if pid in a:
        ut0, st0 = a[pid][1], a[pid][2]
    du, ds = ut1 - ut0, st1 - st0
    tu += du
    ts += ds
    nt = b[pid][3]
    out.append("%s %s %d %d %.3f %.3f %d" % (pid, comm, du, ds, du / float(ticks), ds / float(ticks), nt))
out.append("TOTAL user_s=%.3f sys_s=%.3f  (对照火焰图：图里只有用户态；sys 不在 cpu-clock:u 里)" % (tu / float(ticks), ts / float(ticks)))
open(sys.argv[3], "w").write("\n".join(out) + "\n")
PY
	fi
}
trap stop_maps EXIT

echo "开始 perf record ${RECORD_SECONDS}s（${PERF_EVENT} + fp）"
set +e
perf record --call-graph fp -e "${PERF_EVENT}" -F "${FREQ}" "${PERF_FILTER[@]}" \
	-o "${OUT}/perf.data" -- sleep "${RECORD_SECONDS}"
PERF_RC=$?
set -e
if [[ "${PERF_RC}" -ne 0 && "${PERF_FILTER[0]}" != "-p" ]]; then
	note "cgroup/绑核过滤失败 (exit ${PERF_RC})，改用开始时的 -p 列表再采一次。"
	refresh_pids
	perf record --call-graph fp -e "${PERF_EVENT}" -F "${FREQ}" -p "${PIDS}" \
		-o "${OUT}/perf.data" -- sleep "${RECORD_SECONDS}"
fi
finish_sample
trap - EXIT

SF=""
DC=""
while read -r pid comm; do
	if [[ "${comm}" == "surfaceflinger" && -z "${SF}" ]]; then
		SF="${pid}"
	fi
	if [[ "${comm}" == *deskclock* && -z "${DC}" ]]; then
		DC="${pid}"
	fi
done <"${OUT}/pids-comm.txt"

SYM=()
if [[ -n "${UNSTRIPPED_PASTEL:-}" && -f "${UNSTRIPPED_PASTEL}" ]]; then
	mkdir -p "${OUT}/symfs/vendor/lib64/hw" "${OUT}/symfs/system/lib64/hw"
	cp -a "${UNSTRIPPED_PASTEL}" "${OUT}/symfs/vendor/lib64/hw/vulkan.pastel.so"
	cp -a "${UNSTRIPPED_PASTEL}" "${OUT}/symfs/system/lib64/hw/vulkan.pastel.so"
	SYM=(--symfs "${OUT}/symfs")
	echo "SYMFS=${OUT}/symfs  （UNSTRIPPED_PASTEL；必须和容器内那份是同一次编译，否则函数名会对错）"
elif [[ -n "${SF}" && -d "/proc/${SF}/root/system" ]]; then
	SYM=(--symfs "/proc/${SF}/root")
	echo "SYMFS=/proc/${SF}/root  （容器内 so 若无 .symtab，这里仍然没有 C++ 函数名）"
elif [[ -n "${DC}" && -d "/proc/${DC}/root/system" ]]; then
	SYM=(--symfs "/proc/${DC}/root")
	echo "SYMFS=/proc/${DC}/root  （无 surfaceflinger 时退到 deskclock 的容器根）"
fi

{
	echo "容器：${NAME}"
	echo "时间：$(date -Is)"
	echo "秒数：${RECORD_SECONDS}  频率：${FREQ}  maps间隔：${MAP_INTERVAL}  事件：${PERF_EVENT}"
	echo "CpusetCpus=${CPUSET:-空}"
	echo "NanoCpus=${NANOCPUS}"
	echo "nproc=${GUEST_NPROC:-?}"
	echo "InitPid=${INIT_PID}"
	echo "cgroup=${CGROUP_NAME:-未检测到}"
	echo "perf_filter=${PERF_FILTER[*]}"
	echo "SF=${SF:-?} DC=${DC:-?}"
} >"${OUT}/meta.txt"

BFDERR="${OUT}/bfd-stderr.txt"
perf report -i "${OUT}/perf.data" --stdio --no-children --percent-limit 0.5 \
	--sort comm,dso "${SYM[@]}" 2>"${BFDERR}" | head -80 >"${OUT}/report-dso.txt" || true
perf report -i "${OUT}/perf.data" --stdio --no-children --percent-limit 0.5 \
	--sort comm "${SYM[@]}" 2>>"${BFDERR}" | head -40 >"${OUT}/report-comm.txt" || true
perf script -i "${OUT}/perf.data" --show-mmap-events 2>>"${BFDERR}" \
	>"${OUT}/mmap-events.txt" || true

if [[ -f "${FG}/stackcollapse-perf.pl" && -f "${FG}/flamegraph.pl" ]]; then
	perf script -i "${OUT}/perf.data" "${SYM[@]}" 2>>"${BFDERR}" \
		| perl "${FG}/stackcollapse-perf.pl" \
		| perl "${FG}/flamegraph.pl" --title "${NAME} ${PERF_EVENT}" \
		>"${OUT}/flame.svg" || true
	echo "火焰图：${OUT}/flame.svg"
fi

echo "maps：${OUT}/maps/   （每秒刷新 PID，t0 … tend）"
echo "user/sys 对照：${OUT}/cpu-time-delta.txt"
echo "marl 线程 / ini：${OUT}/render-threads-t0.txt"
echo "警告：${OUT}/warnings.txt"
echo "对 JIT 地址：grep -i <地址前几位> ${OUT}/maps/*.txt ${OUT}/mmap-events.txt"
echo "pastel 符号：${OUT}/pastel-symbols.txt"
ls -lh "${OUT}/perf.data" "${OUT}/maps" | sed -n '1,20p'
