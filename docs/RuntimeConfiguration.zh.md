运行时配置
==========

[English](RuntimeConfiguration.md) | 中文

SwiftShader 提供基于配置文件的简单配置机制，无需从源码重新编译即可控制多种运行时选项。

配置文件
--------

SwiftShader 会在工作目录中查找名为 `SwiftShader.ini` 的文件（区分大小写）。启动时，如果该文件存在，SwiftShader 会读取它并设置其中指定的选项。

配置文件语法是一系列按节划分的键值对。下面的例子在两个节中给出了三组键值对（`[Processor]` 节中的 `ThreadCount` 和 `AffinityMask`，以及 `[Profiler]` 节中的 `EnableSpirvProfiling`）：
```
[Processor]
ThreadCount=4
AffinityMask=0xf

# Comment
[Profiler]
EnableSpirvProfiling=true
```

语法规则如下：
* 节通过方括号中的名称定义，例如 `[Processor]`。
* 键值对的格式为 `Key=Value`。
* 键始终是字符串，而值可以是字符串、布尔值或整数，取决于该选项的语义：
  * 对于整数选项，同时支持十进制和十六进制值。
  * 对于布尔选项，同时支持十进制（`1` 和 `0`）以及字母形式（`true` 和 `false`）。
* 支持注释：在行首使用 `#` 字符。

选项
----

请参阅 [SwiftConfig.hpp](../src/System/SwiftConfig.hpp) 头文件，以获取可用选项的最新概览。
