> :warning: **内容可能过时**

SwiftShader 文档
================

[English](Index.md) | 中文

SwiftShader 在 CPU 上提供高性能图形渲染，从而摆脱对图形硬件能力的依赖。

架构
----

SwiftShader 提供实现标准化图形 API 的共享库（DLL）。已经使用这些 API 的应用程序因此无需任何修改即可使用 SwiftShader。它可以完全在用户空间中运行，也可以作为驱动程序运行（适用于 Android），并将结果输出到帧缓冲、窗口或离屏缓冲。

为了获得出色的性能，SwiftShader 的架构围绕两项主要优化构建：动态代码生成和并行处理。在运行时生成代码可以消除代码分支并优化寄存器使用，使处理例程专门针对每次绘制调用所需的操作。并行处理既包括利用 CPU 的多个核心，也包括利用 SIMD 向量单元的宽度同时处理多个元素。

结构上分为四个主要层次：

![API、Renderer、Reactor、JIT](/docs/ArchitectureLayers.png "架构层次")

API 层是在 Renderer 接口之上对图形 API（例如 OpenGL (ES) 或 Direct3D）的实现。它负责管理 API 级资源和渲染状态，以及将高级着色器编译为字节码形式。

Renderer 层为绘制调用生成专用处理例程，并协调渲染任务的执行。它定义所用的数据结构以及处理的执行方式。

Reactor 是嵌入 C++ 中的一种语言，用于以所见即所得（WYSIWYG）的方式动态生成代码。它可以根据每次绘制调用所用的状态和着色器来特化处理例程。其语法与 C 及着色语言非常接近，使代码生成过程易于阅读。

JIT 层是运行时编译器，例如 [LLVM](LLVM.zh.md) 的 JIT，或 [Subzero](Subzero.zh.md)。Reactor 将其操作记录为内存中的中间表示，随后由 JIT 物化为可直接调用的函数。

设计
----

### Reactor

若要用 LLVM 直接为 `float y = 1 - x;` 这样的表达式生成代码，需要写出类似 `Value *valueY = BinaryOperator::CreateSub(ConstantInt::get(Type::getInt32Ty(Context), 1), valueX, "y", basicBlock);` 的代码。这种方式非常冗长，表达式稍长就会难以阅读。借助 C++ 运算符重载，[Reactor](../src/Reactor/) 将其简化为 `Float y = 1 - x;`。注意，Reactor 类型的名称与 C 类型相同，但以大写字母开头。同样，`If()`、`Else` 和 `For(,,)` 实现了与 C 对应的控制流结构。

虽然让 Reactor 的语法与它所处的 C++ 如此相似，一开始可能会造成一些混淆，但这为代码特化提供了强大的抽象。例如，要生成加法或减法的代码，可以写成 `x = addOrSub ? x + y : x - y;`。注意，最终生成的代码中只会留下其中一种运算。

我们将由 Reactor 代码生成的函数称为 [Routine](../src/Reactor/Routine.hpp)。

关于 Reactor 的更多细节，请参见 [Reactor.zh.md](Reactor.zh.md)。

### Renderer

[Renderer](../src/Renderer/) 层主要由三部分实现：[VertexProcessor](../src/Renderer/VertexProcessor.cpp)、[SetupProcessor](../src/Renderer/SetupProcessor.cpp) 和 [PixelProcessor](../src/Renderer/PixelProcessor.cpp)。每个“处理器”都会生成对应的 Reactor 例程，并管理相关的图形状态。它们还会缓存已经生成的例程，因此当再次遇到相同的状态组合时，会复用执行所需处理的例程。

[VertexRoutine](../src/Shader/VertexRoutine.cpp) 生成用于处理一批顶点的函数。固定功能的变换与光照（T&L）管线由 [VertexPipeline](../src/Shader/VertexPipeline.cpp) 实现，而带着色器的可编程顶点处理由 [VertexProgram](../src/Shader/VertexProgram.cpp) 实现。注意，顶点例程还会在同一个函数中完成顶点属性读取、顶点缓存、视口变换以及裁剪标志计算。

