# Vulkan 时间线信号量

[English](TimelineSemaphores.md) | 中文

[Vulkan 时间线信号量](https://www.khronos.org/blog/vulkan-timeline-semaphores) 是一种设备端和主机端都可以访问的同步原语。时间线信号量表示一个单调递增的 64 位无符号值。二进制 Vulkan 信号量只需等待其变为已发出信号（signaled）状态；时间线信号量则要等待其达到某个特定值。一旦时间线信号量达到某个值，所有小于或等于该值的取值都被视为已发出信号。[`vkWaitSemaphores`](https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/vkWaitSemaphores.html) 用于在主机上等待信号量。它可以按两种模式工作：“等待全部”（wait for all）和“等待任一”（wait for any）。

在 SwiftShader 中，Vulkan 时间线信号量实现为一个受互斥锁保护的 64 位无符号整数，其变化通过条件变量发出通知。等待一组时间线信号量中的全部，实现为依次等待其中的每一个。等待其中的任意一个则更复杂一些。

## 等待任一信号量

对一组信号量的“等待任一”由 `TimelineSemaphore::WaitForAny` 对象表示。此外，`TimelineSemaphore` 内部保存一份等待它的所有 `WaitForAny` 对象的列表，以及它们各自等待的值。当被发出信号时，时间线信号量会遍历该列表，并依次通知那些正在等待小于或等于其新值的 `WaitForAny` 对象。

`WaitForAny` 对象由 `VkSemaphoreWaitInfo` 创建。构造过程中，它会把每个提供的时间线信号量的当前值与所等待的值进行比较。如果目标值尚未达到，等待对象会向该时间线信号量注册自己。如果**已经**达到，等待对象会立即被发出信号，并且不再检查其余时间线信号量。

`WaitForAny` 对象一旦被发出信号，就会一直保持该状态。构造之后无法再更改要等待的信号量或值。之后对 `wait()` 的任何调用都会立即返回 `VK_SUCCESS`。

销毁 `WaitForAny` 对象时，它会从所等待的每一个 `TimelineSemaphore` 上注销自己。预期并发等待的数量很少，且等待对象寿命很短，因此任何时间线信号量上都不应堆积等待对象。
