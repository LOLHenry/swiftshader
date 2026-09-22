# SwiftShader 管线工作流图

本文画的是 **本仓库自己的渲染管线**（`src/Device/Renderer.cpp`、`src/Pipeline/`），不是 Mesa。

Mesa LLVMpipe 和 SwiftShader **没有代码依赖、也不在同一条调用链上**。它只是同类 CPU 软光栅，对照见 [LLVMpipeWorkflow.zh.md](LLVMpipeWorkflow.zh.md)。redroid / ARM 上真正跑的是下面这条。

面向非图形专业读者：遇到术语可回到 [SoftwareRenderingOptimization.zh.md](SoftwareRenderingOptimization.zh.md) 第 3 节。

---

## 1. 和 Mesa 的关系（先说清楚）

| | SwiftShader（本仓库） | Mesa LLVMpipe / Lavapipe |
|--|----------------------|--------------------------|
| 是什么 | Google 的 CPU Vulkan 驱动（Android 上常叫 `vulkan.pastel`） | Mesa 里另一套 CPU OpenGL/Vulkan 驱动 |
| 代码 | `src/Vulkan` + `src/Device` + `src/Pipeline` + `src/Reactor` | Mesa 的 Gallium `pipe_*` |
| 谁调用谁 | **互不调用** | **互不调用** |
| 相似点 | 都按绘制状态 JIT 一份专用函数，在 CPU 上填像素 | 同左 |
| 用它干什么 | 你的 redroid 无 GPU 路径就是它 | 对照「别人怎么给 JIT 起名字、怎么 profile」 |

所以：优化帧率要改的是 SwiftShader 这条管线；Mesa 的图不能拿来当 SwiftShader 源码地图。

---

## 2. 总览：一张图怎么从应用走到 CPU

redroid 无 GPU 时，应用并不直接碰 SwiftShader。中间还有 HWUI/Skia、GLES、ANGLE。进到本仓库之后，四层是：

**Vulkan API → Renderer（调度）→ Reactor（记录要生成的代码）→ LLVM JIT（变成可调用函数）**

```mermaid
flowchart TB
  APP["应用 / HWUI / Skia"] --> GLES["OpenGL ES"]
  GLES --> ANGLE["ANGLE：GLES → Vulkan"]
  ANGLE --> VK["SwiftShader ICD<br/>src/Vulkan  vulkan.pastel"]

  VK --> CB["vkCmdDraw 记进 CommandBuffer"]
  CB --> Q["vkQueueSubmit<br/>回放命令"]
  Q --> R["sw::Renderer::draw<br/>src/Device/Renderer.cpp"]

  R --> VP["VertexProcessor<br/>顶点例程"]
  R --> SP["SetupProcessor<br/>图元装配例程"]
  R --> PP["PixelProcessor<br/>像素例程 = 光栅 + 片元"]

  VP --> RR["Reactor 记录 IR"]
  SP --> RR
  PP --> RR
  RR --> JIT["LLVM JIT<br/>ARM64 不能用 Subzero"]
  JIT --> MEM["可执行内存 swiftshader_jit"]
  MEM --> RUN["工作线程真正跑这些函数"]
  RUN --> FB["颜色 / 深度 / 模板缓冲"]
```

应用开发者、APK、redroid 镜像 **都不用写 Reactor**。只有改 SwiftShader 源码的人才碰中间那两层。

---

## 3. 一次 `vkCmdDraw` 怎么走完

记录和执行是分开的：`vkCmdDraw` 只往命令缓冲里塞一条 `CmdDraw`；真正算像素发生在 `vkQueueSubmit` 回放时。

```mermaid
flowchart TD
  DRAW["vkCmdDraw / vkCmdDrawIndexed"]
  REC["CommandBuffer 记下 CmdDraw<br/>顶点数、实例数、索引"]
  SUB["vkQueueSubmit"]
  EXE["CmdDraw::execute"]
  BIND["绑附件、描述符、顶点输入"]
  LOOP["按 instance × layer 循环"]
  RD["renderer->draw(pipeline, ...)"]

  DRAW --> REC --> SUB --> EXE --> BIND --> LOOP --> RD
```

`Renderer::draw` 里先按当前管线状态 **取或生成三份例程**，再把这次绘制拆成若干 **batch** 丢进 marl 任务队列：

```mermaid
flowchart TD
  RD["Renderer::draw"]

  UPD["用 GraphicsPipeline 状态做 hash"]
  V{"顶点例程缓存命中？"}
  S{"装配例程缓存命中？"}
  P{"像素例程缓存命中？"}

  VJIT["new VertexProgram → generate → JIT"]
  SJIT["new SetupRoutine → generate → JIT"]
  PJIT["new PixelProgram → generate → JIT<br/>符号名 PixelRoutine_%08X"]

  PACK["填 DrawData：视口、剪刀、颜色/深度指针、push constant"]
  RUN["DrawCall::run"]

  RD --> UPD
  UPD --> V
  UPD --> S
  UPD --> P
  V -->|否| VJIT
  S -->|否| SJIT
  P -->|否| PJIT
  V -->|是| PACK
  S -->|是| PACK
  P -->|是| PACK
  VJIT --> PACK
  SJIT --> PACK
  PJIT --> PACK
  PACK --> RUN
```

状态一变（换着色器、开关混合、改深度测试），hash 就变，可能再 JIT 一次。同样状态再来，走缓存，不再编译。

---

## 4. 三个 Processor：顶点 → 装配 → 像素

这是 SwiftShader 自己的「pipe」。对应代码：

