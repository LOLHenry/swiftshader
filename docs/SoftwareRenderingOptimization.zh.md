# SwiftShader 软渲染优化说明

面向非图形专业读者。说明 x86 上已经做了什么、ARM 上建议做什么，以及在无 GPU 的 ARM 服务器上大规模运行 redroid 时，怎样把帧率做上去。

本文不要求你先懂渲染。遇到术语会先讲它是什么、为什么出现、和帧率有什么关系。

---

## 1. 这份文档要解决什么问题

典型场景：

- 宿主机是 **ARM 服务器**
- 上面跑很多 **redroid** 容器（把 Android 当容器跑）
- **没有 GPU**（或不用宿主机 GPU）
- 画面由 CPU 用 SwiftShader「假装成显卡」画出来
- 目标是：**单容器更流畅，整机还能多开**

这和「手机浏览器偶尔用软件回退」完全不同。在你这里，软渲染就是产品本身：每个像素都在吃 CPU。优化错地方（比如一上来做 SVE、或给每个容器开 16 条渲染线程）会看起来像「改了指令却更卡」。

结论先说清楚：

1. **先管调度和像素量**（每容器几个核、分辨率、目标帧率），通常比改指令涨得更快。
2. **再补 ARM 上 x86 已经有、ARM 被关掉的那几条快路径**（FMA、近似倒数、饱和/pack、Blitter）。
3. **不要先做 SVE / 8 宽光栅**，那是换架构，不是把现网帧率拉上去。

---

## 2. 一张图是怎么画出来的

### 2.1 CPU 和 GPU

- **CPU**：通用处理器，擅长逻辑、调度、跑 Android 系统和应用。
- **GPU**：图形处理器，里面有成百上千个简单计算单元，专门把三角形变成屏幕上的像素。

手机、电脑通常把「画界面、画游戏」交给 GPU。你的服务器没有 GPU，就只能让 CPU 做 GPU 的工作。这叫 **软件渲染（software rendering）**：用软件在 CPU 上模拟一条显卡流水线。

特点：能跑、结果可以对，但比真 GPU 慢一到两个数量级。帧率直接取决于「每秒要算多少像素」和「每个像素算得多快」。

### 2.2 像素、分辨率、帧率、填充率

- **像素**：屏幕上的一个小点，通常要算颜色（红绿蓝，有时还有透明度）。
- **分辨率**：宽 × 高。1280×720 大约 92 万像素；1920×1080 大约 207 万，是前者的两倍多。
- **帧率（FPS）**：每秒画几张完整画面。30 FPS 表示每秒 30 张；60 FPS 是两倍工作量。
- **填充率**：每秒能填多少像素。软渲染时，填充率基本等于 CPU 算像素的速度。

所以：分辨率从 720p 升到 1080p，或帧率从 15 升到 30，CPU 工作量近似翻倍。大规模开容器时，这比「某条指令快 10%」更致命。

### 2.3 三角形、光栅化、片元

应用不会直接给每个像素涂色，而是提交 **三角形**（三维物体和很多二维控件最终都会拆成三角形）。

**光栅化（rasterization）**：判断三角形盖住了哪些像素，再给这些像素算颜色。被盖住的每个点常叫 **片元（fragment）**，可以理解成「待着色的像素候选」。

SwiftShader 一次不是算 1 个像素，而是算 **2×2 的一小块**（称为 **quad**）。四个像素一起走同一套指令，方便后面说的 SIMD。

### 2.4 你这条业务链（redroid，无 GPU）

redroid 是「Remote Android」：在 Linux 上用容器跑 Android 用户空间。无 GPU 时默认 `androidboot.redroid_gpu_mode=guest`，也就是软件渲染。文档里无 GPU 时默认帧率约 **15**，有 GPU 时约 **30**；默认宽度约 **1280**，DPI 约 **320**。

Android 12 以后，常见路径是：

```text
应用（Java/Kotlin UI 或游戏）
  → HWUI / Skia（把控件、文字、图片变成绘制命令）
    → OpenGL ES（应用和系统以为自己在对「显卡」说话）
      → ANGLE（把 GLES 翻译成 Vulkan）
        → SwiftShader（Vulkan 的 CPU 实现，Android 里常叫 vulkan.pastel）
          → 真正在 ARM CPU 上算像素
            → SurfaceFlinger（把各层窗口合成到虚拟屏幕）
```

