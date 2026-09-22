# `src/` 逐文件说明

配对出现的 `.hpp` / `.cpp` 当作一个单元。只列**读代码时真正会跳进去的函数**，完整签名以头文件为准。

路径均相对 `src/`。

---

## 0. 目录根：怎么编进 `vulkan.pastel`

| 文件 | 作用 |
| --- | --- |
| `Android.bp` | AOSP/Soong：静态库 `libswiftshadervk_llvm` + 共享库 `vulkan.pastel`。定义 `REACTOR_ANONYMOUS_MMAP_NAME=swiftshader_jit`。 |
| `BUILD.gn` / `swiftshader.gni` | Chromium/GN 构建。 |
| `CMakeLists.txt` | 独立 CMake 构建。 |
| `commit_id.py` | 把 git hash 写进版本字符串。 |
| `clang-format-all.sh` / `clang-format-separate.sh` | 格式化脚本。 |

---

## 1. `Device/` — 一次 DrawCall 的调度

软件 GPU 的「指挥部」。不生成机器码，只准备状态、切 batch、调用已经 JIT 好的 Routine。

### 调度核心

| 文件 | 关键类型 / 函数 | 说明 |
| --- | --- | --- |
| `Renderer.hpp/.cpp` | `Renderer::draw` | 图形绘制入口：根据管线+动态状态选出三套 Routine，构造 `DrawCall`。 |
| | `Renderer::synchronize` | 等所有 in-flight DrawCall 结束。 |
| | `DrawCall::run` | marl 任务：顶点 → 图元 → 像素。 |
| | `DrawCall::processVertices` | 调顶点 Routine，填 `Triangle`。 |
| | `DrawCall::processPrimitives` | 调 `setupPrimitives`（实心/线/点）。 |
| | `DrawCall::processPixels` | 按 cluster 调像素 Routine。 |
| | `setupSolidTriangles` 等 | 把拓扑展开成三角形并调用 Setup Routine。 |
| | `DrawData` | 本次绘制的只读包：描述符、viewport、混合常数、推送常量。 |
| `Context.hpp/.cpp` | `setDepthStencilState` / `setColorBlendState` / `setVertexInputBinding` | 把 Vulkan 动态状态收进软件管线状态。 |
| | `IndexBuffer` / `VertexInputBinding` | 绑定的 VB/IB。 |
| `Config.hpp` | `MAX_COLOR_BUFFERS=8`、`OUTLINE_RESOLUTION=8192` 等 | 编译期上限。 |

### 三个 Processor（状态 → Routine 缓存）

