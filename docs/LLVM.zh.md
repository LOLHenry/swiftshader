LLVM 依赖
=========

[English](LLVM.md) | 中文

概述
----

SwiftShader 的 [Reactor](Reactor.zh.md) 库将 LLVM 用作其 JIT 编译器后端之一。本页包含关于构建和升级 LLVM 的说明。

目录结构
--------

当前使用的 LLVM 版本是 10，位于 `third_party/llvm-10.0`。

在该文件夹中可以看到以下目录：

*   configs：包含 LLVM 源码为配置构建而包含的按平台划分的头文件。这些文件通过运行 `scripts/update.py` 生成（下文有更多说明）。
*   llvm：包含构建 SwiftShader 所需 JIT 支持而用到的 LLVM 源码子集。
*   scripts：包含 `update.py`，用于更新 `configs` 文件夹中的文件。下文有更多说明。

将当前 LLVM 版本更新到最新
--------------------------

手动更新到最新版 LLVM 可能很棘手，尤其是因为 [llvm-project 仓库](https://github.com/llvm/llvm-project) 包含的远不止 LLVM（例如还包括全部 Clang 源码）。此外，我们对 LLVM 副本可能有本地修改，必须在更新过程中保留，或至少加以考虑。

为减轻这一负担，请在 Linux 上运行脚本 `third_party/update-llvm-10.sh`。该脚本会更新 SwiftShader 的一个独立分支 `llvm10-clean`：在该分支上获取并提交最新的 LLVM 快照，然后再把该分支合并回 `master`。合并过程中，如果因我们做过的本地修改而产生冲突，可以按通常方式解决，然后继续合并。

脚本配置为从 `LLVM_REPO_BRANCH` 中的分支获取，并会自动抓取该分支上的最新提交。

虽然并非总是必要，但如果新增或修改了配置变量，你可能需要按下述方式运行 `update.py`。否则，若一切顺利，即可提交并推送这次 LLVM 更新。

更新 LLVM 配置文件
------------------

脚本 `third_party/llvm-10.0/scripts/update.py` 用于更新 `third_party/llvm-10.0/configs` 中的配置文件。

运行该脚本前，必须先更新其中的两个变量（并提交此更改）：

```
# LLVM_BRANCH must match the value of the same variable in third_party/update-llvm-10.sh
LLVM_BRANCH = "release/10.x"

# LLVM_COMMIT must be set to the commit hash that we last updated to when running third_party/update-llvm-10.sh.
# Run 'git show -s origin/llvm10-clean' and look for 'llvm-10-update: <hash>' to retrieve it.
LLVM_COMMIT = "d32170dbd5b0d54436537b6b75beaf44324e0c28"
```

该脚本接受一个平台参数以及额外的 CMake 参数。例如，要更新 Linux 配置，运行：

```
python3 update.py linux -j 200
```

该脚本会执行以下操作：

*   克隆 LLVM 仓库，并从 `LLVM_BRANCH` 检出 `LLVM_COMMIT`。
*   专门针对 `LLVM_TRIPLES` 字典中指定的目标架构构建 LLVM。
*   将指定平台的配置文件复制到 `third_party/llvm-10.0/configs`，并对文件应用某些转换，例如取消定义 `LLVM_UNDEF_MACROS` 中列出的宏（参见 `copy_platform_file` 函数）。

注意，某些配置选项取决于主机操作系统，你需要在正确的主机操作系统上运行该脚本。参见 `LLVM_PLATFORM_TO_HOST_SYSTEM` 字典中的映射，撰写本文时如下：

```
# Mapping of target platform to the host it must be built on
LLVM_PLATFORM_TO_HOST_SYSTEM = {
    'android': 'Linux',
    'darwin': 'Darwin',
    'linux': 'Linux',
    'windows': 'Windows',
    'fuchsia': 'Linux'
}
```

一般而言，在 Windows 上构建 Windows，在 Darwin 上构建 Darwin（macOS），其余都在 Linux 上构建。另请注意，对于 Android 和 Fuchsia，配置最接近 Linux，但你很可能需要手动调整配置（尤其是 `configs/<platform>/include/llvm/Config/config.h`）。

支持的平台、架构和构建系统
--------------------------

SwiftShader 被许多产品用于多种架构：

*   操作系统：Windows、Linux、macOS、Android、Fuchsia
*   架构：x64、x86、ARM、ARM64、MIPS、MIPS64
*   构建系统：CMake、GN、Soong、Blaze

升级/更新 LLVM 通常意味着要确保它能在上述全部组合上构建。