中间每一层都有开销。极致帧率要同时看：**少画一些像素、少合成一些层、让最底层 SwiftShader 算得更快、别让 N 个容器把 CPU 抢光**。

---

## 3. 术语表：这些名字是什么、有什么特点

按「从用户能看见的，到 CPU 指令」排列。读方案时可以回到这里。

### 3.1 系统和 UI

**redroid**  
在 Docker / K8s 里跑的 Android。不是 QEMU 那套官方模拟器，不依赖 `/dev/kvm`。适合云手机、自动化、无 GPU 的 ARM 服务器。图形默认 `guest` = 软渲染。

**SurfaceFlinger**  
Android 的「窗口合成器」。每个 App 先画到自己的缓冲，再由 SurfaceFlinger 叠成你看到的那一张。软渲染时，应用画一遍、合成可能再处理一遍，两边都吃 CPU。

**Skia**  
Google 的 2D 图形库，Chrome 和 Android 都用。负责直线、曲线、文字、图片、圆角、模糊等。它输出的是「画什么」，真正加速靠底下的 GPU 或软渲染。云手机主界面、列表、WebView，很多时间耗在 Skia 的路径上。

特点：2D 很强；会触发大量混合、格式转换、缩放，而不一定是复杂 3D 着色器。

**HWUI**  
Android 的硬件 UI 渲染模块（Hardware UI）。系统把 View 树交给 HWUI，HWUI 再用 Skia + OpenGL ES（或 Vulkan）去画。名字带「Hardware」，没有 GPU 时仍然走这条逻辑，只是 GLES/Vulkan 落到 SwiftShader 上。

特点：应用开发者通常不直接碰 SwiftShader；他们写 View，HWUI/Skia 自动画。优化软渲染，优化的是他们看不见的那一层。

**OpenGL ES（GLES）**  
嵌入式设备上的 3D/2D 加速接口。Android 应用和 HWUI 大多对 GLES 说话。

**EGL**  
GLES 和「窗口 / 表面」之间的胶水：怎么创建画布、怎么交换前后缓冲。

**Vulkan**  
比 OpenGL 更现代、更底层的图形接口。驱动（或软渲染库）实现 Vulkan，应用或翻译层去调用。

**ANGLE**  
Google 的翻译层：把应用的 OpenGL ES 调用转成 Vulkan（或 D3D）。redroid 12+ 常用 ANGLE，再接到 SwiftShader 的 Vulkan。

**SwANGLE**  
ANGLE + SwiftShader：GLES → Vulkan → CPU 软渲染。

**ICD / pastel**  
Vulkan 的可安装驱动叫 ICD。SwiftShader 在 Android 上常叫 `vulkan.pastel`。`ro.hardware.vulkan=pastel` 表示「Vulkan 走软渲染」。

**不要**为了躲 ANGLE 随便退回老的 `libGLESv2_swiftshader`。社区里这样改过 SurfaceFlinger，容易直接崩。12+ 的正路是 ANGLE + pastel。

### 3.2 SwiftShader 内部

**SwiftShader**  
用 CPU 实现 Vulkan（历史上还有 OpenGL ES / Direct3D）的库。应用以为在对显卡说话，实际每条绘制都在 CPU 上算。目标是「不改应用、换驱动就能跑」。

**绘制调用（draw call）**  
「请用当前状态画这批三角形」。状态包括：用哪套着色器、混不混合、有没有深度测试、纹理格式等。状态一变，后面生成的机器码也可能变。

**着色器（shader）**  
对每个顶点或每个像素要跑的一小段程序。真 GPU 上在 GPU 里跑；SwiftShader 里会先翻译，再变成 CPU 上的函数。

**管线（pipeline）**  
从顶点 → 三角形装配 → 光栅化 → 逐像素测试/着色/混合 的整条工厂流水线。很多阶段可选，组合数量极大。

**特化（specialization）**  
不为「所有可能的管线」写一个万能解释器，而是：**当前这次绘制实际用到哪些功能，就生成一份只含这些功能的机器码**。没有模板测试，生成的函数里就没有模板测试。这是软渲染要快的核心思想。

