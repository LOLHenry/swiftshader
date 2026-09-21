# Regres - SwiftShader 自动化测试

[English](Regres.md) | 中文

## 简介

Regres 是一组工具，用于对 SwiftShader 进行 [dEQP](https://github.com/KhronosGroup/VK-GL-CTS) 预提交测试、持续集成测试以及代码覆盖率评估。

Regres 提供：

* [预提交测试](#预提交测试) - 对每个提交到 Gerrit 供审查的 patchset 自动运行 Vulkan dEQP 测试。
* [持续集成测试](#每日运行持续集成测试) -
  每晚针对 `master` 分支执行一次 Vulkan dEQP 测试。\
  这次夜间运行还会生成代码覆盖率信息，可在
  [swiftshader-regres.github.io/swiftshader-coverage](https://swiftshader-regres.github.io/swiftshader-coverage/) 查看。
* [本地 dEQP 测试运行器](#本地-deqp-测试运行器) 提供本地工具，可基于通配符或正则表达式名称匹配高效运行若干 dEQP 测试。

Regres 源码根目录位于 [`<swiftshader>/tests/regres/`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/)。

## 预提交测试

Regres 会监视已[提交到 Gerrit 供审查](https://swiftshader-review.googlesource.com/q/status:open)的变更。

一旦发现新的[符合条件](#符合条件)的 patchset，regres 会检出、构建该变更，并对照其父 changelist 进行测试。\
结果差异会作为审查评论发布在该变更上
[[示例]](https://swiftshader-review.googlesource.com/c/SwiftShader/+/46369/5#message-4f09ea3e6d01ed94ae26183c8b6c547c90492c12)。

### 符合条件

由于 Regres 可能在 Google 硬件上运行外部作者的代码，
Regres 仅会测试由 Googler 撰写或审查的变更。

只会测试某个变更的最新 patchset。如果在前一个 patchset 正在测试时推送了新的 patchset，则会继续把当前测试跑完并把前一个 patchset 的结果发布出去，同时将新的 patchset 加入测试队列。

### 优先级

撰写本文时，一次 Regres 预提交运行大约需要 20 多分钟完成，并且只有一台 Regres 机器为所有变更服务。
为保持 Regres 响应及时，变更会根据其“可合入就绪程度”确定优先级，该就绪程度由变更的 `Kokoro-Presubmit`、`Code-Review` 和 `Presubmit-Ready` Gerrit 标签决定。

### 测试过滤

默认情况下，Regres 会运行 [`<swiftshader>/tests/regres/ci-tests.json`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/ci-tests.json) 文件中声明的全部测试列表。\
随着新功能的实现，`ci-tests.json` 中的测试列表可能会引用由[每日运行](#每日运行持续集成测试)更新的已知通过测试列表，以便跳过不完整功能的失败测试，但会测试新功能中已经通过的测试，以确保它们不会回退。

[`<swiftshader>/tests/regres/full-tests.json`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/full-tests.json)
所引用文件中的额外测试名称，可以通过在变更描述中加入如下签名行，显式包含到该变更的预提交运行中：

```text
Test: <dEQP-test-pattern>
```

`<dEQP-test-pattern>` 可以是单个 dEQP 测试名，也可以使用通配符，[说明见此](https://golang.org/pkg/path/filepath/#Match)。

你可以按需要多次重复 `Test:`。`Tests:` 也可以接受。

[例如](https://swiftshader-review.googlesource.com/c/SwiftShader/+/26574)：

```text
Add support for OpLogicalEqual, OpLogicalNotEqual

Test: dEQP-VK.glsl.operator.bool_compare.*
Test: dEQP-VK.glsl.operator.binary_operator.equal.*
Test: dEQP-VK.glsl.operator.binary_operator.not_equal.*
Bug: b/126870789
Change-Id: I9d33444d67792274d8027b7d1632235533cfc079
```

## 每日运行持续集成测试

每天一次，regres 还会从 [`<swiftshader>/tests/regres/full-tests.json`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/full-tests.json) 运行另一组测试，
并将测试结果列表作为 Gerrit changelist 提交
[[示例]](https://swiftshader-review.googlesource.com/c/SwiftShader/+/46448)。

每日运行还会按每个 dEQP 测试进行代码覆盖率插桩，
自动将所有 dEQP 测试的结果上传到查看器
[swiftshader-regres.github.io/swiftshader-coverage](https://swiftshader-regres.github.io/swiftshader-coverage/)。

## 本地 dEQP 测试运行器

Regres 还提供一个多线程、[进程沙箱化](#进程沙箱化)的本地 dEQP 测试运行器，支持基于通配符 / 正则表达式的测试名匹配。

可以用以下方式运行本地测试运行器：

[`<swiftshader>/tests/regres/run_testlist.sh`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/run_testlist.sh) `--deqp-vk=<path to deqp-vk> [--filter=<test name filter>]`

`<test name filter>` 可以是单个 dEQP 测试名，也可以使用通配符，[说明见此](https://golang.org/pkg/path/filepath/#Match)。
或者以 `/` 开头以使用正则表达式过滤。

其他有用的标志：

```text
  -limit int
        only run a maximum of this number of tests
  -no-results
        disable generation of results.json file
  -output string
        path to an output JSON results file (default "results.json")
  -shuffle
        shuffle tests
  -test-list string
        path to a test list file (default "vk-master-PASS.txt")
```

使用 `--help` 运行 [`<swiftshader>/tests/regres/run_testlist.sh`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/run_testlist.sh) 可查看全部可用标志。

## 进程沙箱化

Regres 会在单独进程中运行每个 dEQP 测试，以防止测试之间发生状态泄漏。

测试会并发运行，崩溃的进程不会拖垮测试运行器。

已知某些 dEQP 测试会进行过量内存分配（即不断分配，直到无法再从操作系统申请）。\
为防止单个测试耗尽其他测试进程的内存，每个进程都会通过 [Linux 资源限制](https://man7.org/linux/man-pages/man2/getrlimit.2.html) 被限制为系统内存的一部分。

测试也可能死锁，因此每个测试进程都有时间限制，超时后会被自动杀死。

## 实现细节

### 预提交与每日运行流程

Regres 会一直运行直到被停止，并会：

* 将已知兼容版本的 Clang 下载到缓存目录。下面所有编译阶段都会使用它。
* 定期轮询 Gerrit 以获取最近打开的变更
* 定期向 Gerrit 查询每个被跟踪变更的详情，判断[是否应当测试](#符合条件)，并确定其当前[优先级](#优先级)。
* 会选出优先级最高且符合条件的变更，并对该变更执行以下操作：
  1. 将该变更 `git fetch` 到临时目录。
  2. 若尚未缓存，则下载并构建该变更 [`<swiftshader>/tests/regres/deqp.json`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/deqp.json) 文件中描述的 dEQP 版本，放入缓存目录。
  3. 将该变更的源码构建到临时构建目录。
  4. 使用构建出的 dEQP 二进制测试该变更。完整测试结果存储在缓存目录中。
  5. 如果父变更的测试结果尚未缓存，则对父变更重复步骤 3 和 4。
  6. 对两个变更的结果做 diff，并将 diff 结果作为 Gerrit 审查评论发布到该变更上。
* 重复上述过程，直到该进行每日运行，届时会：
  1. 将 `master` 的 `HEAD` 变更 fetch 到临时目录。
  2. 若尚未缓存，则下载并构建该变更 [`<swiftshader>/tests/regres/deqp.json`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/deqp.json) 文件中描述的 dEQP 版本，放入缓存目录。
  3. 将 `HEAD` 变更构建到临时目录，可选地带上代码覆盖率插桩。
  4. 使用构建出的 dEQP 二进制测试该变更。完整测试结果存储在缓存目录中，每个测试会按状态分桶，并写入 [`<swiftshader>/tests/regres/testlists`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/testlists) 目录。
  5. 创建一个包含更新后测试列表的新 Gerrit 变更并提交审查，同时附上测试结果变化摘要 [[示例]](https://swiftshader-review.googlesource.com/c/SwiftShader/+/46448)。
     如果已有每日测试变更在审查中，则复用该变更，而不是再创建一个。
  6. 如果构建包含代码覆盖率插桩，则从所有测试运行中汇总覆盖率结果，进行处理和压缩，并上传到 [github.com/swiftshader-regres/swiftshader-coverage](https://github.com/swiftshader-regres/swiftshader-coverage)，
     随即反映在 [swiftshader-regres.github.io/swiftshader-coverage](https://swiftshader-regres.github.io/swiftshader-coverage)。
     该过程[在下文有更详细描述](#代码覆盖率)。
  7. 对 LLVM 和 Subzero 后端重复阶段 3 - 5。

### 缓存

会大量使用缓存目录以避免重复工作。例如，常见情况是多次推送的 patchset 具有相同的父变更，因此父变更的测试结果可以计算一次并存储。已测试并合入 master 的 patchset 在作为另一个变更的父变更时也会被缓存。

缓存需要考虑的远不止变更标识符作为存储和检索数据的 cache-key。所用测试列表和 dEQP 版本都由被测试的变更决定，因此二者都会作为缓存键的一部分。

### Vulkan Loader 的使用

应用程序通过加载 [Vulkan Loader](https://github.com/KhronosGroup/Vulkan-Loader) 库（Linux 上为 `libvulkan.so.1`）来使用 Vulkan API。该库会枚举可用的 Vulkan 实现（通常是 GPU 及其驱动），然后再创建实际的 “instance” 以与特定的可安装客户端驱动（ICD）通信。

不过，SwiftShader 本身可以构建成 `libvulkan.so.1`，它实现与 Vulkan Loader 相同的 API 入口函数。Regres 默认会让 dEQP 加载这个 SwiftShader 库，而不是系统的 Vulkan Loader。这确保测试结果独立于系统的 Vulkan 设置。

要覆盖此行为，可以将 LD_LIBRARY_PATH 设为指向 Loader 的 libvulkan.so.1 所在位置。

### 代码覆盖率

[每日运行](#每日运行持续集成测试)会生成代码覆盖率信息，可以按每个 dEQP 测试在
[swiftshader-regres.github.io/swiftshader-coverage](https://swiftshader-regres.github.io/swiftshader-coverage/) 查看。

生成该信息的过程比较复杂，下面详细说明：

#### 按测试生成

代码覆盖率插桩使用 [clang 的 `--coverage`](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html) 功能生成。该编译器选项通过 SwiftShader 的 `SWIFTSHADER_EMIT_COVERAGE` CMake 标志启用。

每个 dEQP 测试进程都会以唯一的 `LLVM_PROFILE_FILE` 环境变量值运行，该值决定进程将原始覆盖率 profile 文件写到何处。每个进程使用不同路径，以便我们可以从多个并发的 dEQP 测试进程中发出覆盖率。

#### 解析

[Clang 提供两个工具](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html#creating-coverage-reports) 用于处理覆盖率数据：

* `llvm-profdata` 为原始 `.profraw` 覆盖率 profile 文件建立索引，并发出 `.profdata` 文件。
* `llvm-cov` 进一步把 `.profdata` 文件处理成人类可读或机器可解析的形式。

`llvm-cov` 提供许多选项，包括发出精美的 HTML 文件，但在生成易于机器解析的数据时出奇地慢。幸运的是，`llvm-cov` 的核心[只有几百行代码](https://github.com/llvm/llvm-project/tree/master/llvm/tools/llvm-cov)，因为它依赖 LLVM 库完成繁重工作。Regres 用 ["`turbo-cov`"](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/cov/turbo-cov/) 替换 `llvm-cov`，它能高效地把 `.profdata` 转换成可由 Regres 消费的简单二进制流。

#### 处理

撰写本文时，共有超过 560,000 个独立 dEQP 测试，以及 [`<swiftshader>/src`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:src/) 中大约 176,000 行 C++ 代码。
如果每个源码行用 1 位，那么所有 dEQP 测试的逐行源码覆盖率将需要超过 11GiB 存储。这还只是一个快照。

下文描述的处理和压缩方案将其降到大约 10 MiB（约 1100 倍的体积缩减），并支持行内覆盖率作用域。

##### 跨度（Spans）

代码覆盖率信息用跨度来描述。

跨度描述为源码位置区间，位置是行-列对：

```go
type Location struct {
    Line, Column int
}

type Span struct {
    Start, End Location
}
```

##### 测试树构建

每个 dEQP 测试都由完全限定名称唯一标识。
每个测试属于一个组，该组可以嵌套在任意数量的父组中。组在测试名中描述，用点（`.`）分隔各组以及叶子测试名。

例如，完全限定测试名：

`dEQP-VK.fragment_shader_interlock.basic.discard.ssbo.sample_unordered.4xaa.sample_shading.16x16`

可以分解为以下组和测试名：

```text
dEQP-VK                       <-- root group name
╰ fragment_shader_interlock
  ╰ basic.discard
    ╰ ssbo
      ╰ sample_unordered
        ╰ 4xaa
          ╰ sample_shading
            ╰ 16x16           <-- leaf test name
```

把完全限定测试名分解成组，为组织覆盖率数据提供了自然方式，因为同一组中的测试很可能具有相似的覆盖跨度。

因此，对于代码库中的每个源文件，我们创建一棵树，以测试组作为非叶节点，测试作为叶节点。

例如，给定以下测试列表：

```text
a.b.d.h
a.b.d.i.n
a.b.d.i.o
a.b.e.j
a.b.e.k.p
a.b.e.k.q
a.c.f
a.c.g.l.r
a.c.g.m
```

我们会构造如下树：

```text
               a
        ╭──────┴──────╮
        b             c
    ╭───┴───╮     ╭───┴───╮
    d       e     f       g
  ╭─┴─╮   ╭─┴─╮         ╭─┴─╮
  h   i   j   k         l   m
     ╭┴╮     ╭┴╮        │
     n o     p q        r

```

该树中的每个叶节点（`h`、`n`、`o`、`j`、`p`、`q`、`f`、`r`、`m`）
代表一个测试，非叶节点（`a`、`b`、`c`、`d`、`e`、`g`、`i`、`k`、
`l`）是组。

开始时，我们创建测试树结构，并把完整的测试覆盖跨度列表关联到该树中的每个叶节点（测试）。

这个数据结构目前还没有带来压缩收益，但接下来可以做一些技巧，大幅减少描述该图所需的跨度数量：

##### 优化 1：公共跨度提升

第一种压缩方案是：当某个跨度对所有子节点都公共时，把它提升到树的上层。这会减少最终文件中需要编码的跨度数量。

例如，如果测试组 `a` 有 4 个子节点都共享同一跨度 `X`：

```text
          a
    ╭───┬─┴─┬───╮
    b   c   d   e
 [X,Y] [X] [X] [X,Z]
```

则跨度 `X` 可以提升到 `a`：

```text
         [X]
          a
    ╭───┬─┴─┬───╮
    b   c   d   e
   [Y] []   [] [Z]
```

##### 优化 2：跨度 XOR 提升

这个想法可以进一步扩展：不必要求所有子节点都共享同一跨度才提升。如果**大多数**子节点共享同一跨度，我们仍然可以提升该跨度，但这次会：子节点**如果已有**该跨度则**移除**它，**如果没有**则**添加**它。

例如，如果测试组 `a` 有 4 个子节点，其中 3 个共享跨度 `X`：

```text
          a
    ╭───┬─┴─┬───╮
    b   c   d   e
 [X,Y] [X]  [] [X,Z]
```

则可以通过翻转子节点上 `X` 的有无，把跨度 `X` 提升到 `a`：

```text
         [X]
          a
    ╭───┬─┴─┬───╮
    b   c   d   e
   [Y] []  [X] [Z]
```

该过程会沿树向上重复。

应用此优化后，我们需要从根遍历到叶，才能知道某个跨度是否被叶节点（测试）使用：

* 如果遍历过程中该跨度出现**奇数**次，则该跨度**被覆盖**。
* 如果遍历过程中该跨度出现**偶数**次，则该跨度**未被覆盖**。

更多该优化的例子见 [`tests/regres/cov/coverage_test.go`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/cov/coverage_test.go)。

##### 优化 3：公共跨度分组

在真实数据中，我们会遇到经常一起出现的跨度组。为进一步减少覆盖率数据，会扫描整张图以寻找常见跨度模式，并由每个树节点建立索引。
上文所述的跨度 XOR 仍按跨度未分组时的方式执行。

##### 优化 4：查找表

所有跨度、跨度组和字符串都存储在去重表中，并尽可能通过索引引用。

最终序列化由 [`tests/regres/cov/serialization.go`](https://cs.opensource.google/swiftshader/SwiftShader/+/master:tests/regres/cov/serialization.go) 执行。

##### 优化 5：zlib 压缩

覆盖率数据编码为 JSON，供网页解析。

写入 JSON 文件之前，文本数据会进行 zlib 压缩。

#### 展示

zlib 压缩的 JSON 覆盖率数据使用 [`pako`](https://github.com/nodeca/pako) 解压，并由一些
[原生 JavaScript](https://github.com/swiftshader-regres/swiftshader-coverage/blob/gh-pages/index.html) 消费。

[`codemirror`](https://codemirror.net/) 用于执行覆盖率跨度和 C++ 语法高亮。