[SetupRoutine](../src/Shader/SetupRoutine.cpp) 执行图元装配。这包括背面剔除、计算梯度和光栅化。

[PixelRoutine](../src/Shader/PixelRoutine.cpp) 接收一批图元并执行逐像素操作。固定功能的纹理阶段和旧式整数着色器由 [PixelPipeline](../src/Shader/PixelPipeline.cpp) 实现，而带着色器的可编程像素处理由 [PixelProgram](../src/Shader/PixelProgram.cpp) 实现。深度测试、Alpha 测试、模板测试和 Alpha 混合等其他逐像素操作也在像素例程中完成。它与 [QuadRasterizer](../src/Renderer/QuadRasterizer.cpp) 中的像素遍历一起构成一个函数。

PixelProgram 和 VertexProgram 在 [ShaderCore](../src/Shader/ShaderCore.cpp) 中共享部分通用功能。同样，纹理采样由 [SamplerCore](../src/Shader/SamplerCore.cpp) 实现。

除了借助 Processor 类创建和管理处理例程外，Renderer 还会将渲染任务细分并调度到多个线程上执行。

### OpenGL

OpenGL (ES) 和 EGL API 实现于 [src/OpenGL/](../src/OpenGL/)。

GLSL 编译器实现于 [src/OpenGL/compiler/](../src/OpenGL/compiler/)。它使用 [Flex](http://flex.sourceforge.net/) 和 [Bison](https://www.gnu.org/software/bison/) 对 GLSL 着色器源码进行词法分析和语法分析，生成[抽象语法树](https://en.wikipedia.org/wiki/Abstract_syntax_tree)（AST），再遍历该树，在 [OutputASM.cpp](../src/OpenGL/compiler/OutputASM.cpp) 中输出汇编级指令。

[EGL](https://www.khronos.org/registry/egl/specs/eglspec.1.4.20110406.pdf) API 实现于 [src/OpenGL/libEGL/](../src/OpenGL/libEGL/)。其入口函数列于 [libEGL.def](../src/OpenGL/libEGL/libEGL.def)（Windows）和 [libEGL.lds](../src/OpenGL/libEGL/libEGL.lds)（Linux），定义于 [main.cpp](../src/OpenGL/libEGL/main.cpp)，实现于 [libEGL.cpp](../src/OpenGL/libEGL/libEGL.cpp)。[Display](../src/OpenGL/libEGL/Display.h)、[Surface](../src/OpenGL/libEGL/Surface.h) 和 [Config](../src/OpenGL/libEGL/Config.h) 类分别实现抽象的 EGLDisplay、EGLSurface 和 EGLConfig 类型。

[OpenGL ES 2.0](https://www.khronos.org/registry/gles/specs/2.0/es_full_spec_2.0.25.pdf) 实现于 [src/OpenGL/libGLESv2/](../src/OpenGL/libGLESv2/)。需要注意的是，虽然 [OpenGL ES 3.0](https://www.khronos.org/registry/gles/specs/3.0/es_spec_3.0.0.pdf) 函数实现于 [libGLESv3.cpp](../src/OpenGL/libGLESv2/libGLESv3.cpp)，但它们会被编译进 libGLESv2 库，这与大多数实现的惯例一致（部分平台上 libGLESv3 会符号链接到 libGLESv2）。本文档将重点介绍 OpenGL ES 2.0。

当应用程序调用 OpenGL 函数时，会进入 [main.cpp](../src/OpenGL/libGLESv2/main.cpp) 中的 C 入口函数，随后分发到 [libGLESv2.cpp](../src/OpenGL/libGLESv2/libGLESv2.cpp) 中 `es2` 命名空间下的函数。这些函数获取当前线程的 OpenGL 上下文，并对调用参数进行校验。大多数函数随后会调用对应的 [Context](../src/OpenGL/libGLESv2/Context.h) 方法来执行该调用的主要操作（修改状态或将绘制任务入队）。

其他文档
--------

面向非图形专业读者的软渲染说明（x86 优化背景、ARM / redroid 方案、术语表）见 [SoftwareRenderingOptimization.zh.md](SoftwareRenderingOptimization.zh.md)。