**Reactor**  
SwiftShader 里嵌在 C++ 中的「代码生成语言」。写起来像 `Float y = 1 - x;`，运行时并不是立刻算 y，而是记下「以后要做减法」，再交给编译器变成函数。  
**用 SwiftShader 的应用（游戏、redroid 里的 APK）完全不用学 Reactor。** 只有改 SwiftShader 源码的人才写它。

**JIT（即时编译）**  
程序跑着的时候再编译，而不是出厂前一次编译死。好处：能按「这次的状态」特化。坏处：第一次遇到新状态会卡一下（编译风暴），编译结果一般只活在本进程里，容器重启就没了。

**LLVM**  
通用编译器框架。SwiftShader 用它的 JIT：把 Reactor 记下的运算变成 ARM 或 x86 机器码。CMake 默认后端。能力强、二进制更大。

**Subzero**  
更轻的 JIT，来自 Chrome 的 PNaCl。生成的库更小，所以 Chrome 在 x86 / ARMv7 上默认用它。**不支持 ARM64。** 你的 ARM 服务器应走 LLVM，不要选 Subzero。

**Routine（例程）**  
JIT 吐出来的那份可调用函数，例如「按当前混合模式处理一批 2×2 像素」。会缓存：同样状态再来就复用。

### 3.3 SIMD 和指令集

**标量 vs 向量（SIMD）**  
标量：一条指令处理 1 个数。  
**SIMD**（Single Instruction, Multiple Data）：一条指令同时处理多个数。好比一次给 4 个像素做加法，而不是循环 4 次。

SwiftShader 里宽度固定为 **4**（`SIMD::Width = 4`），正好对应 4 个 32 位浮点 = **128 位**，也正好是一个 2×2 quad。这是有意对齐 x86 SSE 和 ARM NEON 的 128 位寄存器，不是随便选的。

**SSE / SSE2 / SSE4.1**  
Intel/AMD 的 128 位 SIMD 扩展，1990–2000 年代陆续加入。

| 名字 | 直观理解 |
|------|----------|
| SSE | 开始能对 4 个 float 一起做加减乘、近似倒数 |
| SSE2 | 整数向量、更完整的 128 位能力；Chrome 长期把 SSE2 当 x86 最低配 |
| SSE4.1 | 更好的整数 min/max、pack 等，少写很多补丁指令 |

**特点**：历史包袱重。早期还有更窄的 MMX；很多指令语义很「x86 味」（例如 pack 的饱和规则、`rcpps` 只是近似）。LLVM 不会总自动选出这些指令，所以 SwiftShader 在 x86 上手写了一层对接。

**AVX2**  
256 位整数/浮点扩展，常和下面的 FMA 一起出现。SwiftShader **没有**把整条像素管线加宽到 8。AVX2 在这里主要用于「能不能发 FMA」，不是「一次算 8 个像素」。

**NEON（Advanced SIMD）**  
ARM 的 128 位 SIMD。AArch64（64 位 ARM）上是标配，不用像 x86 那样问「有没有 SSE2」。  
**特点**：同样是 128 位 4 个 float，和 SwiftShader 的 4 宽模型天生匹配。很多普通加减乘，LLVM 从可移植向量 IR 就能生成 NEON，不一定要手写。

**SVE / SVE2**  
ARM 的「长度可变」向量：128 到 2048 位，由 CPU 决定。理论上一次能算更多像素。  
**特点**：和当前「死写 Width=4、2×2 光栅、subgroup=4」不兼容。要用 SVE 吃满宽向量，等于改架构。对「先把 redroid 帧率做上去」不划算。

### 3.4 为什么那些具体指令值钱

**FMA / FMLA（融合乘加）**  
数学上就是 `a * b + c`，但用 **一条指令** 完成：先乘再加，中间结果更精确，延迟通常也更低。着色器、光照、插值里这种式子极多。

- x86：AVX2 机器上有 FMA；SwiftShader 用 `Caps::fmaIsFast()` 探测，为真才按「FMA 很快」来选算法。
- ARM：ARMv8 的 `FMLA` 是常驻能力，但当前探测函数 **只认 x86 的 AVX2**，在 ARM 上会当成「FMA 不快」，可能拆成普通乘 + 加。这是最不该漏掉的一刀。

