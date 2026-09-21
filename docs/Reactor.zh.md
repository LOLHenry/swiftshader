Reactor 文档
============

[English](Reactor.md) | 中文

Reactor 是嵌入 C++ 中的一种语言，用于辅助动态代码生成与特化。

简介
----

若要用 LLVM 编译器框架为如下表达式生成代码：
```C++
float y = 1 - x;
```
需要执行：
```C++
Value *valueY = BinaryOperator::CreateSub(ConstantInt::get(Type::getInt32Ty(Context), 1), valueX, "y", basicBlock);
```

表达式一旦变长，这种方式很快就会难以阅读，写起来和改起来也很繁琐。

使用 Reactor 则只需写成：
```C++
Float y = 1 - x;
```
注意类型名以大写字母开头。这并不是真正执行计算的代码，而是在运行时记录“将要执行的计算”的代码。

这是通过 C++ 运算符重载实现的。Reactor 还以类似 C 的语法支持控制流结构和指针运算。

动机
----

即时编译（JIT）代码有可能通过[运行时特化](http://en.wikipedia.org/wiki/Run-time_algorithm_specialisation)比静态编译代码更快。但实践中很少真正做到这一点。

特化通常是指：针对某一组特定条件，使用更优的专用例程。例如对两个数排序时，如果它们尚未有序，直接交换会比调用通用的 quicksort 更快。特化可以静态完成：显式写出每种变体，或用元编程在静态编译期生成多种变体；也可以动态完成：在运行时检查参数并生成专用路径。

正因为特化可以静态完成（有时还辅以元编程），JIT 编译器在运行时做特化的能力常常被忽视。特化过的基准测试往往显示 JIT 代码并不优于静态代码。然而，特化过的基准并不能反映典型真实应用要面对的大量不可预测条件。系统可能只有一个核心，也可能有几十个核心，并带有许多不同的 ISA 扩展。仅此一点就使手工写出完全特化的例程变得不切实际；若借助元编程，又会导致代码膨胀。更糟的是，任何非平凡应用都有分层架构，下层（例如框架 API）对上层如何使用自己知之甚少甚至一无所知。许多参数还取决于用户输入。运行时特化可以访问每个例程执行时的完整上下文；虽然针对单个参数的特化收益可能很小，但组合起来的加速可以非常可观。一个极端例子是：解释器可以执行任何语言的任何程序，但针对某个具体程序做特化后，得到的就是该程序的编译版本。要观察到解释与通过编译做特化之间的巨大差异，并不需要一门完整的语言。大多数应用都会以解释方式处理某种命令列表，甚至对框架 API 的一系列调用，也可以在运行时被编译成更高效的整体。

运行时特化的好处现在应该已经很明显，但 JIT 编译语言缺少静态编译的许多实际优势。JIT 编译器能花在把字节码编译成机器码上的时间非常有限。这限制了它们甚至达到与静态编译持平的能力，更不用说通过运行时特化去超越静态编译。即便编译时间没有那么受限，也不能在每次机会都做特化，否则生成的代码量会爆炸式增长。必须非常有选择性地只为经常出现的热点条件做特化，并管理不同变体的缓存。即便只是选定构成完整特化条件的那一组变量的规模，也可能变得极其复杂。

显然，我们需要一种可控的方式：在收益显著的地方利用运行时特化，其余部分仍使用静态编译。一个关键观察是：开发者对应用程序行为有预期，这些信息非常有价值，可以用来在静态编译和 JIT 编译之间做选择。一种做法是使用会把应用开发者提供的命令即时编译的 API。例如，先进的数据库管理系统会把查询编译成一组优化过的例程，分别针对涉及的数据类型、CPU 缓存大小等做特化。另一个例子是现代图形 API：它接收着色器（对每个像素或其他元素执行的例程）以及一组影响其执行的参数，并把它们编译成 GPU 专用代码。然而，这些例子在 API 内外有非常硬的分界。静态编译的外部世界与 JIT 编译的例程之间无法交换数据，除非经由该 API，而且它们的执行模型也很不相同。换句话说，它们高度领域相关，并不是在任意代码中利用运行时特化的通用方法。

这对 GPU 尤其成问题：它们现在已经与 CPU 同样可编程，但你仍然只能通过 API 来指挥它们。试图用单一语言掩盖这一点的方案（例如 C++AMP 和 SYCL）仍然难以表达数据如何交换，实际上也不提供对特化的控制，存在隐藏开销，并且在不同设备上的性能特征难以预测。与此同时，CPU 拥有越来越多的核心和更宽的 SIMD 向量单元，但静态编译语言并不能轻易利用这些能力，也无法应对榨取最优性能所需的大量代码路径。因此需要一种不同的语言和框架。

概念与语法
----------

### Routine 与 Function<>

Reactor 允许你在运行时创建新函数。它们的生成发生在 C++ 中；物化之后，可以在同一个 C++ 程序的执行过程中调用它们。我们把这些动态生成的函数称为“例程”（routine），以区别于静态编译的函数和方法。Reactor 的 `Routine` 类封装一个例程。删除 Routine 对象时，也会释放用于存储该例程的内存。

要声明例程的函数签名，使用 `Function<>` 模板。模板参数是函数签名，其中使用 Reactor 变量类型。下面是一个不接受参数、返回整数的例程的完整定义：

`C++
Function<Int(Void)> function;
{
    Return(1);
}
`

花括号并非必需。它们只是让语法看起来更像普通 C++，并为 Reactor 变量提供一个新的作用域。

通过“调用”`Function<>` 对象并为其命名，即可获得并物化 Routine：

```C++
auto routine = function("one");
```

最后，我们可以取得该例程入口点的函数指针并调用它：

```C++
int (*callable)() = (int(*)())routine->getEntry();

int result = callable();
assert(result == 1);
```

注意，`Function<>` 对象相对较重，因为其背后是整个 JIT 编译器；而 `Routine` 对象很轻量，只负责生成例程的存储和生命周期管理。因此我们通常让 `Function<>` 对象销毁（离开作用域即可），同时保留 `Routine` 对象，直到不再需要调用该例程。这也是二者需要区分、并因此需要几行样板代码的原因。

### 参数与表达式

例程可以接受各种参数。下面的例子展示如何访问一个接受两个整数参数并返回它们之和的例程的参数：

```C++
Function<Int(Int, Int)> function;
{
    Int x = function.Arg<0>();
    Int y = function.Arg<1>();

    Int sum = x + y;

    Return(sum);
}
```

Reactor 支持多种与 C++ 类型对应的类型：

| 类名          | 对应的 C++ 类型 |
| ------------- |----------------|
| Int           | int32_t        |
| UInt          | uint32_t       |
| Short         | int16_t        |
| UShort        | uint16_t       |
| Byte          | uint8_t        |
| SByte         | int8_t         |
| Long          | int64_t        |
| ULong         | uint64_t       |
| Float         | float          |

注意：字节类型默认无符号，除非以 S 为前缀；更大的整数类型默认有符号，除非以 U 为前缀。

这些标量类型支持所有 C++ 算术运算。

Reactor 还支持若干向量类型。例如 `Float4` 是四个 float 组成的向量。它们支持一部分 C++ 运算符，以及若干“内建”函数，例如用 `Max()` 计算逐元素最大值并返回位掩码。所有类型、运算符和内建函数请参见 [Reactor.hpp](../src/Reactor/Reactor.hpp)。

### 转换与重解释

可以用构造函数风格的语法进行类型转换：

```C++
Function<Int(Float)> function;
{
    Float x = function.Arg<0>();

    Int cast = Int(x);

    Return(cast);
}
```

可以使用 `As<>` 对变量做重解释转换：

```C++
Function<Int(Float)> function;
{
    Float x = function.Arg<0>();

    Int reinterpret = As<Int>(x);

    Return(reinterpret);
}
```

注意这是按位转换。与 C++ 的 `reinterpret_cast<>` 不同，它不允许在不同大小的类型之间转换。可以把它理解为：把值存入内存，再从同一地址加载到目标类型。

一个重要例外是：16 字节、8 字节和 4 字节的向量可以转换为这些尺寸之一的其他向量。转换到更长的向量时，高位内容未定义。

### 指针

指针同样使用模板类：

```C++
Function<Int(Pointer<Int>)> function;
{
    Pointer<Int> x = function.Arg<0>();

    Int dereference = *x;

    Return(dereference);
}
```

指针运算只支持 `Pointer<Byte>`，并可用于访问结构体字段：

```C++
struct S
{
    int x;
    int y;
};

Function<Int(Pointer<Byte>)> function;
{
    Pointer<Byte> s = function.Arg<0>();

    Int y = *Pointer<Int>(s + offsetof(S, y));

    Return(y);
}
```

Reactor 还定义了 `OFFSET()` 宏，它是 `<cstddef>` 中 `offsetof()` 宏的推广。例如，即使动态索引，也可以用它获取数组元素的偏移。

### 条件语句

例如要生成[单位阶跃](https://en.wikipedia.org/wiki/Heaviside_step_function)函数：

```C++
Function<Float(Float)> function;
{
    Pointer<Float> x = function.Arg<0>();

    If(x > 0.0f)
    {
        Return(1.0f);
    }
    Else If(x < 0.0f)
    {
        Return(0.0f);
    }
    Else
    {
        Return(0.5f);
    }
}
```

还有一个 `IfThenElse()` 内建函数，对应于 C++ 的 `?:` 运算符。

### 循环

循环的语法也与 C++ 类似：

```C++
Function<Int(Pointer<Int>, Int)> function;
{
    Pointer<Int> p = function.Arg<0>();
    Int n = function.Arg<1>();
    Int total = 0;

    For(Int i = 0, i < n, i++)
    {
        total += p[i];
    }

    Return(total);
}
```

注意循环表达式之间用逗号而不是分号分隔。

`While(expr) {}` 的行为也符合预期，但没有与 `Do {} While(expr)` 对等的写法，因为无法区分二者。取而代之的是 `Do {} Until(expr)`，可以用相反的表达式来退出循环。

特化
----

上面的例子并不能说明任何无法用普通 C++ 函数写出的东西。Reactor 真正的能力，是生成针对某一组条件或“状态”特化的例程。

```C++
Function<Int(Pointer<Int>, Int)> function;
{
    Pointer<Int> p = function.Arg<0>();
    Int n = function.Arg<1>();
    Int total = 0;

    For(Int i = 0, i < n, i++)
    {
        if(state.operation == ADD)
        {
            total += p[i];
        }
        else if(state.operation == SUBTRACT)
        {
            total -= p[i];
        }
        else if(state.operation == AND)
        {
            total &= p[i];
        }
        else if(...)
        {
            ...
        }
    }

    Return(total);
}
```

注意这个例子使用的是普通 C++ 的 `if` 和 `else`。它们只决定哪些代码会进入生成的例程，本身并不会出现在生成的代码中。因此该例程的循环里只有一种算术或逻辑运算，比用普通 C++ 写出的版本更高效。

当然，也可以用普通 C++ 写出等价的高效函数，如下：

```C++
int function(int *p, int n)
{
    int total = 0;

    if(state.operation == ADD)
    {
        for(int i = 0; i < n; i++)
        {
            total += p[i];
        }
    }
    else if(state.operation == SUBTRACT)
    {
        for(int i = 0; i < n; i++)
        {
            total -= p[i];
        }
    }
    else if(state.operation == AND)
    {
        for(int i = 0; i < n; i++)
        {
            total &= p[i];
        }
    }
    else if(...)
    {
        ...
    }

    return total;
}
```

但现在有大量重复代码。可以用宏或模板让它更好管理，但这并不能减小静态编译代码的二进制体积。当只需为少数几种状态条件做特化时，这还可以接受；但当你有多个状态变量、每个变量又有许多可能取值时，组合总数会变得难以承受。

在实现功能面很广、而开发者很可能只用其中一小部分的 API 时，这种情况尤为典型。最典型的例子就是图形处理：管线很长，包含大量可选操作，既有固定功能阶段也有可编程阶段。应用程序会在每次绘制调用之间配置这些阶段的状态。

有了 Reactor，我们可以用接近朴素未优化实现的、易于阅读的语法来编写这类管线的代码，同时让生成的代码恰好只包含该管线配置所需的操作。
