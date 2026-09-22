# SwiftShader 当前架构（Vulkan）

读这份之前只需要记住三件事：

1. **没有 GPU。** 所有像素都在 CPU 上算。应用仍调用标准 Vulkan API。
2. **着色器不会解释执行。** SPIR-V 先被翻成 C++ 里的「代码生成器」，再由 LLVM 编成机器码，放进匿名可执行页（perf 里常显示成 `jit unknown`）。
3. **多核 + SIMD。** 三角形批次丢给 marl 线程池；一次处理 4 个像素（`SIMD::Width = 4`）。

## 1. 源码目录怎么分

```
应用 / SurfaceFlinger / ANGLE
        │  vkCreateInstance / vkQueueSubmit / …
        ▼
src/Vulkan     Vulkan ICD：句柄、命令缓冲、队列、图像、内存
        │  Renderer::draw()
        ▼
src/Device     一次 DrawCall 的调度：顶点 → 图元装配 → 像素
        │  生成 / 调用 Routine
        ▼
src/Pipeline   用 Reactor 语法写出 Vertex/Setup/Pixel/Sampler/Compute
        │  Nucleus IR
        ▼
src/Reactor    LLVM JIT（或 Subzero）→ 可调用的函数指针
        │
        ▼
src/System     线程数、SwiftShader.ini、内存、同步
src/WSI        窗口系统：swapchain / present（桌面）；Android 多用 AHB
```

| 目录 | 角色 | 运行时对应物 |
| --- | --- | --- |
| `Vulkan/` | 标准 Vulkan 入口（`libVulkan.cpp` 里几百个 `vk*`） | `libvk_swiftshader.so` / Android `vulkan.pastel` |
| `Device/` | 软件光栅化调度器 | `Renderer`、`DrawCall`、三个 Processor |
| `Pipeline/` | 「对着状态写机器码」的生成器 | `PixelRoutine_%08X`、`sampler` 等 JIT 页 |
| `Reactor/` | 嵌入式 DSL + JIT 后端 | 匿名 `r-xp` mmap，Android 上名字 `swiftshader_jit` |
| `System/` | 配置、数学、缓存、同步 | `SwiftShader.ini`、`marl::Scheduler` |
| `WSI/` | `VK_KHR_swapchain` 各平台 Surface | 桌面 present；嵌套 ReDroid 上很少走到这里 |

`docs/Index.md` 画的四层（API / Renderer / Reactor / JIT）仍然对，但 **API 层现在只有 Vulkan**，不再有 OpenGL ES。

## 2. 一次 `vkCmdDraw` 实际走哪

命令记录在 `VkCommandBuffer` 里，真正干活发生在 `vkQueueSubmit`：

1. `Queue::submitQueue` 把命令缓冲交给设备。
2. 图形管线走到 `sw::Renderer::draw`。
3. 为这次绘制准备三套 **Routine**（状态哈希 miss 时现场 JIT）：
   - `VertexProcessor` → `VertexRoutine` / `VertexProgram`
   - `SetupProcessor` → `SetupRoutine`
   - `PixelProcessor` → `PixelRoutine` / `PixelProgram`（内部再调 `SamplerCore`）
4. `DrawCall::run` 按 batch（最多 128 个图元）切给 marl worker：
   - `processVertices`：跑顶点 JIT
   - `processPrimitives`：裁剪、装配、算平面方程
   - `processPixels`：四像素一组光栅化 + 片元着色 + 写颜色/深度
5. 输出写到 `vk::Image` 的设备内存。上屏另走拷贝路径（见第 4 节）。

计算着色器不经过 Renderer，走 `ComputePipeline` → `ComputeProgram`。

## 3. JIT 在 perf 里长什么样

Reactor 把生成的函数放进匿名可执行内存。Android `src/Android.bp` 里：

```
-DREACTOR_ANONYMOUS_MMAP_NAME=swiftshader_jit
```

所以 `/proc/<pid>/maps` 上这些页的名字是 `swiftshader_jit`。Routine 内部还会带符号式名字：

| 名字模式 | 谁生成 | 干什么 |
| --- | --- | --- |
| `PixelRoutine_%08X` | `Pipeline/PixelRoutine.cpp` | 片元内循环：插值、跑 SPIR-V、混合、写颜色 |
| `VertexRoutine_%08X` | `Pipeline/VertexRoutine.cpp` | 顶点着色 + 输出装配 |
| `SetupRoutine` | `Pipeline/SetupRoutine.cpp` | 三角形 setup（边方程、梯度） |
| `"sampler"` | `Pipeline/SamplerCore.cpp` | 纹理采样（gather / bilinear / cube…） |

`%08X` 是管线状态哈希。同一套混合/格式/着色器会复用同一块 JIT。

嵌套 ReDroid 上，SurfaceFlinger 合成时 **90%+ 的 JIT 样本落在 PixelRoutine + sampler**，而不是顶点或 setup。

## 4. Android 上屏（和桌面不同）

桌面：`vkQueuePresentKHR` → `WSI/VkSwapchainKHR` → 各平台 Surface。

Android（含 ReDroid `gpu_mode=guest`）：交换链图像是 **AHardwareBuffer（memfd）**。合成器读的是这块共享内存，不走 `vkQueuePresentKHR`。

关键调用链：

```
vkQueueSignalReleaseImageANDROID          // libVulkan.cpp
  → Image::prepareForExternalUseANDROID() // VkImage.cpp
      按行 memcpy 到 AHB
```

`VkDeviceMemoryExternalAndroid` 把 Vulkan 图像绑到 AHB。这一步的 memcpy 经常和 JIT 采样打成 CPU 热点。

## 5. 可调参数（不用改代码）

工作目录下的 `SwiftShader.ini`（只认 **进程 cwd**，不是库所在目录）：

- `[Processor] ThreadCount=0`：`0` 表示 `min(ncpu, 16)`，marl worker 数量。
- `AffinityMask` / `AffinityPolicy`
- `[Profiler]` SPIR-V 剖析开关

对应实现：`System/SwiftConfig.cpp`、`System/Configurator.cpp`。

## 6. 和旧文档的差异

| 旧 `Index.zh.md` | 当前树 |
| --- | --- |
| OpenGL ES / Direct3D API 层 | 只实现 Vulkan 1.3 ICD |
| `src/Renderer`、`src/Shader`、`src/OpenGL` | 已删除；调度在 `src/Device`，着色器在 `src/Pipeline` |
| 固定管线为主 | SPIR-V → Reactor → LLVM |
| present = swapchain | Android 上是 AHB + `vkQueueSignalReleaseImageANDROID` |

下一篇按文件列出关键函数：[src-files.zh.md](src-files.zh.md)。