**rcp / rcpps / Rcp（倒数）**  
算 `1/x`。透视、纹理 LOD、归一化经常要除法。除法比加减乘慢得多。

x86 的 `rcpps`：**近似**倒数，很快但不精确。图形里很多地方允许「差不多就行」（Vulkan/GLSL 的 relaxed precision）。不够准再做一次 **牛顿迭代** 补精度。

ARM 对应的是 `frecpe`（浮点倒数估计）。SwiftShader 里 `HasRcpApprox()` **只在 x86 为真**，ARM 上直接走 `1.0f / x` 真除法。采样重的界面（列表、缩放、各向异性）会吃亏。

**rsqrt / frsqrte（反平方根）**  
算 `1/sqrt(x)`，光照里对向量「归一化」极常见（除以长度 = 乘 `1/sqrt(x²+y²+z²)`）。x86 有 `rsqrtps`，ARM 有 `frsqrte`。道理和倒数一样：先估计，再迭代。Antonio Maiorano 在 2020 年把 x86 的 `RcpSqrt` 接到了这条路上；ARM 仍偏真除法 + sqrt。

**牛顿迭代（Newton-Raphson）**  
从粗答案出发，用一两次简单算术逼近真值。图形里常用「一条近似指令 + 一次迭代」替代慢除法。

**饱和运算（saturate）**  
结果超出类型范围时卡在头尾，而不是绕回。例如字节颜色加到 255 就停，不会变成 0。混合两个半透明像素时几乎总要饱和。x86 有 `paddusb`（无符号字节饱和加），NEON 有 `vqadd` / `vuqadd` 一类。

**pack（打包 / 窄化）**  
把宽数字压成窄数字，例如 32 位整数压成 8 位颜色，并带饱和。CPU 内部喜欢 32 位，屏幕和纹理喜欢 8 位。x86 的 `packssdw` / `packuswb` 一条指令干完；通用实现往往是一串比较和裁剪。

**min / max**  
逐通道取较小/较大。混合、夹紧颜色、深度范围都会用。SSE4.1 有专门的整数向量 min/max；没有时要「比较 + 用掩码挑选」，指令更多。

**pmovmskb / 符号掩码**  
从向量里抽出「每路是不是负数 / 是否通过测试」，变成一个整数位图，便于决定哪些像素还要写内存。x86 一条 `pmovmskb` / `movmskps`；别的架构常常要拆开拼。

**Blitter**  
负责整块图像的拷贝、清除、缩放、**MSAA resolve**（多重采样「拍平」成一张普通图）。它有时不走复杂着色器，而是手写循环。x86 上 Nicolas 用 SSE2 的 `_mm_avg_epu8`（字节平均）加速过 resolve；ARM 仍是标量循环。

**MSAA**  
多重采样抗锯齿：每个像素算多次再平均，边缘更平滑，填充量成倍增加。软渲染上非常贵。能关就关。

**DAZ / FTZ**  
x86 上把「太小的浮点数」（denormal）直接当 0，避免掉进极慢的微码。SwiftShader 在工作线程启动时会开。这是 x86 的坑；ARM 浮点行为不同，不是你现在的主战场。

---

## 4. x86 上已经做了哪些优化

### 4.1 谁做的、从哪来

商业起源是 TransGaming 的 CPU Direct3D，核心人物是 **Nicolas Capens**。2014 年以 code dump 进入 Chromium。进 Google 后，x86 SIMD、Reactor、CPUID、FMA 仍主要由他推进；Alexis Hétu 长期做审查。

这不是「2018 年才离开 x86」。更准确是：

- 产品从 x86 起步，SSE 特化层最厚。
- **2017** 年 ARM32 已能靠 **Subzero + 一批 NEON** 在 Android 上跑。
- **2018** Logan Chien 补的是 **LLVM 后端**里那些 SSE 专用算子的通用实现，让非 x86 用 LLVM 也能编过，不是「第一次支持 ARM」。

### 4.2 做法：不是手写整游戏，而是对接指令

SwiftShader 没有为每个游戏写内核。它做了两件事：

