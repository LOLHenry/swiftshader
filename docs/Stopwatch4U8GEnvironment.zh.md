# 4 核 8 吉字节 + 秒表：可重复的极限测试环境

这份规格把「能支撑对比测试」的环境钉死。任何人用同一份规格启动，应得到同一套资源、同一套画面参数、同一条操作路径。换其中任何一项，就视为另一个环境，不能和旧数字直接比。

对象是负责测试的现场工程师。极限指的是：秒表界面几乎每一帧都在改数字，软件渲染和窗口合成会持续干活；同时实例被限制在 4 颗处理器、8 吉字节内存，避免「看见整机 128 核」把结果搅乱。

和第 0 个工作包的关系：先按本文把环境拉起来，再把测到的数字填进 [WP0-baseline-template.zh.md](WP0-baseline-template.zh.md)。

启动脚本在 [scripts/redroid_4u8g_stopwatch/run.sh](../scripts/redroid_4u8g_stopwatch/run.sh)。

---

## 1. 必须钉死的参数

| 项目 | 锁定值 | 为什么锁 |
|------|--------|----------|
| 处理器 | 4 颗，建议绑在同一非统一内存访问节点 | 对应套餐「4 核」；跨节点会让拷贝变慢且不稳定 |
| 内存 | 8 吉字节，交换区也限制到 8 吉字节 | 对应套餐「8 吉」；禁止用交换区把卡顿藏起来 |
| 系统镜像 | `redroid/redroid:16.0.0_64only-latest` 的 **镜像摘要**，不要只用会移动的 `latest` 标签 | 标签会变，摘要不会 |
| 图形 | 客户机软件渲染：`androidboot.redroid_gpu_mode=guest` | 走 ANGLE 再进 `vulkan.pastel` |
| 共享内存 | `androidboot.use_memfd=true` | 许多宿主机内核没有 ashmem，Android 16 需要这项才能稳定起来 |
| 画面 | 宽 1280、高 720、每英寸点数 320、目标帧率 30 | 像素量和刷新率一旦改，处理器占用没有可比性 |
| SwiftShader 工作线程 | `ThreadCount=4`，`AffinityPolicy=one` | 和 4 颗可见处理器对齐；线程钉在单核上 |
| 应用 | 秒表已经启动并在走时，录制 60 秒 | 数字一直变，负载稳定、可重复 |
| 预热 | 第一次打开后丢掉，从第二次走时开始记数 | 第一次即时编译会把结果抬高 |

不要在对比「换库之前 / 换库之后」时改分辨率、帧率、线程数或镜像摘要。

---

## 2. 怎么把环境固化下来

固化不是写在聊天里，而是留下四样东西，每次开测都对照：

1. **镜像摘要**  
   第一次拉镜像后执行 `docker image inspect --format '{{.RepoDigests}}' redroid/redroid:16.0.0_64only-latest`，把 `@sha256:...` 写进环境指纹文件。以后用 `docker run` 时写完整摘要，并加上 `--pull=never`。

2. **资源上限写在容器启动参数里**  
   `--cpus=4 --memory=8g --memory-swap=8g`。有条件再加上 `--cpuset-cpus=` 四个同一节点上的编号。不要只靠容器内部的 `nproc` 碰巧等于 4。

3. **画面和线程写进启动参数与配置文件**  
   redroid 的宽度、高度、点数、帧率写在 `androidboot.redroid_*`。`SwiftShader.ini` 必须出现在 **窗口合成器进程和应用进程的当前工作目录**。脚本默认把配置文件挂到容器的 `/data/local/tmp/SwiftShader.ini`，并在启动后复制到查到的工作目录；你们若确认合成器工作目录是 `/`，就把同一份文件挂到 `/SwiftShader.ini`。

4. **应用和操作路径写进脚本，不要人手点**  
   优先使用系统自带时钟里的秒表（包名常见为 `com.android.deskclock`）。若镜像里没有，把你们选定的秒表安装包放到 `scripts/redroid_4u8g_stopwatch/stopwatch.apk`，并在指纹文件里记下该文件的校验和。启动、开始走时、录 60 秒，全部由脚本执行。

每次跑完，脚本会在输出目录写下 `environment-fingerprint.txt`：镜像摘要、容器编号、系统指纹、`vulkan.pastel.so` 的校验和、安装包校验和、`nproc`、内存、配置文件原文。换库对比时，除「库文件校验和」和测得的帧率、处理器占用以外，其余行应完全相同。

---

## 3. 第一次在宿主机上做的事

1. 安装 Docker。
2. 让宿主机内核提供 Android Binder。openEuler 22 的发行版内核通常没有打开它，也没有 `systemctl start binder` 这种服务。先跑 `scripts/redroid_4u8g_stopwatch/check_host_binder.sh`，再按 [OpenEuler22Binder.zh.md](OpenEuler22Binder.zh.md) 处理。323 上已跑通的是第 3.2 节：用同一颗 `kernel-source` 重编并换内核。`grep binder /proc/filesystems` 必须出现 `nodev binder` 再往下走。
3. 拉镜像并记下摘要，不要以后只写 `latest`。
4. 若系统时钟没有秒表，放入固定的 `stopwatch.apk`。
5. 执行：

```bash
cd scripts/redroid_4u8g_stopwatch
# 把摘要填进 IMAGE 变量，或 export REDROID_IMAGE=redroid/redroid@sha256:...
./run.sh
```

脚本会：创建容器 → 等待开机 → 写入配置 → 启动秒表并开始走时 → 等 60 秒 → 写出指纹和 `dumpsys gfxinfo`。需要采性能计数时加上 `COLLECT_PERF=1`，脚本在宿主机上对窗口合成器对应的宿主进程号执行 `perf record`。

---

## 4. 秒表怎么启动（脚本已按此尝试）

较新的 AOSP 时钟使用：

```text
com.android.deskclock.action.SHOW_STOPWATCH
com.android.deskclock.action.START_STOPWATCH
```

脚本先解析包名，再发送「显示秒表」和「开始走时」。若失败，请把 `adb shell cmd package resolve-activity` 的输出保存下来，改脚本里的包名后重新固化，不要改用手点。

秒表走时后，界面大约每几十毫秒改一次数字。这就是这份环境的负载：应用重绘，窗口合成器再叠一层。不要在走时过程中按圈数或切到闹钟，那会变成另一条路径。

---

## 5. 换 SwiftShader 库时哪些能动

只允许改 `/vendor/lib64/hw/vulkan.pastel.so`（以及 32 位镜像上对应的 `/vendor/lib/hw/` 文件），然后重启容器，用同一脚本再跑一遍。

不允许同时改：镜像摘要、处理器个数、内存、分辨率、帧率、`ThreadCount`、秒表安装包、录制时长。否则无法判断变快是因为库，还是因为环境变了。

---

## 6. 验收：环境算不算已经固化

同时满足下列各项，才算这份极限环境已经钉住：

- 容器内 `nproc` 为 4。
- `MemTotal` 约为 8 吉字节量级（允许内核预留造成的少量偏差）。
- `ro.hardware.vulkan` 为 `pastel`。
- 宽度、高度、点数、目标帧率与上表一致。
- 指纹文件里的镜像摘要与启动命令一致。
- 连续两次不换库、只重跑脚本，第 99 百分位帧时间和处理器占用的差异小到你们能接受（建议先看是否在百分之十以内；差太多说明预热或绑核还没稳住）。

还没满足最后一条时，先稳环境，不要开始换库对比。
