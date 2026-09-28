# 第 0 个工作包：基线填空表

第 0 个工作包只记录「现在有多慢、时间花在哪」，不改产品。

用法：先按 [Stopwatch4U8GEnvironment.zh.md](Stopwatch4U8GEnvironment.zh.md) 把 4 核 8 吉字节秒表环境跑起来，再复制本页填写。同一操作路径录 3 次，数字取中位数。改线程数、分辨率或库文件之前各存一份。

---

## A. 机器和镜像（填一次即可）

| 项 | 怎么取 | 填写 |
|----|--------|------|
| 日期 / 填写人 | | |
| 服务器型号 | 资产标签或 `dmidecode -s system-product-name` | |
| CPU 型号 | `lscpu \| grep 'Model name'` | 例：Kunpeng-920 |
| 物理核 / 路数 / NUMA | `lscpu` 里 CPU(s)、Socket(s)、NUMA node(s) | 例：128 核 / 2 路 / 4 节点 |
| 每核线程数 | `Thread(s) per core` | 鲲鹏常见 1 |
| 有无 SVE | `lscpu \| grep -i sve`；空则无 | 920 官方通常无 |
| 宿主机 OS / 内核 | `uname -r`；openEuler 22 还要记 `grep binder /proc/filesystems` | 必须有 `nodev binder`。没有则先看 [OpenEuler22Binder.zh.md](OpenEuler22Binder.zh.md) |
| redroid / Android 版本 | 镜像说明或 `getprop ro.build.version.release` | |
| 整机同时开的实例数 | 编排系统 | |
| 本份表对应实例 ID | | |

## B. 这个容器能看见什么

| 项 | 怎么取 | 填写 |
|----|--------|------|
| 容器内 `nproc` | 容器里执行 `nproc` | |
| cpuset / quota | `cat /sys/fs/cgroup/cpuset/cpuset.cpus` 或 cgroup v2 对应文件 | |
| 是否和别的实例抢同一 NUMA | 宿主机 `numactl --show` / 编排绑核 | |
| `ro.hardware.vulkan` | `getprop ro.hardware.vulkan` | 必须是 `pastel` |
| EGL / GLES | `getprop ro.hardware.egl`；`dumpsys SurfaceFlinger` 里 GLES 行 | 12+ 常见 angle |
| 进程 cwd 有无 ini | 对 surfaceflinger 或渲染进程：`ls -l /proc/<pid>/cwd/SwiftShader.ini` | 有 / 无；ThreadCount= |
| redroid 宽 / 高 / DPI / FPS | 启动参数 `androidboot.redroid_*` | 例：1280 × 720，DPI 320，FPS 15 |

## C. 场景（一张表只对应一条路径）

| 项 | 填写 |
|----|------|
| 场景名 | 例：桌面滑动 / 设置列表 / 某 APK 首页 |
| APK 包名与版本 | |
| 操作步骤（写成别人能复现） | 1. … 2. … 3. … |
| 录制时长 | 建议 20～60 秒 |
| 是否预热（先打开过一遍再录） | 是 / 否 |

## D. 体验与负载（改之前必须有）

同一操作录 3 次，填中位数。

| 指标 | 第 1 次 | 第 2 次 | 第 3 次 | 中位数 |
|------|---------|---------|---------|--------|
| 平均 FPS | | | | |
| P99 帧时间 (ms) | | | | |
| 是否可接受（主观） | | | | |

帧时间怎么取：能用 `dumpsys gfxinfo <包名>` 或你们现成的流畅度脚本就用现成的；没有就先只记 FPS 和是否卡顿，并在备注写「无 P99」。

| 项 | 怎么取 | 填写 |
|----|--------|------|
| 渲染相关进程 CPU% | 容器内 `top`，看 surfaceflinger、应用、`*Hwui*` | sf=　%  应用=　% |
| 渲染线程条数（忙着的） | `top -H` 或 `ps -T`，数 SwiftShader / ANGLE / HwuiTask | |
| 宿主机该实例占用核 | 宿主机 `top` / pidstat | |
| 整机 load / 空闲核 | `uptime`；`nproc` 对比 | load=　 空闲约　核 |

经验公式（先算再填是否超卖）：

```text
实例数 × 每实例 ThreadCount  ？>  物理核 − 预留（system + 网络 + 宿主机）
本机：____ × ____  = ____    物理核 ____  预留 ____  超卖：是 / 否
```

## E. 热点归属（perf 前五名）

对 **应用进程** 和 **surfaceflinger** 各采一次（合成也会走软渲染）。

**perf 打在宿主机上**，pid 用宿主机看到的那个。容器里 `pidof surfaceflinger` 的数字对宿主机无效。先在宿主机用 cgroup / `ps` 对上，再采。