1. **按绘制状态 JIT 特化整条像素/顶点例程**（Reactor + LLVM/Subzero）。
2. 在 x86 上，对「LLVM 不太会主动选、但图形很爱用」的操作，用 `rr::x86` 直接调用 SSE/SSE2/SSE4.1 intrinsic（见 `src/Reactor/x86.hpp` 和 `LLVMReactor.cpp` 末尾）。

上层写 `AddSat`、`PackSigned`、`RcpApprox`，在 x86 走进这条快路径；其它架构走进 `lower*` 通用 lowering。

### 4.3 时间线上的具体工作

**2016–2017（定型，几乎全是 Capens）**

- 探测 SSE4.1；没有则发 SSE2 兼容序列（例如 `packusdw` 回退）。
- **默认假定 SSE2**（与 Chrome 最低配一致），去掉大量 MMX 死路径。
- 64 位向量用 128 位 SSE 模拟，**不再用 MMX**。
- 理清 saturating pack 的符号规则。

**2017 ARM32（对比用，不是 x86）**  
同一时期在 Subzero 里加了 ARM32 NEON：`VQMOVN` pack、`VMULL+VSHRN` 高位乘、`VLD1/VST1` 等。说明「ARM 特化」做过一轮，但对象是 32 位 + Subzero，不是后来的 ARM64 + LLVM。

**2018 Logan Chien**  
给 LLVM 补 generic codegen，并给 SSE 专用代码加 `#if x86`。没有它，ARM 上用 LLVM 会缺实现。

**2020**

- Capens：`Blitter` 里用 SSE2 做 MSAA resolve（公开 benchmark 里 Multisample 大约从 6.95ms 降到 4.03ms）。
- Antonio Maiorano：`RcpSqrt` 走近似 + 牛顿迭代；`inversesqrt` 不再裸 `1/sqrt`。

**2021–2022（仍以 Capens 为主）**

- 非 Windows x86 的 DAZ/FTZ。
- AVX2 + FMA 探测（还检查 OSXSAVE）。
- `MulAdd` / `Caps::fmaIsFast()`：有 AVX2 时让 LLVM 发 FMA；Subzero 仍拆成乘加。
- `Abs()` 改用 LLVM intrinsic。
- `rr::SIMD` 仍按 128 位实现 `SignMask` 等，为将来加宽留 `ASSERT`，当前宽度仍是 4。

### 4.4 现在 x86 快路径覆盖什么

| 类别 | 代表指令 | 图形上干什么 |
|------|----------|----------------|
| 饱和算术 | `paddusb` 等 | 颜色混合不超过 0–255 |
| Pack | `packssdw` / `packuswb` / `packusdw` | 宽通道收成屏幕格式 |
| 移位 | `psllw` / `psrad`… | 定点数、对齐、打包 |
| 掩码 | `movmskps` / `pmovmskb` | 哪些像素还要写 |
| 浮点 | `maxps` / `sqrt` / `rcpps` / `rsqrtps` / `roundps` | 光照、倒数、取整 |
| 转换 | `cvtps2dq` | 浮点颜色/坐标变整数 |
| 整数 min/max | SSE4.1 `pmaxsd` 等 | 夹紧 |
| 乘加 | `pmaddwd`；后期 AVX2 FMA | 点积、着色器 |

设计一直是：**SSE2 保底、SSE4.1 加速、AVX2 只用于 FMA**，不铺 AVX-512，也不把管线改成 8 宽。这和 4 宽 `Float4`、2×2 quad 一致。

---

## 5. 后面为什么没有一套对等的「rr::arm」

不是完全没人碰 ARM，而是 **没有再做一层和 `x86.hpp` 同样厚的手写表**。

1. **ARM64 只能走 LLVM。** Subzero 不支持 ARM64。AArch64 上 NEON 是标配，`<4 x float>` 的加减乘 LLVM 往往会自己发 NEON。x86 才有大量「LLVM 不肯选」的怪指令。
2. **产品压力不同。** Chrome 在手机上有 GPU，SwiftShader 是回退；x86 无独显的 VM/机器人更常见。2017 年 ARM32 能出货后，团队转向 Vulkan 合格，而不是堆 ARM64 指令表。
3. **宽度已经和 NEON 对齐。** 再特化是「同样 4 个数换更好的指令」，不是突然 4 倍吞吐。SVE 要动光栅骨架。
4. **所有权。** `rr::x86` 是 Capens 一条线带下来的。2018 后更多是「能编、能正确」，例如 2026 年还有人改 ARM 的 `fptosi_sat`，那是正确性和 LLVM 版本，不是 FMLA/`frecpe` 工程。

