Subzero 文档
============

[English](Subzero.md) | 中文

Subzero 是用作 [Reactor](Reactor.zh.md) 后端的 JIT 编译器。它源自 Chrome 的 [Portable Native Client](https://developer.chrome.com/native-client) 项目。其权威仓库位于 [https://chromium.googlesource.com/native_client/pnacl-subzero/](https://chromium.googlesource.com/native_client/pnacl-subzero/)。

SwiftShader 中的 Subzero
------------------------

SwiftShader 包含一份 Subzero 源码的 fork（撰写本文时二者仍保持同步）。它是备选的 JIT 编译器后端，CMake 构建默认仍使用 LLVM。若要用 Subzero 代替 LLVM 构建 SwiftShader，请在 CMake 命令中指定 `-DREACTOR_BACKEND=Subzero`（或在 CMake GUI 中将 LLVM 改为 Subzero）。对于使用 BUILD.gn 文件的 Chrome 构建，默认使用 Subzero，因为它生成的二进制文件比 LLVM 小得多。

Subzero 开发
------------

在 Subzero 本身上开发需要在 Linux 系统上搭建 NaCl 环境，以便运行其单元测试：

* 安装 Chrome 的 [depot_tools](http://dev.chromium.org/developers/how-tos/install-depot-tools)。
* 运行 `mkdir nacl && cd nacl && fetch nacl`（[参考](http://www.chromium.org/nativeclient/how-tos/how-to-use-git-svn-with-native-client)）。
* 运行 `native_client/toolchain_build/toolchain_build_pnacl.py --verbose --sync --clobber --install toolchain/linux_x86/pnacl_newlib_raw`（[参考](https://sites.google.com/a/chromium.org/dev/nativeclient/pnacl/developing-pnacl#TOC-TL-DR-for-checking-out-PNaCl-sources-building-and-testing)）。
* 使用 `make -f Makefile.standalone check` 运行全部单元测试（[参考](https://chromium.googlesource.com/native_client/pnacl-subzero/+/master/docs/README.rst)）。
