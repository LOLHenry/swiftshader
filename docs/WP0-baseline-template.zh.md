# WP0 基线表（填空模板）

**WP** = Work Package，工作包。WP0 是第 0 个工作包：只记录「现在有多慢、时间花在哪」，不改产品。

用法：复制本页，每台服务器 × 每个套餐 × 每条场景填一份。同一操作路径录 3 次，数字取中位数。改 ThreadCount / 分辨率 / 指令之前各存一份，否则后面无法验收。

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
| 宿主机 OS / 内核 | `uname -r` | |
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

```bash
# 在宿主机上，<host_pid> 是该容器 surfaceflinger 的宿主 pid
perf record -g -p <host_pid> -- sleep 30
perf report --stdio | head -n 80
# 对照匿名页名字（maps 也要用同一个 pid 命名空间里的）
grep swiftshader /proc/<host_pid>/maps
```

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
- [ ] AHB 拷贝（AHardwareBuffer：应用把画好的图按行 memcpy 进共享缓冲，还不是叠层）
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
