# `src/` 代码架构

本目录说明 **当前** SwiftShader 源码树（Vulkan ICD，不是已删除的 OpenGL ES / Direct3D 路径）。`docs/Index.zh.md` 里的 GLES/`Renderer/`/`Shader/` 布局已经过时。

| 文档 | 内容 |
| --- | --- |
| [overview.zh.md](overview.zh.md) | 分层、一次绘制怎么跑、JIT 名字、Android 上屏路径 |
| [src-files.zh.md](src-files.zh.md) | `src/` 下每个源文件：职责 + 关键函数 |

第三方库（`third_party/`、`src/Reactor` 里的 Subzero 后端实现）不展开；产品路径以 LLVM JIT 为准。
