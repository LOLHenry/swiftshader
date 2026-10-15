#!/usr/bin/env bash
# 把 /tmp/perf-stopwatch.data 拷到家目录，写 JIT map，按容器根解析符号，出 HTML。
# 用法：
#   OUT=/home/f00589393/perf-stopwatch DATA=/tmp/perf-stopwatch.data \
#     ./scripts/redroid_4u8g_stopwatch/perf_to_html.sh

set -euo pipefail

OUT="${OUT:-/home/f00589393/perf-stopwatch}"
DATA="${DATA:-/tmp/perf-stopwatch.data}"
NAME="${REDROID_NAME:-redroid-4c8g}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${DATA}" ]]; then
	echo "找不到 ${DATA}。先完成 perf record，或把 DATA= 指到实际文件。" >&2
	exit 1
fi

mkdir -p "${OUT}"
cp -a "${DATA}" "${OUT}/perf-stopwatch.data"
echo "已拷贝 ${DATA} -> ${OUT}/perf-stopwatch.data"

ps -eo pid,pcpu,comm --sort=-pcpu | awk 'NR==1 || /surfaceflinger|deskclock/' | tee "${OUT}/ps.txt"

SF="$(ps -eo pid,comm | awk '$2=="surfaceflinger"{print $1; exit}')"
DC="$(ps -eo pid,comm | awk '$2 ~ /deskclock/{print $1; exit}')"
echo "SF=${SF:-?} DC=${DC:-?}" | tee "${OUT}/pids.txt"

write_jit_map() {
	local pid="$1"
	python3 - "${pid}" "${OUT}/perf-${pid}.map" <<'PY'
import sys
pid, dst = sys.argv[1], sys.argv[2]
rows = []
try:
    maps = open("/proc/%s/maps" % pid)
except OSError as exc:
    sys.stderr.write("skip maps %s: %s\n" % (pid, exc))
    raise SystemExit(0)
for line in maps:
    if "swiftshader_jit" not in line:
        continue
    a, b = line.split()[0].split("-")
    start, end = int(a, 16), int(b, 16)
    rows.append("%x %x swiftshader_jit" % (start, end - start))
open(dst, "w").write("\n".join(rows) + ("\n" if rows else ""))
print("jit map %s: %d range(s) -> %s" % (pid, len(rows), dst))
PY
	if [[ -s "${OUT}/perf-${pid}.map" ]]; then
		cp -a "${OUT}/perf-${pid}.map" "/tmp/perf-${pid}.map"
	fi
	cp -a "/proc/${pid}/maps" "${OUT}/maps.${pid}" 2>/dev/null || true
	grep -E 'swiftshader|r-xp' "/proc/${pid}/maps" > "${OUT}/maps-exec.${pid}" 2>/dev/null || true
}

for p in ${SF:-} ${DC:-}; do
	write_jit_map "${p}"
done

SYMFS=""
if [[ -n "${SF:-}" && -d "/proc/${SF}/root/system" ]]; then
	SYMFS="/proc/${SF}/root"
elif [[ -n "${DC:-}" && -d "/proc/${DC}/root/system" ]]; then
	SYMFS="/proc/${DC}/root"
fi
if MERGED="$(docker inspect "${NAME}" --format '{{.GraphDriver.Data.MergedDir}}' 2>/dev/null)" && [[ -d "${MERGED}/system" ]]; then
	SYMFS="${MERGED}"
fi
echo "SYMFS=${SYMFS}" | tee "${OUT}/symfs.txt"

SYMFS_ARGS=()
if [[ -n "${SYMFS}" ]]; then
	SYMFS_ARGS=(--symfs "${SYMFS}")
fi

perf report -i "${OUT}/perf-stopwatch.data" --stdio --no-children --percent-limit 0.3 \
	--sort comm,dso "${SYMFS_ARGS[@]}" >"${OUT}/report-dso.txt" || true
perf report -i "${OUT}/perf-stopwatch.data" --stdio --no-children --percent-limit 0.3 \
	--sort comm,symbol "${SYMFS_ARGS[@]}" >"${OUT}/report-sym.txt" || true
perf script -i "${OUT}/perf-stopwatch.data" "${SYMFS_ARGS[@]}" >"${OUT}/script.txt" || true

python3 - "${OUT}/script.txt" "${OUT}/collapsed.txt" <<'PY'
import sys
from collections import Counter

src, dst = sys.argv[1], sys.argv[2]
counts = Counter()
stack = []
comm = "unknown"

def flush():
    global stack
    if not stack:
        return
    counts[comm + ";" + ";".join(reversed(stack))] += 1
    stack = []

try:
    fh = open(src, encoding="utf-8", errors="replace")
except OSError:
    open(dst, "w").close()
    raise SystemExit(0)

for raw in fh:
    line = raw.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    if line[:1] in "\t ":
        tok = line.strip()
        if tok.startswith("..."):
            continue
        parts = tok.split()
        if parts and all(ch in "0123456789abcdefABCDEFx" for ch in parts[0].replace("0x", "")):
            name = " ".join(parts[1:]) if len(parts) > 1 else parts[0]
        else:
            name = tok
        stack.append(name)
        continue
    flush()
    comm = line.split()[0]
    if "cpu-clock" in line:
        # 无调用栈时，叶子在同一行末尾
        rest = line.split(":", 2)[-1].strip()
        bits = rest.split()
        if len(bits) >= 2:
            stack.append(" ".join(bits[1:]))
flush()
with open(dst, "w", encoding="utf-8") as out:
    for k, n in counts.most_common():
        out.write("%s %d\n" % (k, n))
print("collapsed stacks:", sum(counts.values()))
PY

python3 "${HERE}/perf_report_html.py" \
	"${OUT}/report-dso.txt" "${OUT}/report-sym.txt" "${OUT}/collapsed.txt" \
	"${OUT}/index.html"

if [[ ! -d "${OUT}/FlameGraph" ]]; then
	git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "${OUT}/FlameGraph" \
		|| echo "FlameGraph 克隆失败，跳过 SVG（index.html 仍可用）" >&2
fi
if [[ -x "${OUT}/FlameGraph/stackcollapse-perf.pl" || -f "${OUT}/FlameGraph/stackcollapse-perf.pl" ]]; then
	perl "${OUT}/FlameGraph/stackcollapse-perf.pl" "${OUT}/script.txt" >"${OUT}/collapsed-fg.txt" || true
	perl "${OUT}/FlameGraph/flamegraph.pl" --title "stopwatch cpu-clock:u" "${OUT}/collapsed-fg.txt" \
		>"${OUT}/flame.svg" || true
	printf '%s\n' '<!DOCTYPE html><meta charset=utf-8><title>flame</title>' \
		'<embed src="flame.svg" type="image/svg+xml" style="width:100%;height:100vh">' \
		>"${OUT}/flame.html"
fi

echo "打开： ${OUT}/index.html"
ls -lh "${OUT}/index.html" "${OUT}/perf-stopwatch.data" "${OUT}/report-dso.txt" "${OUT}/report-sym.txt"
