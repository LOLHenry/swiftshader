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

秒表负载建议一次只盯 sf+时钟时用 `-p <sf>,<deskclock>`。采 **这个 redroid 的全部进程** 时不要裸 `-a`（那是整台宿主机）。脚本在能检测到容器 cgroup 时会用 `-G` 限定在该容器内（可带上后来新起的进程）。

每次进带时间戳的新目录，**采样同时记可执行 maps**。把 `scripts/redroid_4u8g_stopwatch/perf_record_redroid.sh` 拷到宿主机后：

```bash
cd /path/to/swiftshader/scripts/redroid_4u8g_stopwatch
NAME=redroid-4c8g RECORD_SECONDS=60 ./perf_record_redroid.sh
```

输出在 `/home/f00589393/perf-redroid/时间戳/`：

| 文件 | 用途 |
|------|------|
| `perf.data` / `flame.svg` | 默认 `cpu-clock`（用户态+系统态）。内核不要符号，图上常是地址 / `[kernel.kallsyms]`。失败会降级 |
| `maps/t00.txt`…`tend` | 采样同时段的可执行映射；每秒刷新 PID |
| `cpu-visible.txt` | 容器里 `nproc` / `cpu/online`。绑了 4 核但这里仍是 16/320，就会起 16 条 worker |
| `cpu-time-delta.txt` | 各进程 user/sys 秒数 |
| `render-threads-t0.txt` | pastel 进程、cwd 有无 ini、`Thread<*>` 条数 |
| `warnings.txt` | 未绑核，或已绑核但 nproc 对不上 |
| `docker-stats-t0/tend.txt` | 容器总 CPU |

对 JIT 地址用当时的 maps，不要 grep 现在的 `/proc/pid/maps`。

**为什么 SF 会有 16 条 worker，而不是 4U 就 4 条：** redroid 不会自己起 16 条渲染线程。`vulkan.pastel.so` 里 marl 的默认是 `min(看见的逻辑核, 16)`（`src/System/SwiftConfig.cpp`）。它看的是容器里 `nproc` / `cpu/online`，**不是** `docker inspect` 的 `CpusetCpus`。所以会出现：宿主机已经 `--cpuset-cpus=316-319`，Android 里 `nproc` 仍是 16 或 320，于是仍起 16 条；线程只会被调度到那 4 个核上跑，16 条在 4 核上挤。另一种：绑核前 SF 已经起来了，池子不会自己缩小，必须重启容器。ini 只认进程 cwd。脚本把 `nproc` vs 绑核写进 `cpu-visible.txt` / `warnings.txt`。

进容器核对（先宿主机，再进 Android）：

```bash
NAME=redroid-4c8g
docker inspect -f 'CpusetCpus={{.HostConfig.CpusetCpus}}  NanoCpus={{.HostConfig.NanoCpus}}' "$NAME"
docker exec -it "$NAME" sh
```

容器里：

```bash
nproc
cat /sys/devices/system/cpu/online
pidof surfaceflinger
SF=$(pidof surfaceflinger)
ls -l /proc/$SF/cwd/SwiftShader.ini
cat /proc/$SF/cwd/SwiftShader.ini 2>/dev/null
grep Cpus_allowed /proc/$SF/status
for t in /proc/$SF/task/*/comm; do cat "$t"; done | grep Thread | wc -l
for t in /proc/$SF/task/*/comm; do cat "$t"; done | grep Thread
```

`nproc`/`online` 大于 4 → 默认就会 `min(该数,16)`。已经是 4 但 Thread 仍 16 → 重启容器。没有 ini → 不会走 `ThreadCount=4`。

也可走 adb：`adb connect 127.0.0.1:6666` 然后 `adb -s 127.0.0.1:6666 shell`，后面命令相同。

手工等价命令（一般直接跑脚本）：

```bash
NAME=redroid-4c8g
FG=/home/f00589393/redroid-build/FlameGraph-master
OUT=/home/f00589393/perf-redroid/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
sysctl -w kernel.kptr_restrict=0 kernel.perf_event_paranoid=-1
PIDS=$(docker top "$NAME" -eo pid | awk 'NR>1{printf "%s%s", (n++?",":""), $1}')
echo "$PIDS" | tr ',' '\n' | wc -l | awk '{print "pids",$1}'
echo "$OUT"
perf record --call-graph fp -e cpu-clock:u -F 99 -p "$PIDS" -o "$OUT/perf.data" -- sleep 60
SF=$(ps -eo pid,comm | awk '$2=="surfaceflinger"{print $1; exit}')
SYM=( )
[[ -n "$SF" && -d /proc/$SF/root/system ]] && SYM=(--symfs /proc/$SF/root)
perf script -i "$OUT/perf.data" "${SYM[@]}" | "$FG/stackcollapse-perf.pl" | "$FG/flamegraph.pl" > "$OUT/flame.svg"
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 1 --sort comm "${SYM[@]}" | head -40 | tee "$OUT/report-comm.txt"
ls -lh "$OUT"
```