因此：ARM64 上「已经能跑、已经有 NEON」，缺的是 **x86 明确打开、ARM 明确关掉** 的那几条（FMA 探测、近似倒数、部分 pack/饱和、Blitter）。

---

## 6. 面向 redroid × ARM 服务器的完整方案

### 6.1 目标怎么定义

「极致帧率」在规模部署里其实是两件事，必须一起写进目标，否则会互相拆台：

- **单容器**：目标 UI 场景达到可接受 FPS（例如 20/30），抖动可控。
- **整机**：实例数 × 每实例 CPU ≈ 物理核，还能剩下给 Android 系统进程。

只追单容器、把 `ThreadCount` 拉到 16，整机一扩容就会全员掉帧。

### 6.2 第一阶段：调度和像素量（先做，不改指令）

SwiftShader 默认线程数是 `min(逻辑核数, 16)`（`SwiftConfig.hpp` / `SwiftShader.ini` 的 `[Processor] ThreadCount`，0 表示用默认）。容器若能看见整机 64 核，每个 redroid 都可能起 16 条渲染线程。一百个容器就是灾难。

建议：

1. 用 cpuset / CPU quota **限制每个容器能看见的核**（常见 2～4，按套餐定）。
2. 在工作目录放 `SwiftShader.ini`（SwiftShader 启动时读，区分大小写）：

```ini
[Processor]
ThreadCount=2
AffinityPolicy=one
```

`ThreadCount` 对齐该容器的核；`AffinityPolicy=one` 表示一条工作线程尽量钉在一个核上，减少来回跳核。`AffinityMask` 需要时再收紧。

3. 经验公式：  
   **实例数 × ThreadCount ≈ 物理核数**，并给 `system_server`、SurfaceFlinger、网络留余量。超卖时，ISA 优化会被调度噪声淹没。

4. **分辨率 / DPI / 目标 FPS**  
   - 像素量和 CPU 近似线性。720p 相对默认约 1280 宽、相对 1080p，面积小很多。  
   - `androidboot.redroid_fps`：无 GPU 默认约 15。能接受 15/20 就不要锁 30/60。  
   - DPI 过高会让系统按「更密的屏」画更多资源。

5. **关掉 MSAA 和用不到的特效**  
   ARM 上 resolve 没有 SSE2 那种快路径。

6. **确认驱动**  
   `ro.hardware.vulkan=pastel`，GLES 走 ANGLE。JIT 用 LLVM。

7. **JIT 预热**  
   冷启动会为每种管线状态编译。套餐固定时，先跑一遍目标 APK 再对外；或接受前几秒掉帧。缓存不跨容器持久化。

这一阶段常常就能从「卡成幻灯片」变成「能用」。先做 A/B：默认分辨率 vs 720p，默认线程 vs `ThreadCount=2`。

### 6.3 第二阶段：ARM 指令快路径（改 SwiftShader）

在线程和分辨率合理之后，对 **你们 fork 的 SwiftShader** 做与 x86 对等的「打开开关」，而不是重写光栅器。

| 优先级 | 改什么 | 术语对应 | 为什么对云手机有用 |
|--------|--------|----------|-------------------|
| 高 | `Caps::fmaIsFast()` 在 ARMv8 为 true | FMA / FMLA | UI 和着色器里大量 `a*b+c`，改动小 |
| 高 | `HasRcpApprox()` 走 `frecpe` / `frsqrte` | rcp / rsqrt | 采样、LOD、列表滑动、inversesqrt |
| 中 | 饱和、pack、min/max、符号掩码的 NEON | paddusb / pack / pmaxsd | Skia/HWUI 的混合与 UNORM |
| 中 | Blitter / resolve 的 NEON | `_mm_avg_epu8` 的对标 | 合成、缩放、关不掉的 MSAA |
| 低 | SVE、Width=8 | 可变长向量 | 要改 2×2 和 subgroup，不适合当第一期 |