状态结构会 `Memset` 清零后按位哈希，命中 `RoutineCache` 就复用 JIT。

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VertexProcessor.hpp/.cpp` | `setRoutineCacheSize` | 顶点 Routine LRU 大小。 |
| | `States` / `State` / `Input` | 顶点输入、裁剪、viewport 等是否进入哈希。 |
| | `VertexCache` / `VertexTask` | 批内顶点复用。 |
| `SetupProcessor.hpp/.cpp` | `setRoutineCacheSize` | setup Routine 缓存。 |
| | `BITS` | 状态位域（背面剔除、插值模式等）。 |
| `PixelProcessor.hpp/.cpp` | `setRoutineCacheSize` / `setBlendConstant` | 片元 Routine 缓存；混合常数。 |
| | `StencilOpState` / `Factor` | 模板与混合因子（参考值不进哈希）。 |
| | `RasterizerFunction` | 像素 Routine 的函数签名：`(device, primitive, count, cluster, clusterCount, draw)`。 |

### 光栅化与图元数据

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `Rasterizer.hpp` | `Rasterizer` | 像素 Routine 基类（持有 `generate()` 入口约定）。 |
| `QuadRasterizer.hpp/.cpp` | `generate` | 用 Reactor 写出「按扫描线走四像素」的骨架。 |
| | `rasterize` | y 范围循环。 |
| | `quad`（纯虚） | 子类（`PixelRoutine`）填四像素着色。 |
| | `interpolate` | 用平面方程插值属性。 |
| `Clipper.hpp/.cpp` | `Clipper::Clip` | 视锥/用户裁剪平面。 |
| `Polygon.hpp` | `Polygon` | 裁剪后的凸多边形。 |
| `Primitive.hpp` | `Triangle` / `Primitive` / `Span` | 顶点输出 → setup 后的边方程/梯度。 |
| `Vertex.hpp` | 顶点属性布局 | 与 `MAX_INTERFACE_COMPONENTS` 对齐。 |
| `Stream.hpp` | `Stream` | 顶点流描述。 |
| `Sampler.hpp` | `Mipmap` / `Texture` / `Sampler` | JIT 采样器看到的纹理描述块（不是 `vk::Sampler` 句柄）。 |
| `RoutineCache.hpp` | LRU of `Routine` | Processor 共用的 JIT 函数缓存。 |
| `Memset.hpp` | `Memset<T>` | 状态结构必须 trivial + 可 `memset`，否则哈希不稳定。 |

### 拷贝 / 压缩格式

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `Blitter.hpp/.cpp` | `getBlitRoutine` | blit/resolve/clear 也走 JIT（缩放、sRGB、过滤）。 |
| | `getCornerUpdateRoutine` | cube 边界缝。 |
| | `ApplyScaleAndClamp` / `ComputeOffset` | 坐标变换。 |
| `ETC_Decoder.hpp/.cpp` | `Decode` | ETC/EAC。 |
| `BC_Decoder.hpp/.cpp` | `Decode` | BC1–BC7。 |
| `ASTC_Decoder.hpp/.cpp` | `ASTC_Decoder` | ASTC（调用 third_party encoder 的解码）。 |

---

## 2. `Pipeline/` — 对着状态写机器码

这里的 C++ **不会在绘制时逐条解释**。它用 Reactor 类型（`Float4`、`If()`、`For()`）描述「应该生成什么样的函数」，`generate()` 时 LLVM 编一次，之后只调函数指针。

### 图形三件套

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VertexRoutine.hpp/.cpp` | `VertexRoutinePrototype` | 顶点 Routine 骨架：取顶点、调 shader、写 clip 空间。 |
| `VertexProgram.hpp/.cpp` | `VertexProgram` | 把 SPIR-V 顶点着色器嵌进 Routine。 |
| `SetupRoutine.hpp/.cpp` | `getRoutine` | 生成 setup 函数。 |
| | `setupGradient` | 三角形平面方程 / 属性梯度。 |
| `PixelRoutine.hpp/.cpp` | `setBuiltins` / `executeShader` / `writeColor` 等 | 四像素路径：内建变量、跑片元 SPIR-V、深度/模板、混合、写 RT。 |
| | `getSampleSet` | MSAA 样本集合。 |
| `PixelProgram.hpp/.cpp` | `setBuiltins` | 片元 SPIR-V 与 PixelRoutine 的接缝。 |

热点几乎总在 `PixelRoutine` 内循环 + 它调用的 sampler。

### 采样器

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `SamplerCore.hpp/.cpp` | `sampleTexture` | 主入口：按 `SamplerMethod`（Implicit/Lod/Gather/Fetch/Read/Write…）采样。 |
| | `computeLod2D` / `computeLodCube` / `computeLod3D` | 算 LOD / 各向异性。 |
| | `computeIndices` | texel 地址。 |
| | `bilinearInterpolate` / `bilinearInterpolateFloat` | 双线性。 |
| | `selectMipmap` | 选 mip。 |
| | `address` | wrap/clamp/mirror。 |
| | `sampleLumaTexel` / `sampleChromaTexel` | YCbCr。 |
| `SamplerFunction` | 生成独立 `"sampler"` Routine 或内联进 PixelRoutine。 | |