openEuler 22 鲲鹏上的 `perf` 常链了 OpenCSD 和 babeltrace，但 RPM 没把它们写成硬依赖。缺库时二进制起不来，例如：

`error while loading shared libraries: libopencsd_c_api.so.1`
`error while loading shared libraries: libbabeltrace-ctf.so.1`

`perf record -g` 做的是普通采样，不需要 CoreSight / CTF；装上库只是为了让二进制能启动。一次装齐，再用 `ldd` 看还有没有 `not found`：

```bash
yum install -y OpenCSD babeltrace
ldd $(command -v perf) | grep 'not found' || true
# 仍缺某 .so 时：yum provides '*/那个文件名'
```

自编译内核（名字带 `-binder-ashmem`）时，发行版 `perf` 对不上内核符号：会报 `Couldn't record kernel reference relocation symbol`，随后有时直接段错误。软渲染热点在用户态，不要采内核：

```bash
# 即使是 root，kptr_restrict=2 也会把 /proc/kallsyms 打成 0
sysctl -w kernel.kptr_restrict=0 kernel.perf_event_paranoid=-1
# :u = 只采用户态；fp 比默认 dwarf 稳，避开段错误
perf record --call-graph fp -e cpu-clock:u -p <host_pid> -o /tmp/perf-stopwatch.data -- sleep 60
# 若仍段错误，去掉调用栈再采：
# perf record -e cpu-clock:u -p <host_pid> -o /tmp/perf-stopwatch.data -- sleep 60
perf report -i /tmp/perf-stopwatch.data --stdio | head -n 80
grep swiftshader /proc/<host_pid>/maps
```

秒表负载建议 `-p <sf>,<deskclock>`（宿主 pid）。

拷到家目录并出 HTML（进程还活着时跑，才能写 JIT map 和 `--symfs`）：

```bash
OUT=/home/f00589393/perf-stopwatch
DATA=/tmp/perf-stopwatch.data
NAME=redroid-4c8g
mkdir -p "$OUT"
cp -a "$DATA" "$OUT/perf-stopwatch.data"

SF=$(ps -eo pid,comm | awk '$2=="surfaceflinger"{print $1; exit}')
DC=$(ps -eo pid,comm | awk '$2 ~ /deskclock/{print $1; exit}')

# 符号从哪解析：容器根。没有它，libhwui / pastel 经常只显示地址。
SYMFS=
[[ -n "$SF" && -d /proc/$SF/root/system ]] && SYMFS=/proc/$SF/root
MERGED=$(docker inspect "$NAME" --format '{{.GraphDriver.Data.MergedDir}}' 2>/dev/null || true)
[[ -d "$MERGED/system" ]] && SYMFS=$MERGED
echo "SYMFS=$SYMFS"

# JIT 映射：SwiftShader 不写 /tmp/perf-PID.map。把 maps 里名为 swiftshader_jit 的整段标成一个符号。
# 这还不是 PixelRoutine_XXXX；要函数名得改库写 map（WP2）。
for p in $SF $DC; do
  [[ -n "$p" ]] || continue
  cp -a /proc/$p/maps "$OUT/maps.$p"
  python3 - "$p" "$OUT/perf-$p.map" <<'PY'
import sys
pid, dst = sys.argv[1], sys.argv[2]
rows = []
for line in open("/proc/%s/maps" % pid):
    if "swiftshader_jit" not in line:
        continue
    a, b = line.split()[0].split("-")
    start, end = int(a, 16), int(b, 16)
    rows.append("%x %x swiftshader_jit" % (start, end - start))
open(dst, "w").write("\n".join(rows) + ("\n" if rows else ""))
print(pid, "jit ranges", len(rows))
PY
  cp -a "$OUT/perf-$p.map" /tmp/perf-$p.map
done

SYM=( )
[[ -n "$SYMFS" ]] && SYM=(--symfs "$SYMFS")
perf report -i "$OUT/perf-stopwatch.data" --stdio --no-children --percent-limit 0.3 --sort comm,dso "${SYM[@]}" >"$OUT/report-dso.txt"
perf report -i "$OUT/perf-stopwatch.data" --stdio --no-children --percent-limit 0.3 --sort comm,symbol "${SYM[@]}" >"$OUT/report-sym.txt"
perf script -i "$OUT/perf-stopwatch.data" "${SYM[@]}" >"$OUT/script.txt"

python3 - "$OUT" <<'PY'
import html, os, pathlib, sys
out = sys.argv[1]
def pre(name):
    p = os.path.join(out, name)
    t = pathlib.Path(p).read_text(errors="replace") if os.path.isfile(p) else "(missing)"
    return "<h2>%s</h2><pre>%s</pre>" % (html.escape(name), html.escape(t))
html_out = (
    "<!DOCTYPE html><meta charset=utf-8><title>stopwatch perf</title>"
    "<style>body{font:14px/1.4 sans-serif;margin:24px}pre{font:12px monospace;white-space:pre-wrap}</style>"
    "<h1>stopwatch perf</h1>"
    "<p><code>[unknown]</code> + maps 里的 <code>swiftshader_jit</code> = 像素 JIT。"
    "本目录 <code>perf-PID.map</code> 只给整段 JIT 起名，不是 PixelRoutine。</p>"
    + pre("report-dso.txt") + pre("report-sym.txt")
)
pathlib.Path(os.path.join(out, "index.html")).write_text(html_out, encoding="utf-8")
print("wrote", os.path.join(out, "index.html"))
PY

# 可选火焰图（github 不通就跳过）
git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$OUT/FlameGraph" || true
if [[ -f $OUT/FlameGraph/flamegraph.pl ]]; then
  perl "$OUT/FlameGraph/stackcollapse-perf.pl" "$OUT/script.txt" >"$OUT/collapsed.txt"
  perl "$OUT/FlameGraph/flamegraph.pl" --title stopwatch "$OUT/collapsed.txt" >"$OUT/flame.svg"
  printf '%s\n' '<!DOCTYPE html><meta charset=utf-8><embed src="flame.svg" style="width:100%;height:100vh">' >"$OUT/flame.html"
fi
ls -lh "$OUT/index.html" "$OUT"/flame.html "$OUT"/flame.svg 2>/dev/null
echo "浏览器打开 $OUT/index.html  （火焰图: $OUT/flame.html）"
```