打开 `$OUT/flame.svg`。FlameGraph 脚本留在 `redroid-build`，不要拷进 `$OUT`。

`--symfs` 指向容器里的 Android 文件时，宿主机老 `libbfd` 可能刷：

`BFD: /system/bin/surfaceflinger: unknown type [0x13] section '.relr.dyn'`

这是解析器不认识 Android 的 RELR 重定位段，**不是采样失败**。数字照常用。嫌吵：

```bash
perf report -i "$OUT/perf.data" --stdio "${SYM[@]}" 2>/dev/null | head -40
```

火焰图里 `vulkan.pastel.so` **不能展开成函数名**：`nm` 为 0 就是 strip。栈里的 `0xf09c…` 已经是地址级；要 C++ / `PixelRoutine` 名必须换未 strip 的 so，或 JIT 写 `/tmp/perf-PID.map`。

`Thread<04>` 是 SwiftShader（marl）工作线程，活在 surfaceflinger / deskclock 进程里，不是 redroid 另起的进程。默认最多 16 条（见上节）。`--sort comm,dso` 会按线程拆开，每个 ~2–3% 看起来不大，**合计**才有意义：

```bash
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 0.5 --sort dso | head -30
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 0.5 --sort comm | head -30
```

`grep swiftshader` 经常是空的：内核没有 `CONFIG_ANON_VMA_NAME` 时 maps 不带这个名字。改列可执行映射。

**不要用「现在」的 `/proc/pid/maps` 去对采样里的 JIT 地址。** JIT 页会释放、再分配，地址 `0xffec27982000` 采完时可能已经没了。`perf.data` 里自带当时的映射记录：

```bash
# 采样当时有没有这块可执行内存（MMAP / MUNMAP）
perf script -i "$OUT/perf.data" --show-mmap-events | grep -i 27982000
# 仍没有：扩大一点（去掉末尾的页内偏移）
perf script -i "$OUT/perf.data" --show-mmap-events | grep -i ffec2798
```

采的时候并行把 maps 记下来（和 perf 同时段，才对得上）：

```bash
( while sleep 1; do echo "==== $(date -Is) ===="; cat /proc/$SF/maps /proc/$DC/maps; done ) >"$OUT/maps-live.log" &
MPID=$!
# 这里跑原来的 perf record …
kill $MPID
```

彻底解决：JIT 编译当时就写 `/tmp/perf-<pid>.map`（地址、长度、名字），不要事后猜 maps。

```bash
OUT=$(ls -d /home/f00589393/perf-redroid/*/ | sort | tail -1)
SF=$(ps -eo pid,comm | awk '$2=="surfaceflinger"{print $1; exit}')
DC=$(ps -eo pid,comm | awk '$2 ~ /deskclock/{print $1; exit}')
echo "SF=$SF DC=$DC"
awk '$2 ~ /x/' /proc/$SF/maps /proc/$DC/maps | tee "$OUT/maps-exec.txt"
python3 - "$OUT" $SF $DC <<'PY'
import os, sys
from collections import Counter
out, pids = sys.argv[1], sys.argv[2:]
ranges = []
for pid in pids:
    p = "/proc/%s/maps" % pid
    if not os.path.isfile(p):
        continue
    for line in open(p):
        parts = line.split()
        if len(parts) < 5 or "x" not in parts[1]:
            continue
        path = parts[5] if len(parts) > 5 else ""
        if path and not path.startswith("[") and "memfd" not in path and "jit" not in path.lower():
            continue
        a, b = parts[0].split("-")
        ranges.append((int(a, 16), int(b, 16), pid, path or "anon"))
print("exec-anon ranges", ranges)
script = os.path.join(out, "script-ip.txt")
os.system("perf script -i %s/perf.data -F comm,ip > %s" % (out, script))
n = jit = 0
c = Counter()
for line in open(script):
    parts = line.split()
    if len(parts) < 2:
        continue
    try:
        ip = int(parts[-1], 16)
    except ValueError:
        continue
    n += 1
    for lo, hi, pid, path in ranges:
        if lo <= ip < hi:
            jit += 1
            c[(pid, path, (ip - lo) & ~0x3f)] += 1
            break
print("samples", n, "in_anon_exec", jit, "pct", (100.0 * jit / n) if n else 0)
for k, v in c.most_common(15):
    print(" ", k, v)
PY
```

若 `in_anon_exec` 占比高：热点就是像素 JIT，**不要改 pastel.so 里某个可见符号**；要函数名得写 `/tmp/perf-PID.map`（WP2）。若合计时间在 `libhwui` / `memcpy`：先减层或查拷贝。

读报告（先按 **库/映射** 分桶，不要对着单个符号改指令）：

```bash
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 1 --sort comm,dso | head -80
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit 1 --sort comm,symbol | head -80
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