### SPIR-V 翻译

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `SpirvShader.hpp/.cpp` | `Spirv` / `Type` / `Object` / `Block` | SPIR-V 模块的软件表示。 |
| | `DeclareType` / `ProcessExecutionMode` | 类型与 execution mode。 |
| | `TraverseReachableBlocks` / `AssignBlockFields` | CFG。 |
| | `getWorkgroupSizeX/Y/Z` | 计算着色器本地大小。 |
| `SpirvShaderInstructions.cpp` | 多数 Op* 分发 | 算术之外的指令。 |
| `SpirvShaderArithmetic.cpp` | 算术/转换 Op | |
| `SpirvShaderControlFlow.cpp` | 选择/循环/Phi | |
| `SpirvShaderMemory.cpp` | Load/Store/AccessChain | |
| `SpirvShaderImage.cpp` | 图像读写真机 | |
| `SpirvShaderSampling.cpp` | `OpImageSample*` → `SamplerCore` | |
| `SpirvShaderGroup.cpp` | subgroup / group 操作 | |
| `SpirvShaderGLSLstd450.cpp` | GLSL.std.450 扩展 | |
| `SpirvShaderSpec.cpp` | specialization constant | |
| `SpirvShaderDebugger.cpp` / `SpirvShaderDebug.hpp` | shader printf / 调试值 | |
| `SpirvBinary.hpp/.cpp` | `SpirvBinary` | 原始 SPIR-V 字节 + 优化缓存键。 |
| `SpirvID.hpp` | `SpirvID` | 结果 ID 包装。 |
| `SpirvProfiler.hpp/.cpp` | `RegisterShaderForProfiling` / `ReportSnapshot` | 可选 SPIR-V 剖析（`SwiftShader.ini` 打开）。 |

### 计算着色器与公共数学

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `ComputeProgram.hpp/.cpp` | `setWorkgroupBuiltins` / `setSubgroupBuiltins` | 计算 Routine：一个 workgroup 的 JIT。 |
| `ShaderCore.hpp/.cpp` | `Vector4f` / `Vector4s` / `Sin` `Exp2` `Log2`… | 着色器运行时数学（生成 SIMD 代码）。 |
| `Constants.hpp/.cpp` | `Constants` | 光栅化用的常量表（供 QuadRasterizer 指针使用）。 |

---

## 3. `Reactor/` — DSL 和 JIT 后端

对外表现：C++ 里写 `Float4 a = b + c;`，实际往 LLVM IR 里插一条向量加。

### 前端（生成 IR）

| 文件 | 关键类型 / 函数 | 说明 |
| --- | --- | --- |
| `Reactor.hpp/.cpp` | `rr::Int` / `Float` / `Float4` / `Int4` / `Pointer` / `Array` | 标量与 SIMD 类型；运算符重载。 |
| | `If` / `Else` / `For` / `While` | 控制流宏/类，对应基本块。 |
| | `Function<Return(Args...)>` | 声明要 JIT 的函数。 |
| | `Call` / `CallHelper` | 调另一个 Routine 或外部 C 函数。 |
| | `EmitDebugLocation` / `DebugPrintf` | JIT 调试。 |
| `Nucleus.hpp` | `Nucleus` | 后端无关 IR：基本块、值、类型。 |
| | `setInsertBlock` / `setOptimizerCallback` | 插入点与优化回调。 |
| `SIMD.hpp/.cpp` | `SIMD::Float` / `Int` / `Load` / `Store` / `CmpEQ`… | 宽度=`SIMD::Width`（x86 上为 4）。片元四像素走这里。 |
| `Traits.hpp` | `CToReactorT` 等 | 把 C++ 类型映射到 Reactor 类型。 |
| `Swizzle.hpp` | `.x/.y/.z/.w` 与 mask | 向量重排。 |
| `Routine.hpp` | `Routine` / `RoutineT<>` | JIT 产物：可调用函数 + 可执行内存所有权。 |
| `Print.hpp` | `PrintValue` / `RR_PRINT` | 在生成的代码里打印。 |
| `Coroutine.hpp` | `Coroutine<>` | 生成可暂停函数（compute/yield 类用途）。 |
| `Pragma.hpp` / `PragmaInternals.hpp` | `ScopedPragma` | 局部关闭某项优化。 |
| `Assert.hpp/.cpp` | JIT 内断言 | |
| `x86.hpp` | x86 内建/约定 | |

