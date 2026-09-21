dEQP
====

[English](dEQP.md) | 中文

这些步骤专门用于在 Windows 上使用 dEQP 测试 SwiftShader 的 Vulkan 实现（Linux 步骤见 Windows 说明之后）。

先决条件
--------

1. 安装最新的 [Python 3](https://www.python.org/downloads/)
2. 安装 [Visual Studio](https://visualstudio.microsoft.com/vs/community/)
3. 安装 [CMake](https://cmake.org/download/)
4. 安装 [Go](https://golang.org/doc/install)
5. 安装 [MinGW-W64](http://mingw-w64.org/doku.php/download)
  * 安装时将 Architecture 选为 “x86_64”
6. 安装 [Git](https://git-scm.com/download/win)
7. 设置环境变量：控制面板 -> 系统和安全 -> 系统 -> 高级系统设置 -> 环境变量
  * 将 `<path to python>` 添加到 PATH 环境变量
  * 将 `<path to MinGW-W64>\bin` 添加到 PATH 环境变量

8. （可选）安装 [TortoiseGit](https://tortoisegit.org/)

获取代码
--------

12. 获取 dEQP（可在 “cmd” 中操作，或使用 TortoiseGit）：

    `git clone https://github.com/KhronosGroup/VK-GL-CTS`

    你可能希望检出某个稳定的 vulkan-cts-* 分支。

13. 获取 dEQP 的依赖。在 dEQP 根目录中打开 “cmd” 并运行：

    `python3 external\fetch_sources.py`

14. 获取 Cherry（可在 “cmd” 中操作，或使用 TortoiseGit）：

    `git clone https://android.googlesource.com/platform/external/cherry`

15. 设置环境变量（参见第 9 点）：

    添加新变量 GOPATH='`<path to cherry>`'

构建代码
--------

16. 使用 CMake GUI 生成 dEQP 的 Visual Studio 文件，或者在 dEQP 根目录中运行：
    ```
    mkdir build
    cd build
    cmake ..
    ```
    注意：不要直接在根目录调用 “cmake .”。这会导致后续步骤失败。如果已经这样做了，只需删除 CMake 创建的文件，并按上述步骤操作。

17. 构建 dEQP：

    在 Visual Studio 中打开 `<path to dEQP>\build\dEQP-Core-default.sln` 并生成解决方案

    注意：选择 “Debug” 构建。

18. 生成测试用例：
    ```
    mkdir <path to cherry>\data
    cd <path to dEQP>
    python3 scripts\build_caselists.py <path to cherry>\data
    ```

    注意：每次更新 dEQP 后，都需要运行 `python3 scripts\build_caselists.py <path to cherry>\data`。

准备服务器
----------

19. 编辑 `<path to cherry>\cherry\data.go`
* 搜索 `../candy-build/deqp-wgl`，并将其替换为 `<path to deqp>/build`
* 就在其上方，向 CommandLine 添加选项：`--deqp-gl-context-type=egl`
* 移除 `--deqp-watchdog=enable`，以免调试时超时。

  注意：如果在第 17 步选择了 Release 构建，请将 BinaryPath 从 “Debug” 改为 “Release”。

测试 Vulkan
-----------

20. 假设你已经构建了 SwiftShader，复制并重命名该文件：

    `<path to SwiftShader>\build\Release_x64\vk_swiftshader.dll` 或\
    `<path to SwiftShader>\build\Debug_x64\vk_swiftshader.dll`

    到：

    `<path to dEQP>\build\external\vulkancts\modules\vulkan\Debug\vulkan-1.dll`

    这会使 dEQP 直接加载 SwiftShader 的 Vulkan 实现，而不经过系统提供的 [loader](https://github.com/KhronosGroup/Vulkan-Loader/blob/master/loader/LoaderAndLayerInterface.md#the-loader) 库或任何层。

     也可以通过将 `SWIFTSHADER_VULKAN_API_LIBRARY_INSTALL_PATH` 环境变量设为希望安装该即插即用 API 库的路径来自动完成此步骤。例如 `<path to dEQP>/build/external/vulkancts/modules/vulkan/Debug/`。

    若要将 SwiftShader 用作[可安装客户端驱动](https://github.com/KhronosGroup/Vulkan-Loader/blob/master/loader/LoaderAndLayerInterface.md#installable-client-drivers)（ICD）：
    * 编辑环境变量：
      * 将 VK_ICD_FILENAMES 定义为 `<path to SwiftShader>\src\Vulkan\vk_swiftshader_icd.json`
    * 如果你使用的 `vk_swiftshader.dll` 位置与 `src\Vulkan\vk_swiftshader_icd.json` 中指定的不同，请修改它，使其指向你想使用的 `vk_swiftshader.dll` 文件。

运行测试
--------

21. 启动测试服务器。进入 `<path to cherry>` 并运行：

    `go run server.go`

22. 打开你常用的浏览器并访问 `localhost:8080`

    Get Started -> Choose Device “localhost” -> Select Tests “dEQP-VK” -> Execute tests!

Mustpass 集合
-------------

dEQP 包含的测试比合格实现对期望通过的测试更多（例如，有些测试被认为过于严格，或假定了某些未定义行为）。[android/cts/master/vk-master.txt](https://android.googlesource.com/platform/external/deqp/+/master/android/cts/master/vk-master.txt) 文本文件可以加载到 Cherry 的 “Test sets” 选项卡中，以便只运行认证 Android 设备期望通过的最新测试。

Linux
-----

Linux 流程与 Windows 类似。不过它不使用 Release 或 Debug 变体，路径使用正斜杠，并且使用共享对象文件而不是 DLL。

1. 安装最新的 [Python 3](https://www.python.org/downloads/)
2. 安装 GCC 和 Make。在终端中运行：

    `sudo apt-get install gcc make`

3. 安装 [CMake](https://cmake.org/download/)
4. 安装 [Go](https://golang.org/doc/install)
5. 安装 Git。在终端中运行：

    `sudo apt-get install git`

6. 下载 [Vulkan SDK](https://vulkan.lunarg.com/) 并将其解压到你喜欢的位置。

获取代码
--------

7. 获取 Swiftshader。在终端中进入你想保存 Swiftshader 的位置，并运行：

    ```
    git clone https://swiftshader.googlesource.com/SwiftShader && (cd SwiftShader && curl -Lo `git rev-parse --git-dir`/hooks/commit-msg https://gerrit-review.googlesource.com/tools/hooks/commit-msg ; chmod +x `git rev-parse --git-dir`/hooks/commit-msg)
    ```

    这也会安装向 SwiftShader 提交代码所需的 commit hook。

8. 获取 dEQP：

   `git clone https://github.com/KhronosGroup/VK-GL-CTS`

9. 获取 dEQP 的依赖。在 dEQP 根目录中运行：

    `python3 external/fetch_sources.py`

10. 获取 Cherry，类似第 8 步：

    `git clone https://android.googlesource.com/platform/external/cherry`

11. 设置环境变量。用你喜欢的编辑器打开 ~/.bashrc，并添加以下行：

    GOPATH='`<path to cherry>`'

构建代码
--------

12. 构建 Swiftshader。在 Swiftshader 根目录中运行：
    ```
    cd build
    cmake ..
    make --jobs=$(nproc)
    ```

13. 设置环境变量。在即将构建 dEQP 的终端中运行以下命令：

    ```
    export LD_LIBRARY_PATH="<Vulkan SDK location>/x86_64/lib:$LD_LIBRARY_PATH"
    export LD_LIBRARY_PATH="<Swiftshader location>/build:$LD_LIBRARY_PATH"
    ```

14. 构建 dEQP。在 dEQP 根目录中运行：
    ```
    mkdir build
    cd build
    cmake ..
    make --jobs=$(nproc)
    ```

    另外：不要直接在根目录调用 “cmake .”。这会导致后续步骤失败。如果已经这样做了，只需删除 CMake 创建的文件，并按上述步骤操作。

15. 生成测试用例：
    ```
    mkdir <path to cherry>/data
    cd <path to dEQP>
    python3 scripts/build_caselists.py <path to cherry>/data
    ```

    注意：每次更新 dEQP 后，都需要运行 `python3 scripts/build_caselists.py <path to cherry>/data`。

准备服务器
----------

16. 编辑 `<path to cherry>/cherry/data.go`
* 搜索 “.exe” 并删除所有出现处。
* 搜索 `../candy-build/deqp-wgl/execserver/Release`，并将其替换为 `<path to deqp>/build/execserver/execserver`
* 就在其上方，向 CommandLine 添加选项：`--deqp-gl-context-type=egl`
* 紧接着在下方，从 BinaryPath 中移除 “Debug/”。
* 再往下一行，将 `../candy-build/deqp-wgl/` 替换为 `<path to deqp>/build/modules/${TestPackageDir}`。
* 移除 `--deqp-watchdog=enable`，以免调试时超时。

测试 Vulkan
-----------

17. 将 SwiftShader 用作[可安装客户端驱动](https://github.com/KhronosGroup/Vulkan-Loader/blob/master/loader/LoaderAndLayerInterface.md#installable-client-drivers)（ICD）。向 `~/.bashrc` 添加以下行：

      `export VK_ICD_FILENAMES="<path to SwiftShader>/build/Linux/vk_swiftshader_icd.json"`

    然后在将要运行测试的终端中执行 `source ~/.bashrc`。


运行测试
--------

18. 启动测试服务器。进入 `<path to cherry>` 并运行：

    `go run server.go`

19. 打开你常用的浏览器并访问 `localhost:8080`

    Get Started -> Choose Device “localhost” -> Select Tests “dEQP-VK” -> Execute tests!

20. 为确认正在运行 SwiftShader 的驱动，只选择 dEQP-VK->info->device 测试。在下一个窗口中，点击左侧窗格中的这些测试。如果在 deviceName 字段中看到 SwiftShader，则说明套件已正确设置。

21. 如果想在命令行中运行 Vulkan 测试，进入 dEQP 根目录下的 build 目录，然后运行以下命令：

    `external/vulkanacts/modules/vulkan/deqp-vk`

    也可以运行单个测试：

    `external/vulkanacts/modules/vulkan/deqp-vk --deqp-case=<test name>`

    你可以在 `<Swiftshader root>/tests/regres/testlists/vk-master.txt` 中找到测试名称列表。不过，deqp-vk 会在第一次失败时停止。除非你清楚自己在做什么，否则建议使用 cherry 来满足测试需求。

22. 要在 cherry 中确认正在运行 SwiftShader，请启动服务器

Mustpass 集合
-------------

dEQP 包含的测试比合格实现对期望通过的测试更多（例如，有些测试被认为过于严格，或假定了某些未定义行为）。[android/cts/master/vk-master.txt](https://android.googlesource.com/platform/external/deqp/+/master/android/cts/master/vk-master.txt) 文本文件可以加载到 Cherry 的 “Test sets” 选项卡中，以便只运行认证 Android 设备期望通过的最新测试。