实施原则：

- 先对热点 pixel routine **反汇编**。若已经是 `fadd`/`fmul` 的 NEON，就不要再包一层同样的加减。若是标量循环或真除法，再写 intrinsic。
- 对照 `src/Reactor/x86.hpp` 和 `LLVMReactor.cpp` 里 `#if x86` 的 `else` 分支，那就是 ARM 清单。
- 用 **同一套 redroid 镜像、同一 APK、同一分辨率** 做 A/B，看 FPS、CPU%、P99 帧时间，不要只看微基准。

预期要诚实：在 LLVM 已经吐出 4 宽 NEON 的前提下，FMA + 近似倒数常见是 **几个点到一成多**，采样特别重时更高。分辨率减半或每实例少抢一半核，往往是 **几十个百分点**。指令优化是「把每核填充率再往上顶」，不是「替代容量规划」。

### 6.4 第三阶段（明确不做，除非第一、二阶段已经顶满）

- 给 Subzero 补 ARM64：你的规模路径应用 LLVM。
- 整份镜像 `x86.hpp` 的 `rr::arm`：维护成本高，很多加减乘已经是 NEON。
- SVE / 可伸缩向量 / 8 宽管线：等于第二套光栅器。只有 profile 证明 4 宽已经把流水线吃满、内存带宽还剩时才值得立项。

---

## 7. 建议的落地顺序（给项目经理和开发）

**第 0 步：量**  
每容器 `top`/`perf`：SwiftShader/ANGLE 线程数是否≈16；宿主机是否 N×16。对卡顿界面抓一帧，看时间是在应用、Skia、ANGLE 还是 SwiftShader。

**第 1 步：配额 + ini + 分辨率 + FPS**  
目标：单机实例数上去之后，单容器 FPS 不塌。

**第 2 步：确认 ANGLE + pastel + LLVM**  
避免错误地换驱动。

**第 3 步：fork 上改 FMA 探测和 ARM 近似倒数**  
这是和 x86 历史工作对齐、且适合你们场景的最小代码集。

**第 4 步：有汇编证据再补 pack/饱和/Blitter**  
对着 Skia/合成热点做，不要按指令集手册刷完成度。

**第 5 步：预热与镜像固化**  
把「打开过一遍的应用」或固定配置写进镜像/启动脚本。

---

## 8. 和其它文档的关系

| 文档 | 给谁看 |
|------|--------|
| [Index.zh.md](Index.zh.md) | SwiftShader 四层架构（API / Renderer / Reactor / JIT） |
| [src-architecture/overview.zh.md](src-architecture/overview.zh.md) | **当前** `src/` 分层和一次绘制走哪 |
| [KunpengHotspotProposal.zh.md](KunpengHotspotProposal.zh.md) | 鲲鹏上从零压热点的立项顺序（先量再改） |
| [Reactor.zh.md](Reactor.zh.md) | **改 SwiftShader 的人** 怎么写 `Float` / `If()`；应用开发者不用读语法章节 |
| [LLVM.zh.md](LLVM.zh.md) / [Subzero.zh.md](Subzero.zh.md) | 两个 JIT 后端；ARM64 用 LLVM |
| [RuntimeConfiguration.zh.md](RuntimeConfiguration.zh.md) | `SwiftShader.ini` 语法 |
| 本文 | 软渲染背景、x86 优化史、ARM/redroid 方案 |

---

## 9. 一句话备忘

x86 的优势来自 **Capens 一带把图形常用的 SSE 指令接到 Reactor 上**，再加 FMA、近似倒数和 Blitter。ARM64 已经能靠 LLVM 吃到 NEON，但 FMA 探测和近似倒数被写成了「只认 x86」。

在 ARM 服务器上大规模跑 redroid、没有 GPU 时：软渲染就是产能。先把 **每容器的核数、线程、分辨率、目标帧率** 做对，再打开 **FMLA 和 frecpe/frsqrte**，按需补饱和与 Blitter。这样既对得上历史优化的动机，也符合「不懂渲染的人也能判断：我们是在少画一些点，还是在让每个点算得更快」。