### LLVM 后端

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `LLVMReactor.hpp/.cpp` | `JITBuilder` | Nucleus → LLVM IR。 |
| `LLVMJIT.cpp` | ORC JIT 引擎 | 编译、链接、分配可执行页；匿名 mmap 名字在此生效。 |
| `LLVMAsm.hpp/.cpp` | 可选汇编转储 | 对照 `SWIFTSHADER_LLVM_ASM` 一类开关。 |
| `LLVMReactorDebugInfo.hpp/.cpp` | `EmitLocation` / `NotifyObjectEmitted` | DWARF，让 debugger/perf 能对上源行。 |
| `Optimizer.hpp/.cpp` | LLVM pass 管线 | 每次生成 Routine 时跑。 |
| `ExecutableMemory.hpp/.cpp` | `allocateExecutable` / `protect` | RW → RX；即 perf 里的 `r-xp` 匿名页。 |
| `ReactorDebugInfo.hpp/.cpp` | `getCallerBacktrace` | 记录是哪段 C++ 生成了这条 IR。 |

### 其它后端 / CPU 探测

| 文件 | 说明 |
| --- | --- |
| `SubzeroReactor.cpp` | Subzero 后端（体积小、编译快，性能通常不如 LLVM）。 |
| `CPUID.hpp/.cpp` | 运行时探测 SSE/AVX 等，决定能生成哪些指令。 |

---

## 4. `System/` — 运行时基础设施

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `SwiftConfig.hpp/.cpp` | `Configuration` / `getSchedulerConfiguration` | 读 ini：线程数默认 `min(ncpu,16)`、亲和性、SPIR-V profiler。 |
| `Configurator.hpp/.cpp` | `getInteger` / `getBoolean` / `getValueIfExists` | 通用 ini 解析（**只读 cwd 下的文件**）。 |
| `Synchronization.hpp` | `CountedEvent` / `Chan` | DrawCall 完成计数；队列与 `Renderer::synchronize` 配合。 |
| `LRUCache.hpp` | `LRUCache` | Routine / pipeline cache 底层。 |
| `Memory.hpp/.cpp` | 对齐分配 | Device/Image 后备。 |
| `Linux/MemFd.hpp/.cpp` | `LinuxMemFd` | Linux memfd；Android AHB 路径会碰到类似机制。 |
| `CPUID.hpp/.cpp` | `setFlushToZero` / `setDenormalsAreZero` | 渲染线程 FP 模式（和 Reactor/CPUID 分工：这里偏运行时控制）。 |
| `Math.hpp/.cpp` | `FNV_1a` 等 | 哈希、整数数学。 |
| `Half.hpp/.cpp` | `half` / `RGB9E5` / `R11G11B10F` | 16-bit / packed float。 |
| `Types.hpp` | `vec<T,N>` | 小向量。 |
| `Timer.hpp/.cpp` | `Timer` | 剖析计时。 |
| `Socket.hpp/.cpp` | `Socket` | 调试服务器（见 `Vulkan/Debug`）。 |
| `SharedLibrary.hpp` | 动态库加载 | WSI 里 dlopen xcb/wayland。 |
| `Build.hpp/.cpp` | 构建信息字符串 | |
| `Debug.hpp/.cpp` | 断言、日志 | |

---

## 5. `Vulkan/` — ICD 与对象模型

应用只看见这一层。每个 `VkXxx` 句柄对应 `vk::Xxx`，经 `VkObject.hpp` 的 `Cast<>` 转换。

