# `marl::Scheduler`

[English](scheduler.md) | 中文

本文说明调度器**内部怎么工作**，不是使用手册。英文原稿：[scheduler.md](scheduler.md)。

目录：

- [`marl::Scheduler`](#marlscheduler)
  - [绑定](#绑定)
  - [纤程（Fiber）](#纤程fiber)
  - [任务](#任务)
  - [工人](#工人)
    - [`marl::Scheduler::Worker::run()`](#marlschedulerworkerrun)
    - [`marl::Scheduler::Worker::runUntilIdle()`](#marlschedulerworkerrununtilidle)
    - [`marl::Scheduler::Worker::waitForWork()`](#marlschedulerworkerwaitforwork)
    - [`marl::Scheduler::Worker::spinForWork()`](#marlschedulerworkerspinforwork)
    - [`marl::Scheduler::Worker::suspend()`](#marlschedulerworkersuspend)
  - [工人种类](#工人种类)
    - [单线程工人](#单线程工人)
    - [多线程工人](#多线程工人)

`marl::Scheduler` 是 marl 里最复杂的部分：负责执行任务，并在任务阻塞时让线程继续有活可干。

## 绑定

每个会调用 `marl::schedule()` 的线程，都必须先绑定调度器。
析构调度器时会阻塞，直到它从所有线程上解绑。

绑定和解绑用 `marl::Scheduler::bind()`、`marl::Scheduler::unbind()`。

绑定会写一份线程局部存储，把调度器和当前线程绑在一起。作用有两层：

1. 调用 `marl::schedule()` 以及各种同步原语时，不必再传 `marl::Scheduler` 指针。
2. 更重要的是：能拿到**当前线程正在执行的纤程（Fiber）**。`marl::ConditionVariable::wait()` 靠这个把当前纤程挂起、放进一个容器；`marl::ConditionVariable::notify_`xxx`()` 再把这些被挡住的纤程重新排进调度。

每次绑定还会为调用线程建一个内部的[单线程工人](#单线程工人)。没有[多线程工人](#多线程工人)可用时，任务就排到这个工人上。解绑会等到该单线程工人上已排的任务都做完再返回。

## 纤程（Fiber）

[纤程（Fiber）](https://en.wikipedia.org/wiki/Fiber_(computer_science))是一种很轻的协作式线程，只能在明确的让出点挂起和恢复。后文里的「纤程」都指 Fiber，和操作系统线程（Thread）不是一回事。

目前没有统一、跨平台的纤程/协程标准库，所以 marl 为各平台和 ABI 自己实现了 `marl::OSFiber`。多数实现是汇编：保存/恢复被调用者保存的寄存器，并维护一块纤程栈。`marl::OSFiber` 是内部细节，不出现在公开 API 里。

`marl::Scheduler::Fiber` 是对外的纤程（Fiber）接口，和 `marl::Scheduler` 绑得很紧。接口风格接近 `std::condition_variable`。

每个 `marl::Scheduler::Fiber` **永久**属于一个 `marl::Scheduler::Worker`，恢复时保证仍在挂起时的那条线程上。

## 任务

`marl::Task` 是 `std::function<void()>` 的别名：无参数、无返回值的函数。

任务用 `marl::schedule()` 提交，通常写成 lambda：

```c++
marl::schedule([] {
    printf("Hello world!\n");
});
```

签名虽然没有参数，但 lambda 里可以捕获变量，当作任务的输入输出。

除 `marl::ConditionVariable` 外，marl 的同步原语都持有一份指向内部状态的共享指针。**请按值捕获**这些原语。按引用捕获看起来省事，但如果任务活得比调用 `marl::schedule()` 的那一帧栈更久，就会踩内存。共享状态有分配和性能开销，这里选择了安全优先。

```c++
marl::WaitGroup wg(1);
marl::schedule([=] { // 按值捕获，不要按引用！
    printf("Hello world!\n");
    wg.done();
});
wg.wait();
```

## 工人

调度器里有若干 `marl::Scheduler::Worker`。每个工人持有：

- `work.tasks`：尚未开始的任务队列。
- `work.fibers`：已挂起、可以恢复的纤程（Fiber）队列。
- `work.waiting`：已挂起、在等恢复或超时的纤程队列。
- `work.num`：与 `work.tasks.size() + work.fibers.size()` 保持一致的计数。
- `work.numBlockedFibers`：当前卡在 [`suspend()`](#marlschedulerworkersuspend) 里的纤程数。
- `idleFibers`：空闲、可复用的纤程集合。

`marl::schedule()` 提交任务时，会挑一个工人，把任务放进该工人的 `work.tasks`。挑选规则：

- 调度器没有专用工作线程（`marl::Scheduler::config().workerThreads.count == 0`）时，任务排到**当前线程**的[单线程工人](#单线程工人)上。
- 否则挑一个[多线程工人](#多线程工人)。若有工人正处于[为工作自旋](#marlschedulerworkerspinforwork)状态，优先给它们；否则按轮转挑一个多线程工人。

### `marl::Scheduler::Worker::run()`

`run()` 是工人纤程的主处理函数。[多线程工人](#多线程工人)线程一启动就会调它；[`Worker::suspend()`](#marlschedulerworkersuspend) 在其它纤程都阻塞、需要再拉一条工人纤程时也会调它。

[单线程](#单线程工人)和[多线程](#多线程工人)工人共用这个函数。

`run()` 调用 `runUntilShutdown()`，循环做两件事：

- 调 [`waitForWork()`](#marlschedulerworkerwaitforwork)，一直等到有新活。
- 调 [`runUntilIdle()`](#marlschedulerworkerrununtilidle)，把新任务和纤程处理掉。注意 [`runUntilIdle()`](#marlschedulerworkerrununtilidle) 内部会切换纤程，所以同一条线程上 `run()` 的执行可能在多条纤程之间跳。

循环直到工人做完所有活、并被要求关机。

因关机退出循环后，会恢复 `mainFiber`，由它处理剩余关机逻辑。

![流程图](imgs/worker_run.svg)

### `marl::Scheduler::Worker::runUntilIdle()`

顾名思义：一直执行，直到没有活，或剩下的活全被挡住。

基本逻辑：

1. 恢复已解除阻塞的纤程

   先把 `work.fibers` 里可以恢复的纤程做完。做法：从 `work.fibers` 取出一条纤程，把**当前**纤程放进 `idleFibers`（它正在找活，算空闲），然后切换到取出的那条。

   恢复已有纤程优先于开新任务。因为新任务可能再派生纤程，而每条纤程都要占内存（通常是栈）。

2. 开始执行新任务

   可恢复的纤程都做完或再次阻塞后，从 `work.tasks` 取新任务执行。任务结束后回到 `runUntilIdle()`，从第 1 步再来。

3. 没有纤程也没有任务可执行时，`runUntilIdle()` 返回。

![流程图](imgs/worker_rununtilidle.svg)

### `marl::Scheduler::Worker::waitForWork()`

工人既没有可开的任务、也没有可恢复的纤程时，调用 `waitForWork()`，阻塞到有事可做。

若是[多线程工人](#多线程工人)，`waitForWork()` 一开始会进入 [`spinForWork()`](#marlschedulerworkerspinforwork)；单线程工人跳过这一步。

然后等到下面任一情况发生再返回：

- 有纤程可以恢复，被放进 `work.fibers`。
- 有任务被放进 `work.tasks`。
- `work.waiting` 里有纤程超时。
- 工人被要求关机。

返回前，会把 `work.waiting` 里已超时的纤程自动挪到 `work.fibers`。

![流程图](imgs/worker_waitforwork.svg)

### `marl::Scheduler::Worker::spinForWork()`

> 源码里对应函数现名为 `spinForWorkAndLock()`，行为与下文一致。

`spinForWork()` 做两件事：

1. 尝试从别的工人**偷活**，让各工人负载更均匀。

   任务时长差可以很大，时间一长有的工人队列堆满、有的挨饿。`spinForWork()` 只在本工人挨饿时调用，会随机挑别的工人偷**任务**。纤程必须在同一条线程上恢复，所以只能偷任务，不能偷纤程。

2. 尽量避免把线程让给操作系统。

   常见情况：一个任务（生产者）往调度器上丢很多小任务，再均分给工人（消费者）。消费者往往比生产者多，生产者很难一直喂饱所有人。

   这时工人容易陷入：拿到一个任务、做完、再短等下一批。若一没活就 `std::condition_variable::wait()` 把线程交给 OS，代价很大。视平台而定，再被调度回来可能要一毫秒甚至更久。这种停顿会把整张任务依赖图都卡住。

`spinForWork()` 里有一段只跑很短时间的循环。每一轮：

- 先用一串 `nop` 占着 CPU，并隔一会儿看 `work.num` 有没有新活。有活则立刻返回。
- 没有新排进来的活，就尝试从另一个随机工人偷一个任务。偷到则立刻返回。
- 没偷到，调用 `std::this_thread::yield()`，免得 marl 把操作系统饿死。

![流程图](imgs/worker_spinforwork.svg)

### `marl::Scheduler::Worker::suspend()`

Marl 允许任务阻塞，同时让线程别闲着。

任务阻塞时调用 `Scheduler::Worker::suspend()`。它先调 [`waitForWork()`](#marlschedulerworkerwaitforwork)，等到有任务或纤程可执行，然后：

 1. 若有未阻塞的纤程，从 `work.fibers` 取出并切换过去。
 2. 否则若有空闲纤程，从 `idleFibers` 取出并切换过去。这条空闲纤程恢复后继续执行任务。
 3. 以上都没有，就新建一条纤程，入口是 [`marl::Scheduler::Worker::run()`](#marlschedulerworkerrun)，再切换过去。

三种情况都会切到另一条纤程。被挂起的纤程以后恢复时，`suspend()` 才返回给调用者。

![流程图](imgs/worker_suspend.svg)

## 工人种类

工人创建时要么是单线程工人，要么是多线程工人。

两种模式的大部分逻辑相同。

最大差别：多线程工人会再拉一条专用线程去调 `marl::Scheduler::run()`；单线程工人只在**其它纤程都阻塞**时，才在一条新纤程上调 `marl::Scheduler::run()`。

### 单线程工人

每个用 `marl::Scheduler::bind()` 绑过的线程，都会有一个单线程工人（STW）。

调度器没有专用工作线程（`marl::Scheduler::config().workerThreads.count == 0`）时，提交的任务排到**当前线程**的 STW 上。

这种模式下没有工作线程，STW 上的任务**不会在后台自动跑**。只有调用 [`marl::Scheduler::Worker::suspend()`](#marlschedulerworkersuspend) 时才会执行。
[`suspend()`](#marlschedulerworkersuspend) 的逻辑 STW 和 MTW 共用：其它纤程都阻塞时，再拉新纤程去调 [`run()`](#marlschedulerworkerrun)。

```c++
void SingleThreadedWorkerExample() {
  marl::Scheduler::Config cfg;
  cfg.setWorkerThreadCount(0); // STW 模式

  marl::Scheduler scheduler(cfg);
  scheduler.bind();
  defer(scheduler.unbind());

  // marl::schedule() 只把任务排到 STW 上，线程被挡住之前不会执行。
  marl::Event done;
  marl::schedule([=] {
    done.signal();
  });

  // 这是阻塞调用。
  // marl::Event::wait()（间接）调用 marl::Scheduler::Worker::suspend()。
  // suspend() 创建并切换到一条纤程，该纤程调用 run() 跑完队列里的任务。
  // 主纤程解除阻塞后，runUntilIdle() 再切回主纤程，继续跑应用。
  done.wait();
}
```

### 多线程工人

构造 `marl::Scheduler` 时若工作线程数大于 0（`marl::Scheduler::Config::workerThread::count > 0`），就会创建多线程工人（MTW）。

每个 MTW 配一条新的 `std::thread`，线程入口调用 `marl::Scheduler::Worker::run()`。

工人被要求关机且活都做完后，`run()` 退出主循环，切回主线程纤程，这条 `std::thread` 结束。
