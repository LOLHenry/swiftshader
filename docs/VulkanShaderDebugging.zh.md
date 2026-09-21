# Vulkan 着色器调试

[English](VulkanShaderDebugging.md) | 中文

SwiftShader 实现了一个使用 [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol) 的 Vulkan 着色器调试器。

该调试器仍在积极开发中。请参见[已知问题](#已知问题)。

# 启用

要启用调试器功能，需要使用 CMake 的 `SWIFTSHADER_ENABLE_VULKAN_DEBUGGER` 标志构建 SwiftShader（`-DSWIFTSHADER_ENABLE_VULKAN_DEBUGGER=1`）：

SwiftShader 带调试器功能构建完成后，有两个环境变量控制运行时行为：

* `VK_DEBUGGER_PORT` - 设为一个未使用的端口号，用于创建 DAP localhost 套接字。若未设置该环境变量，则不会启用调试器功能。
* `VK_WAIT_FOR_DEBUGGER` - 若已定义，调试器会在 `vkCreateDevice()` 上阻塞，直到建立调试器连接后才允许 `vkCreateDevice()` 返回。这样可以在继续执行之前设置断点。

# 使用 Visual Studio Code 连接

在启用调试器功能构建 SwiftShader，并设置 `VK_DEBUGGER_PORT` 环境变量后，可以使用如下 Visual Studio Code `"debugServer"` [启动配置](https://code.visualstudio.com/docs/editor/debugging#_launch-configurations)连接到调试器：

```json
    {
        "name": "Vulkan Shader Debugger",
        "type": "node",
        "request": "launch",
        "debugServer": 19020,
    }
```

注意 `"type": "node"` 字段并未使用，但是必需的。

[TODO](https://issuetracker.google.com/issues/148373102)：创建一个 Visual Studio Code 扩展，提供预构建的 SwiftShader 驱动和调试器类型。

# 着色器入口断点

可以使用以下函数断点名称，在对应类型的所有着色器入口处设置断点：
* `"VertexShader"`
* `"FragmentShader"`
* `"ComputeShader"`

# 高级着色器调试

默认情况下，调试器会自动反汇编 SPIR-V 着色器代码，并将其作为着色器程序的源码。

不过，如果着色器程序包含 [`OpenCL.DebugInfo.100`](https://www.khronos.org/registry/spir-v/specs/unified1/OpenCL.DebugInfo.100.mobile.html) 调试信息指令，调试器将允许你调试高级着色器源码（请参见[已知问题](#已知问题)）。


# 已知问题

* 当前启用调试器会显著影响所有着色器调用的性能。我们可能希望即时重编译正在被调试的着色器，以使未调试着色器的调用保持高性能。[跟踪缺陷](https://issuetracker.google.com/issues/148372410)
* 对 [`OpenCL.DebugInfo.100`](https://www.khronos.org/registry/spir-v/specs/unified1/OpenCL.DebugInfo.100.mobile.html) 的支持仍处于早期但活跃的开发阶段。许多功能仍不完整。
* 着色器子组调用当前呈现为单一线程，每个调用在监视窗口中显示为 `Lane N` 组。该方法仍在评估中，可能会改写。