### 入口与实例

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `libVulkan.cpp` | 全部 `vk*` 导出 | ICD 壳：参数检查后转到 `vk::` 对象。含 `vkQueueSignalReleaseImageANDROID`。 |
| `main.cpp` | 库加载/进程入口 | 平台相关。 |
| `VkGetProcAddress.hpp/.cpp` | `GetInstanceProcAddr` / `GetDeviceProcAddr` | `vkGet*ProcAddr`。 |
| `VkInstance.hpp/.cpp` | `getPhysicalDevices` | 实例；通常一台「SwiftShader GPU」。 |
| `VkPhysicalDevice.hpp/.cpp` | `getFeatures2` / `getProperties` / `GetFormatProperties` | 能力与格式表（软件实现的上限）。 |
| `VkDevice.hpp/.cpp` | `getQueue` / `SamplingRoutineCache` | 逻辑设备；持有 `Renderer`、采样 Routine 缓存、私有数据。 |
| `VkObject.hpp` | `Object<T,VkT>` / `DispatchableObject` | 句柄、分配作用域、`Cast`。 |
| `VulkanPlatform.hpp` | `VkNonDispatchableHandle` | 非 dispatchable 句柄布局。 |
| `Version.hpp` | ICD 版本 | |
| `VkConfig.hpp` | Vulkan 层编译期上限 | |
| `VkDestroy.hpp` | 统一销毁辅助 | |
| `VkMemory.hpp/.cpp` | 分配回调封装 | |
| `VkPromotedExtensions.cpp` | 核心版本吸收的扩展入口别名 | |
| `VkStringify.hpp/.cpp` | `Stringify` | enum → 字符串（日志/调试）。 |
| `VkStructConversion.hpp` | `CopyImageInfo` 等 | `Vk*Info` 与 `Vk*Info2` 互转。 |

### 命令、队列、管线

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VkQueue.hpp/.cpp` | `submitQueue` | `vkQueueSubmit`：执行命令缓冲、信号 fence/semaphore。 |
| `VkCommandBuffer.hpp/.cpp` | `setViewport` / `setScissor` / 各 `vkCmd*` 对应方法 | 记录命令；submit 时回放。`ExecutionState` 是回放光标。 |
| `VkCommandPool.hpp/.cpp` | `ComputeRequiredAllocationSize` | 命令池。 |
| `VkPipeline.hpp/.cpp` | `GraphicsPipeline` / `ComputePipeline` | 编译着色器、收集静态状态；`getCombinedState` 给 Renderer。 |
| | `PushConstantStorage` | 推送常量块。 |
| `VkPipelineLayout.hpp/.cpp` | `getBindingOffset` / `getDescriptorSize` | 描述符集布局拼在一起。 |
| `VkPipelineCache.hpp/.cpp` | `getOrOptimizeSpirv` / `getOrCreateComputeProgram` | SPIR-V 优化与 compute Program 缓存。 |
| `VkShaderModule.hpp/.cpp` | SPIR-V 容器 | |
| `VkSpecializationInfo.hpp/.cpp` | 特化常量拷贝 | `ComputeRequiredAllocationSize` 模式：对象可变长，尾随分配。 |
| `VkRenderPass.hpp/.cpp` | `MarkFirstUse` / `getRenderAreaGranularity` | 附件 load/store、subpass。 |
| `VkFramebuffer.hpp/.cpp` | `setAttachment` | 附件 = `ImageView`。 |

### 图像、内存、描述符

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VkImage.hpp/.cpp` | `bind` / `copyTo` / `copyFrom` / `blitTo` / `resolveTo` / `clear` | 图像存储与传输。 |
| | **`prepareForExternalUseANDROID`** | 上屏前把线性内容拷进 AHB（嵌套 Android 热点）。 |
| | `getSubresourceLayout` / `getMipLevelExtent` | 布局查询。 |
| `VkImageView.hpp/.cpp` | `ResolveComponentMapping` / `getState` | 采样/渲染用的视图；`State` 会进 sampler 哈希。 |
| `VkBuffer.hpp/.cpp` | `GetMemoryRequirements` / `getOpaqueCaptureAddress` | |
| `VkBufferView.hpp/.cpp` | texel buffer 视图 | |
| `VkFormat.hpp/.cpp` | `getAspects` / `getDecompressedFormat` / `getCompatibleFormats` | 软件格式表：块压缩、YUV、clear 格式。 |
| `VkDeviceMemory.hpp/.cpp` | `Allocate` / `ParseAllocationInfo` | 普通设备内存。 |
| `VkDeviceMemoryExternalAndroid.hpp/.cpp` | `AHardwareBufferExternalMemory` / `GetAndroidHardwareBufferProperties` | AHB import/export。 |
| `VkDeviceMemoryExternalLinux.hpp` | `OpaqueFdExternalMemory` | `opaque_fd`。 |
| `VkDeviceMemoryExternalHost.hpp/.cpp` | `ExternalMemoryHost` | host pointer 导入。 |
| `VkDeviceMemoryExternalMac.hpp` | macOS fd/IOSurface 类导入 | |
| `VkDeviceMemoryExternalFuchsia.hpp` | `VmoExternalMemory` | Zircon VMO。 |
| `VkSampler.hpp/.cpp` | `Sampler` / `SamplerYcbcrConversion` | 采样状态；与 `Device/Sampler.hpp` 的纹理块是两层。 |
| `VkDescriptorSet.hpp/.cpp` | `ContentsChanged` / `PrepareForSampling` / `ParseDescriptors` | 描述符内容；采样前可能解码压缩纹理。 |
| `VkDescriptorSetLayout.hpp/.cpp` | `WriteDescriptorSet` / `getBindingOffset` | |
| `VkDescriptorPool.hpp/.cpp` | 描述符堆 | |
| `VkDescriptorUpdateTemplate.hpp/.cpp` | 批量更新 | |