读报告（先按 **库/映射** 分桶，不要对着单个符号改指令）：

```bash
ls -lh /tmp/perf-stopwatch.data
# 按进程 + 共享库。Self% 才是「这层自己在烧」
perf report -i /tmp/perf-stopwatch.data --stdio --no-children --percent-limit 1 --sort comm,dso | head -80
# 再看符号叶子（匿名页常叫 [unknown]）
perf report -i /tmp/perf-stopwatch.data --stdio --no-children --percent-limit 1 --sort comm,symbol | head -80
# 匿名热点是不是 SwiftShader JIT
grep swiftshader /proc/<sf>/maps /proc/<deskclock>/maps
```

把 `dso` 列归进下表（同一条样本只算一次）：

| 报告里出现 | 填哪一类 |
|------------|----------|
| `vulkan.pastel` / `libvk_swiftshader` / `[unknown]` 且 maps 有 `swiftshader_jit` | `swiftshader_jit`（再看 comm 是 deskclock 还是 surfaceflinger） |
| `libhwui` / `libskia` / `libhwui.so` | Skia / HWUI |
| `libEGL` / `libGLESv2` / `ANGLE` / `libfeature_support` | ANGLE 翻译 |
| `memcpy` / `memmove` / `prepareForExternalUse` / `libc.so` 里拷贝很重 | AHB 按行拷贝 |
| `libart` / `libdexfile` / `com.android.deskclock` 非渲染符号 | 应用业务 |
| `libbinder` / 内核（本次 `:u` 采样应很少） | 先忽略，或回头查超卖 |

| 排名 | 符号或占比类别 | 进程（应用 / surfaceflinger） | 约占 CPU% |
|------|----------------|------------------------------|-----------|
| 1 | 例：`jit unknown` / `swiftshader_jit` | | |
| 2 | 例：`libhwui` / Skia | | |
| 3 | 例：ANGLE / `libEGL` | | |
| 4 | 例：memcpy / `prepareForExternalUse`（AHB：把画好的图拷进共享缓冲） | | |
| 5 | 例：内核 / 其它 | | |
| 合计核对 | 前五名相加（不必等于 100） | | |

把「最大头」圈成下面之一（只圈一个，决定下一刀）：

- [ ] 应用业务（Java/Kotlin，不是画图）
- [ ] Skia / HWUI（2D 自己在算）
- [ ] ANGLE 翻译
- [ ] `swiftshader_jit`（CPU 在算像素，**应用进程**）
- [ ] `swiftshader_jit`（CPU 在算像素，**surfaceflinger 进程**）
- [ ] 应用把画好的图按行拷进 Android 硬件共享图缓冲（还不是窗口合成器在叠层）
- [ ] 每容器约 16 条忙线程 / 整机打满（先做 WP1）

## F. 附件清单

- [ ] `lscpu` 全文
- [ ] 应用进程 `perf report`（改之前）
- [ ] surfaceflinger `perf report`（改之前）
- [ ] `/proc/<pid>/maps` 里含 `swiftshader_jit` 的几行
- [ ] 一张目标界面截图（防以后精度回归时对照）

## G. 结论（一句话）

下一刀做：WP1 调度像素 / WP2 打开 JIT / 减层或分辨率 / 查拷贝 / 暂缓改指令。

理由（对照 E 的最大头）：
