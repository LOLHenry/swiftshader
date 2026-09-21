# Reactor 调试信息生成

[English](ReactorDebugInfo.md) | 中文

## 简介

Reactor 会即时编译出动态可执行代码，可用于 JIT 出针对运行时配置特化的高性能函数，甚至可以用来构建编译器。

要在高于反汇编的层次调试可执行代码，需要源码文件。

Reactor 有两种潜在的源码来源：

1. 调用 Reactor 的程序的 C++ 源码。
2. 程序读取并传递给 Reactor 的外部源文件。

虽然情况 (2) 更适合实现编译器，但目前尚未实现。

Reactor 实现了情况 (1)，GDB 可以用它进行单行步进并检查变量。

## 支持的平台

当前：

* 调试信息生成仅在 Linux 上、使用 LLVM 7 后端时受支持。
* GDB 是唯一受支持的调试器。
* 程序本身必须带调试信息编译。

## 启用

使用 CMake 标志 `REACTOR_EMIT_DEBUG_INFO` 启用调试信息生成（默认关闭）。

## 实现细节

### 源码位置

所有 Reactor 函数都以调用 `RR_DEBUG_INFO_UPDATE_LOC()` 开始，它会进入 `rr::DebugInfo::EmitLocation()`。

`rr::DebugInfo::EmitLocation()` 调用 `rr::DebugInfo::getCallerBacktrace()`，后者再使用 [`libbacktrace`](https://github.com/ianlancetaylor/libbacktrace) 展开栈，并找出调用者的文件、函数和行号。

该信息会传给 `llvm::IRBuilder<>::SetCurrentDebugLocation`，以便为接下来要构建的 LLVM 指令发出源码行信息。

### 变量

生成变量调试信息有三个方面：

#### 1. 变量名

构造 Reactor `LValue`：

```C++
rr::Int a = 1;
```

会发出一条 LLVM `alloca` 指令来分配该变量的存储，再发出另一条指令把它初始化为常量 `1`。虽然写法流畅，但没有任何 Reactor 调用能看到 C++ 局部变量 "`a`" 的名称，LLVM `alloca` 值也只会得到一个无意义的数字编号。

Reactor 可以通过两种潜在方式获得变量名：

1. 使用正在运行的可执行文件自身的调试信息，检查局部声明并提取局部变量名。
2. 使用回溯信息，从源文件中解析名称。

虽然 (1) 可以说更干净、更稳健，但 (2) 更容易实现，并且能覆盖大多数用例。

当前实现的是 (2)。

`rr::DebugInfo::getOrParseFileTokens()` 会逐行扫描源文件，并用正则表达式查找 `<type> <name>` 模式。匹配并不精确，但足以找到带赋值和不带赋值的局部变量构造。

#### 2. 变量绑定

既然我们可以为给定源码行找到变量名，就需要一种把 LLVM 值绑定到该名称的方法。

以这个简单例子为例：

```C++
rr::Int a = 1
```

`rr::Int` 构造函数会调用 `RR_DEBUG_INFO_EMIT_VAR()`，把存储值作为唯一参数传入。`RR_DEBUG_INFO_EMIT_VAR()` 会进行回溯以找到源文件和行号，并使用 `rr::DebugInfo::getOrParseFileTokens()` 产生的 token 信息来识别变量名。

不过，当同一行上构造多个变量时，情况会更复杂。

例如：

```C++
rr::Int a = rr::Int(1) + rr::Int(2)
```

这里会对 `rr::Int` 构造函数进行 3 次调用，每次都会进入 `RR_DEBUG_INFO_EMIT_VAR()`。

为了区分其中哪一次应绑定到变量名 "`a`"，`rr::DebugInfo::EmitVariable()` 会把绑定缓冲到 `scope.pending` 中，给定行的最后一次绑定由 `DebugInfo::emitPending()` 使用。对于变量构造和赋值，C++ 保证左侧（LHS）是最后一个被构造的值。

该方案并不完美。

多行表达式、同一行上的多次赋值、宏混淆都可能破坏变量绑定——不过大多数典型情况可以工作。

#### 3. 变量作用域

`rr::DebugInfo` 维护一叠 `llvm::DIScope` 和 `llvm::DILocation`，镜像当前被调用函数的回溯。

通过用 `InlinedAt` 把 `llvm::DILocation` 串起来，会生成合成调用栈。

例如，在声明 `i` 时：

```C++
void B()
{
    rr::Int i; // <- here
}

void A()
{
    B();
}

int main(int argc, const char* argv[])
{
    A();
}
```

`DIScope` 层次结构会是：

```C++
                              DIFile: "foo.cpp"
rr::DebugInfo::diScope[0].di: ↳ DISubprogram: "main"
rr::DebugInfo::diScope[1].di: ↳ DISubprogram: "A"
rr::DebugInfo::diScope[2].di: ↳ DISubprogram: "B"
```

`DILocation` 层次结构会是：

```C++
rr::DebugInfo::diRootLocation:      DILocation(DISubprogram: "ReactorFunction")
rr::DebugInfo::diScope[0].location: ↳ DILocation(DISubprogram: "main")
rr::DebugInfo::diScope[1].location:   ↳ DILocation(DISubprogram: "A")
rr::DebugInfo::diScope[2].location:     ↳ DILocation(DISubprogram: "B")
```

其中 “↳” 表示一个 `InlinedAt`。


`rr::DebugInfo::diScope` 由 `rr::DebugInfo::syncScope()` 更新。

`llvm::DIScope` 通常不会嵌套——调用栈中的每个函数通常都有各自的 `llvm::DISubprogram`。函数内的所有局部变量通常共享同一作用域，无论它们是否在子块中声明。

函数内的循环和跳转会增加复杂性。考虑：

```C++
void B()
{
    rr::Int i = 0;
}

void A()
{
    for (int i = 0; i < 3; i++)
    {
        rr::Int x = 0;
    }
    B();
}

int main(int argc, const char* argv[])
{
    A();
}
```

在这个例子中，Reactor 不会感知 `for` 循环，并会尝试在 `A()` 的同一函数作用域中创建三个名为 "`x`" 的变量。同一 `llvm::DIScope` 中的重复符号会导致未定义行为。

为解决这个问题，`rr::DebugInfo::syncScope()` 会在函数向后跳转时观察到这一点，并为该函数 fork 当前的 `llvm::DILexicalBlock`。这会产生若干 `llvm::DILexicalBlock` 链，每一条都声明遮蔽前一块的变量。

在声明 `i` 时，`DIScope` 层次结构会是：

```C++
                              DIFile: "foo.cpp"
rr::DebugInfo::diScope[0].di: ↳ DISubprogram: "main"
                              ↳ DISubprogram: "A"
                              | ↳ DILexicalBlock: "A".1
rr::DebugInfo::diScope[1].di: |   ↳ DILexicalBlock: "A".2
rr::DebugInfo::diScope[2].di: ↳ DISubprogram: "B"
```

`DILocation` 层次结构会是：

```C++
rr::DebugInfo::diRootLocation:      DILocation(DISubprogram: "ReactorFunction")
rr::DebugInfo::diScope[0].location: ↳ DILocation(DISubprogram: "main")
rr::DebugInfo::diScope[1].location:   ↳ DILocation(DILexicalBlock: "A".2)
rr::DebugInfo::diScope[2].location:     ↳ DILocation(DISubprogram: "B")
```

### 调试器集成

调试信息生成之后，需要交给调试器。

Reactor 使用 [`llvm::JITEventListener::createGDBRegistrationListener()`](http://llvm.org/doxygen/classllvm_1_1JITEventListener.html#a004abbb5a0d48ac376dfbe3e3c97c306) 把 JIT 出的程序及其调试信息告知 GDB。
更多信息[可在此处找到](https://llvm.org/docs/DebuggingJITedCode.html)。

LLDB 理应也能支持同一机制，但在撰写本文时，这似乎无法工作。