### 同步与查询

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VkFence.hpp` | `Fence` | CPU 侧完成。 |
| `VkEvent.hpp` | `Event` | GPU 侧事件（软件里就是原子/条件）。 |
| `VkSemaphore.hpp/.cpp` | `BinarySemaphore` | 队列间二进制信号。 |
| `VkSemaphoreExternalLinux.hpp` | `OpaqueFdExternalSemaphore` | |
| `VkSemaphoreExternalFuchsia.hpp` | `ZirconEventExternalSemaphore` | |
| `VkTimelineSemaphore.hpp/.cpp` | `getCounterValue` / `WaitForAny` | 时间线信号量。 |
| `VkQueryPool.hpp/.cpp` | `Query::set` / `getData` | occlusion / timestamp 等。 |
| `VkPrivateData.hpp` | `PrivateData` | `VK_EXT_private_data`。 |
| `VkDebugUtilsMessenger.hpp/.cpp` | 验证消息回调 | |

### 构建与导出符号（非运行逻辑）

| 文件 | 说明 |
| --- | --- |
| `vk_swiftshader_icd.json` / `.tmpl` / `write_icd_json.py` | ICD 发现文件。 |
| `vk_swiftshader.exports` / `.def` / `*.lds` | Linux/Windows/Fuchsia/Android 导出脚本。 |
| `android_vk_swiftshader.lds` / `android_host_vk_swiftshader.lds` / `fuchsia_vk_swiftshader.lds` | 同上。 |
| `Vulkan.rc` / `resource.h` | Windows 版本资源。 |
| `vulkan.gni` / `BUILD.gn` / `CMakeLists.txt` | 子目录构建。 |

### `Vulkan/Debug/` — 可选着色器调试器

通过 socket 连外部调试器，不是绘制热路径。

| 文件 | 关键类型 | 说明 |
| --- | --- | --- |
| `Server.hpp/.cpp` | `Server` | 监听客户端。 |
| `Context.hpp/.cpp` | `Context::get` | 全局调试上下文、函数断点。 |
| `Thread.hpp/.cpp` | `Thread` / `Frame` / `Scope` | 模拟调用栈。 |
| `File.hpp/.cpp` | `File::getBreakpoints` | 源文件断点。 |
| `Value.hpp/.cpp` | `Constant` / `Reference` / `Struct` | 变量值。 |
| `Variable.hpp/.cpp` | `Variables` / `VariableContainer` | 作用域变量表。 |
| `EventListener.hpp/.cpp` | 服务端/客户端事件 | |
| `Location.hpp` / `ID.hpp` / `WeakMap.hpp` | 位置、ID、弱引用表 | |
| `TypeOf.hpp/.cpp` | 类型描述 | |
| `Debug.cpp` | 调试模块胶水 | |

---

## 6. `WSI/` — 窗口系统（桌面 present）

Android 嵌套 ReDroid 合成 **通常不走这里**，走 AHB。桌面/无头测试才会用。

| 文件 | 关键函数 | 说明 |
| --- | --- | --- |
| `VkSurfaceKHR.hpp/.cpp` | `GetSurfaceFormats` / `GetPresentModes` / `SetCommonSurfaceCapabilities` | Surface 基类。`PresentImage` 是可 present 的图像包装。 |
| `VkSwapchainKHR.hpp/.cpp` | `getNextImage` / `getImages` | `vkAcquireNextImageKHR` / present 队列。 |
| `HeadlessSurfaceKHR.hpp/.cpp` | `VK_EXT_headless_surface` | 无窗口。 |
| `XcbSurfaceKHR.hpp/.cpp` | X11；`SHMPixmap` 共享内存 pixmap | |
| `libXCB.hpp/.cpp` | `LibXCB` | dlopen libxcb。 |
| `WaylandSurfaceKHR.hpp/.cpp` | `WaylandBuffer` / `WaylandImage` | |
| `libWaylandClient.hpp/.cpp` | dlopen libwayland-client | |
| `Win32SurfaceKHR.hpp/.cpp` | HWND | |
| `MetalSurface.hpp` / `MetalSurface.mm` | `MetalSurfaceEXT` / `MacOSSurfaceMVK` | macOS/Molten 层。 |
| `DisplaySurfaceKHR.hpp/.cpp` | `VK_KHR_display`：直接 scanout | |
| `DirectFBSurfaceEXT.hpp/.cpp` | DirectFB | |
| `BUILD.gn` / `CMakeLists.txt` | 子目录构建 | |

---

## 7. 按「想改什么」反查

| 目标 | 先打开 |
| --- | --- |
| 片元太慢 / `jit unknown` 在 PixelRoutine | `Pipeline/PixelRoutine.cpp`、`SamplerCore.cpp` |
| 纹理 gather/双线性 | `SamplerCore::sampleTexture`、`computeIndices` |
| 顶点慢 | `VertexRoutine.cpp`、`VertexProcessor.cpp` |
| 三角形 setup | `SetupRoutine.cpp`、`Clipper.cpp` |
| blit / resolve / clear | `Device/Blitter.cpp` |
| Android 上屏 memcpy | `VkImage::prepareForExternalUseANDROID`、`VkDeviceMemoryExternalAndroid.cpp` |
| 线程数、绑核 | `System/SwiftConfig.cpp` |
| 多开一张 RT、更大分辨率上限 | `Device/Config.hpp` |
| 新 Vulkan 入口 | `libVulkan.cpp` + 对应 `Vk*.cpp` |
| JIT 页名字、RX 内存 | `Reactor/LLVMJIT.cpp`、`ExecutableMemory.cpp`、`Android.bp` |
| SPIR-V 某条 Op 行为不对 | `Pipeline/SpirvShader*.cpp` |
| 桌面窗口 present | `WSI/VkSwapchainKHR.cpp` + 平台 Surface |

配合总览：[overview.zh.md](overview.zh.md)。