- `src/Device/VertexProcessor.cpp` + `src/Pipeline/VertexProgram.cpp`
- `src/Device/SetupProcessor.cpp` + `src/Pipeline/SetupRoutine.cpp`
- `src/Device/PixelProcessor.cpp` + `src/Pipeline/PixelProgram.cpp`（继承 `QuadRasterizer`）

```mermaid
flowchart TD
  subgraph batch["一个 batch（最多 MaxBatchSize=128 个图元）"]
    PV["processVertices"]
    TOPO["按拓扑展开成三角形索引<br/>list / strip / fan"]
    VR["vertexRoutine：<br/>读属性、顶点缓存 64 槽、<br/>跑 SPIR-V 顶点着色器、<br/>视口变换、裁剪标志"]
    PP2["processPrimitives"]
    SR["setupPrimitives → setupRoutine：<br/>背面剔除、插值梯度、<br/>线/点/实心三角"]
    VIS["numVisible > 0？"]
    PX["processPixels"]
  end

  PV --> TOPO --> VR --> PP2 --> SR --> VIS
  VIS -->|否，全被 cull| SKIP["结束这个 batch"]
  VIS -->|是| PX
```

像素阶段再按 **cluster** 切开，好让多核同时填同一批三角形盖住的像素。上限 `MaxClusterCount = 16`，和 `SwiftShader.ini` 里 `ThreadCount` 默认 `min(逻辑核, 16)` 对齐。

```mermaid
flowchart TD
  PX["processPixels"]
  C["cluster = 0 .. 15"]
  TICK["clusterTickets[cluster].onCall"]
  PR["pixelRoutine(primitives, cluster, 16, drawData)"]
  QR["QuadRasterizer：遍历这个 cluster 该画的像素"]
  Q["每次 2×2 quad（4 像素）"]

  PX --> C --> TICK --> PR --> QR --> Q

  subgraph quad["PixelRoutine::quad，四个像素一起走 SIMD"]
    ST["模板测试"]
    ZT["深度测试"]
    SH["executeShader：片元 SPIR-V"]
    AT["Alpha 测试 / alpha-to-coverage"]
    BL["混合，写颜色"]
  end

  Q --> ST --> ZT --> SH --> AT --> BL
```

`quad` 里没有模板就 JIT 时不会生成模板代码；没有混合就不会生成混合。这就是特化：当前绘制用到什么，机器码里才有什么。

老文档里的 `VertexPipeline` / `PixelPipeline` 是固定功能时代的类名。**当前 Vulkan 路径走的是 `VertexProgram` / `PixelProgram`（SPIR-V）**，目录在 `src/Pipeline/`，不在过时的 `src/Shader/`。

---

## 5. 着色器：SPIR-V 怎样编进那三份例程

```mermaid
flowchart LR
  SM["VkShaderModule<br/>SPIR-V 字节码"] --> SS["sw::SpirvShader"]
  SS --> VP2["VertexProgram::program"]
  SS --> PP3["PixelProgram::executeShader"]
  SS --> CS["ComputeProgram<br/>计算管线，另一条路"]

  VP2 --> RE["Reactor：Float / If / For<br/>看起来像 C++，实际在记账"]
  PP3 --> RE
  RE --> IR["LLVM IR"]
  IR --> MC["本机机器码"]
  MC --> CACHE["RoutineCache<br/>按 State hash 复用"]
```

采样走 `SamplerCore`；加减乘、纹理 LOD 等公共运算在 `ShaderCore`。x86 上部分运算会进 `rr::x86` 的 SSE 快路径；ARM 上多数靠 LLVM 自己降成 NEON，FMA / 近似倒数的开关目前仍偏 x86。那是指令层的事，不改变上面这张图的形状。

计算着色器（`vkCmdDispatch`）不走顶点/装配/像素这三段，而是 `ComputeProgram` 直接 JIT。UI / Skia 主路径几乎都是图形管线。

---

## 6. 并行怎么切：batch 和 cluster

```mermaid
flowchart TB
  D["一次 draw，N 个图元"] --> B["切成若干 batch<br/>每批最多 128 个图元"]
  B --> M["marl::schedule 每个 batch"]
  M --> V3["这个 batch：先顶点，再装配"]
  V3 --> CL["16 个 cluster 队列"]
  CL --> W["工作线程跑 pixelRoutine<br/>各画各的像素带"]
```

和帧率的关系：

- **图元多**：batch 变多，顶点/装配次数变多。
- **像素多**（分辨率、MSAA）：每个 cluster 的 `pixelRoutine` 更久。云手机界面通常是像素更贵。
- **容器能看见很多核**：每个进程都可能起最多 16 条渲染线程。所以先限 `ThreadCount`，再谈改指令。

---

## 7. 你在 profile 里会看见什么

热点若是匿名可执行页 `swiftshader_jit`，对应的就是图上 **已经 JIT 出来的 vertexRoutine / setupRoutine / pixelRoutine**。其中像素例程生成时会带名字 `PixelRoutine_%08X`（`%08X` 是 shaderID），但默认 **不会** 写成 Linux `perf` 的 `/tmp/perf-PID.map`，所以 `perf report` 往往只显示匿名映射。

打开分析的顺序仍然是：先确认时间在 SwiftShader 而不是 Skia/ANGLE → 再对 JIT 页做 RIP 聚类 → 需要的话开 `REACTOR_EMIT_ASM_FILE` 对照汇编。那是剖析手段，不是另一条渲染管线。

---

## 8. 一句话

SwiftShader 的管线是 **Vulkan 命令 → Renderer 按状态取出三份 JIT 函数 → 按 batch 做顶点、按 cluster 做 2×2 像素**。Mesa 的 Gallium pipe 不在这条路上；它只是业界另一套 CPU 光栅，用来对照「JIT 也能起名字」，不能当成本仓库的模块图。
