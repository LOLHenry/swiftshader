# 在 openEuler 22 上让内核提供 Android Binder

对象是要把 redroid 跑起来的现场工程师。本文只解决一件事：宿主机 Linux 内核里还没有 Android Binder 时，怎么让系统支持它。

**Android Binder** 是 Android 服务之间通信用的内核机制。redroid 的客户机要靠宿主机内核提供 Binder（现在常见形态是 **Binder 文件系统 binderfs**）。没有它，容器起不来，后面的 4 核 8 吉字节秒表环境也跑不成。

Binder 不是一个用户态守护进程，也没有 `systemctl start binder` 这种服务。要么内核里已经编进去了，要么编成可加载模块再装上，要么换一颗打开了相应配置的内核。

**现场不能重启、也没有换内核权限时，只能走树外模块：编 `binder_linux.ko`，当场 `insmod`，不要碰启动项。** 换内核那条路需要重启，这篇里标成「有权限再做」。源码用 openEuler 自己的内核源码包，不要去 GitHub。

整段命令必须放进 `bash -s <<'EOF'` 或脚本文件里执行。不要直接贴进当前登录 shell：脚本里的 `exit` 和 `exec` 会结束登录会话，看起来像突然 logout。下载源码包和编译可能要十几分钟，请先开 `tmux` 或 `screen`，避免 SSH 闲置断线把任务带走。

openEuler 22 常见内核是 Linux 5.10。发行版默认配置通常**不打开** Android Binder。这和 Ubuntu 不一样：Ubuntu 往往只要再装 `linux-modules-extra`，然后 `modprobe binder_linux` 就能用。openEuler 22 不能指望这一步。

---

## 0. 先贴这一段探测（不换内核）

在 **openEuler 22 宿主机** root 或 sudo 用户下整段粘贴。它只看现状，并在磁盘上已有模块时尝试加载。加载失败是常见结果，把从 `======== 1` 到 `======== 结论` 的输出留下来即可。

```bash
bash -s <<'EOF'
set +e
echo "======== 1. 机器 ========"
echo "内核：$(uname -r)"
. /etc/os-release 2>/dev/null
echo "发行版：${PRETTY_NAME:-未知}"
echo "架构：$(uname -m)"

echo
echo "======== 2. 现在有没有 Binder ========"
grep -E '[[:space:]]binder$' /proc/filesystems || echo "还没有 binder。"

echo
echo "======== 3. 已加载模块 / 磁盘上的模块文件 ========"
lsmod | grep -E 'binder|ashmem' || echo "当前没有加载 binder / ashmem 模块。"
find /lib/modules/"$(uname -r)" \( -iname '*binder*' -o -iname '*ashmem*' \) -print 2>/dev/null
echo

echo "======== 4. 内核配置 ========"
if [[ -r /proc/config.gz ]]; then
	zgrep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /proc/config.gz || echo "没有相关行。"
elif [[ -r /boot/config-$(uname -r) ]]; then
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /boot/config-"$(uname -r)" || echo "没有相关行。"
else
	echo "找不到本机内核配置。"
fi

echo
echo "======== 5. 尝试加载（没有模块时失败是正常的） ========"
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"
echo "modprobe binder_linux 退出码：$?"
sudo modprobe binder
echo "modprobe binder 退出码：$?"
grep -E '[[:space:]]binder$' /proc/filesystems || echo "仍然没有 binder。"

echo
echo "======== 6. ashmem / 安全增强型 Linux ========"
grep ashmem /proc/misc || echo "没有 ashmem（秒表环境可用 androidboot.use_memfd=true）。"
command -v getenforce >/dev/null && echo "getenforce：$(getenforce)" || echo "没有 getenforce。"

echo
echo "======== 结论 ========"
if grep -qE '[[:space:]]binder$' /proc/filesystems; then
	echo "Binder 已经可用。若 redroid 仍起不来，测试机先：sudo setenforce 0"
else
	echo "Binder 仍然不可用。不是服务没启动，是这颗内核没提供。下一步先跑第 4 节树外编模块；编不过再走第 3 节换内核。"
fi
EOF
```

仓库里同一套探测是 `scripts/redroid_4u8g_stopwatch/probe_host_binder.sh`。只看、不尝试加载，用 `check_host_binder.sh`。

怎么读这段输出：

- 第 2 节或第 5 节末尾出现 `nodev binder`：探测通过，可以去跑 redroid。
- 第 5 节 `modprobe` 报 `not found` / `无法找到模块`，第 3 节也没有 `.ko`，第 4 节没有 `CONFIG_ANDROID_BINDER` 或全是未打开：发行版默认就是这样，接着看第 3 节或第 4 节。
- 不要因为宿主机没有 `/dev/binder` 判定失败。

---

## 1. 先在本机看清楚缺的是什么

在 **openEuler 22 宿主机**上执行，把输出留下来：

```bash
uname -r
cat /etc/os-release | head -n 8

# 内核是否已经登记了 Binder 文件系统。成功时应看到一行：nodev	binder
grep binder /proc/filesystems || echo "还没有 binder 文件系统"

# 是否已经有可加载模块挂着
lsmod | grep -E 'binder|ashmem' || echo "当前没有加载 binder / ashmem 模块"

# 磁盘上有没有现成的模块文件
find /lib/modules/"$(uname -r)" -iname '*binder*' -o -iname '*ashmem*' 2>/dev/null

# 这颗正在跑的内核当初有没有把 Android Binder 编进去
# 有 /proc/config.gz 就用它；否则看 /boot/config-$(uname -r)
if [[ -r /proc/config.gz ]]; then
	zgrep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /proc/config.gz
elif [[ -r /boot/config-$(uname -r) ]]; then
	grep -E 'CONFIG_ANDROID|CONFIG_ASHMEM' /boot/config-"$(uname -r)"
else
	echo "找不到本机内核配置，请到 /boot 或 /usr/src/kernels/$(uname -r)/.config 再查"
fi
```

怎么读结果：

| 你看到的 | 含义 | 下一步 |
|----------|------|--------|
| `/proc/filesystems` 已有 `nodev binder` | 内核已经提供 Binder | 不要再改内核。去看第 5 节把加载写进开机，再看第 6 节的安全增强型 Linux |
| 配置项是 `=y`，但文件系统里没有 binder | 少见，多半是这颗内核和 `/boot` 里的配置对不上 | 先确认 `uname -r` 和你读的那份配置是同一颗内核 |
| 配置项是 `=m`，并且 `/lib/modules/...` 里有模块文件 | 已经编成模块，只是没装上 | 走第 2 节，直接加载 |
| 配置项是 `=n`、被注释，或者根本没有这些行；磁盘上也没有模块 | **发行版默认就是这样** | 走第 3 节（官方：换内核）或第 4 节（不换整颗内核，只编模块） |

**匿名共享内存 ashmem** 不是 redroid 16 的硬条件。本仓库的秒表脚本已经写了 `androidboot.use_memfd=true`，用内存文件描述符代替 ashmem。第 3 节里的 `CONFIG_ASHMEM` 可以以后再开。先把 Binder 弄出来。

宿主机上没有 `/dev/binder` 这个字符设备，**不等于** Binder 没好。开了 binderfs 之后，设备节点常常是容器里按需创建的。判断标准是 `grep binder /proc/filesystems` 出现 `nodev binder`，不是宿主机根目录下有没有那个文件。

---

## 2. 模块已经在磁盘上：加载即可

若第 1 节找到了 `binder_linux.ko` 或同类文件：

```bash
# 一次加载三个逻辑设备：普通 Binder、硬件 Binder、厂商 Binder
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"

# 验收
grep binder /proc/filesystems
# 期望：nodev	binder
```

若 `modprobe` 报找不到模块，先确认模块目录和正在跑的内核版本一致：

```bash
uname -r
ls /lib/modules/"$(uname -r)"
```

版本对不上时，加载的是另一颗内核的模块，会失败。不要强行 `insmod` 别人机器上拷来的 `.ko`。

---

## 3. 「只能编进内核」是什么意思

openEuler 的 Linux 5.10 把 `CONFIG_ANDROID_BINDER_IPC` 写成 **bool**：编这颗内核时只能选打开（`y`，做进内核镜像）或关掉（`n`），**不能**选 `m` 做成发行版自带的可加载模块。所以仓库里没有 `binder_linux.ko` 可 `modprobe`，Ubuntu 那种「再装一组额外模块」在这里不成立。

这**不等于**你正在跑的内核已经有 Binder。发行版默认选的是关掉（`n`）。因此会出现：配置语义是「只能内置」，而本机 `/proc/filesystems` 里仍然没有 `binder`。

怎么办，只有两条路：

1. **不能重启时（现场默认）**：无视这份 bool，把 `binder.c` 等文件在树外拼成 `binder_linux.ko`，当场 `insmod`。不改启动项、不换 `uname -r`。编不过或加载报版本魔数、未知符号，这台机器在重启权限下来之前做不了 Binder。见第 4 节。
2. **有换内核和重启权限时**：用同一条 openEuler 5.10 源码，把上面四个配置改成 `y`，编出新内核，安装并重启。见第 3.1 节。

不要尝试把正在跑的内核的 `.config` 改成 `=m` 再 `make M=drivers/android`。bool 开关不会因此变成模块。

---

## 3.1 官方路径：用打开了 Binder 的 5.10 内核

redroid 给 openEuler 的部署说明写得很明确：在 **自定义的 Linux 5.10 长期支持内核**里打开下面这些项，然后安装、重启，让 `uname -r` 变成这颗新内核。

必须打开（Binder）：

```text
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
```

建议一并打开（编解码和缓冲堆；和秒表软渲染无直接关系，但官方清单里有）：

```text
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
```

可选（本仓库用内存文件描述符，可以暂缓）：

```text
CONFIG_STAGING=y
CONFIG_ASHMEM=y
```

来源：[redroid-doc 的 openEuler 部署说明](https://github.com/remote-android/redroid-doc/blob/master/deploy/openeuler.md)。

内核源码要用 **和现场同一条产品线、同一大版本** 的 openEuler 22 内核，不要随便下一份主线 5.10。用软件源装，不要去官网下 `src.rpm`：

```bash
uname -r
yum whatprovides kernel-source
yum install -y "kernel-source-uname-r == $(uname -r)"
# 若上面的提供名不存在，改用 whatprovides 列出的全名，例如：
# yum install -y kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
```

现场 323 已确认：这个包装到 `/usr/src/linux-$(uname -r)/`，里面有 `Makefile` 和 `drivers/android/binder.c`。`kernel-source` 是解开的源码树，不是 `src.rpm`。

若这份树里做过 `make`、改过 `drivers/android/Makefile`，或怕被污染：不要 `yum reinstall`（额外文件删不掉）。卸掉、删目录、再装同一颗：

```bash
yum remove -y kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
rm -rf /usr/src/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64
yum install -y kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
rm -rf /home/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64 /home/kbuild
rpm --verify kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
ls /usr/src/linux-$(uname -r)/drivers/android/binder.c
```

不要装成别的内核版本。正在跑的 `kernel` / `kernel-devel` 不要动。`build_binder_kernel.sh` 开头会做同一套重装。

不要在 `/usr/src` 里 `make`（会弄脏软件包文件，也容易把根分区写满）。工作目录放 `/home`。以正在跑的 `/boot/config-$(uname -r)` 为底，只打开上面四项，编完把 `Image` 打成和发行版一样的 gzip `vmlinuz`，用 `dracut` 生成初始化内存盘，`grubby --copy-default` 加启动项，**默认启动仍指向正在跑的 323**。仓库脚本一次做完这些：

```bash
# tmux 里跑，不要直接贴进登录 shell
bash scripts/redroid_4u8g_stopwatch/build_binder_kernel.sh
```

脚本结束且默认启动仍是 323 之后，打开 iBMC 控制台，再把新内核设为默认并重启。失败就在控制台选回 323。重启后再跑第 1 节：`grep binder /proc/filesystems` 必须出现 `nodev binder`。`uname -r` 会带 `binder`，第 4 节的树外模块就不必再加载。

这条路会换内核，影响面最大，但也是 redroid 文档承认的 openEuler 做法。现场若本来就要维护自有内核，优先走这里。

---

## 4. 探测已确认没有 Binder：先试树外编模块

第 0 节如果打出「Binder 仍然不可用」，含义已经定了：不是服务没启动，是这颗 **Linux 5.10 内核编译时没打开 Android Binder**。上游把 `CONFIG_ANDROID_BINDER_IPC` 写成 **bool**（只能 `y` 或 `n`），所以 **不能** 在内核树里 `make M=drivers/android` 当可加载模块。Ubuntu 能 `modprobe binder_linux`，是因为他们另外打了包；openEuler 22 默认没有这一包。

还不能换整颗内核时，先走树外模块：把 `binder.c`、`binder_alloc.c`、`binderfs.c` 拼成一个 `binder_linux.ko`，对着 **和 `uname -r` 完全一致** 的 `kernel-devel` 来编。这是试验，不是 redroid 文档承认的 openEuler 路径；编不过或 `insmod` 报版本魔数 / 符号不存在，就停，改走第 3 节换内核。不要关版本检查硬装。

模块后期处理报 `can_nice`、`task_work_add`、`security_binder_*` 未定义，和「内核符号表里看得到这些名字」不是一回事。符号表里有，只说明内核镜像里有这份函数；模块只能调用**导出表**里的符号。这颗内核把 Binder 当成内置专用，安全钩子往往**不导出**。带 GPL 字样的导出还要求模块声明 GPL 许可。不要关版本检查。处理办法：模块声明 GPL；对未导出的安全钩子在模块内做「直接放行」的本地实现；对已导出但后期处理仍抱怨的符号，先看是不是许可证没声明。仍对不上才是这条路的终点。

现场若已经具备完整内核源码和 `kernel-devel`（例如 `/usr/src/linux-$(uname -r)/drivers/android/*.c` 与 `/usr/src/kernels/$(uname -r)`），**不要再下载源码包**。完整源码树里 `make modules_prepare` 成功、`auto.conf` 出现 `CONFIG_ANDROID_BINDER_IPC=m`，只说明这份源码能编，不等于正在跑的内核已经有 Binder。不要用改过配置的完整源码树当 `make -C` 的目录（和正在跑的内核对不齐），也不要在那里 `make M=drivers/android`（会拆成多个不能单独加载的 `.ko`）。`.c` 拷到 `/home/redroid-binder-build`，对着 `kernel-devel` 合成一个 `binder_linux.ko`。模块很小，不要 `make -j320`。

现场只能复制粘贴时：整段放进圆括号子 shell，不要 heredoc、不要 `for ... do`、不要把 `exit` 贴进登录 shell。仓库里的 `scripts/redroid_4u8g_stopwatch/build_binder_local.sh` 仅作备份。

仍然不要做：

- 不要 `git checkout origin/openeuler2003` 去编 [redroid-modules](https://github.com/remote-android/redroid-modules)。那一支是 **openEuler 20.03 / Linux 4.19**。
- 不要从别的内核版本拷 `.ko` 过来。

先看磁盘。现场常见情况是：根分区 `/`（例如 69 吉字节）被 Docker 的 `/var/lib/docker` 占满，`/home` 却还有上百吉字节。工作目录应写到 `/home`，但 `kernel-devel` 仍要装进根分区的 `/usr` 和 `/lib`，**只改工作目录不够**，必须先给 `/` 腾出至少约 1 吉字节。

```bash
df -hT
sudo du -xhd1 / | sort -h
sudo docker system df
# 安全清理：软件包缓存、日志、悬空镜像。不要删正在跑的容器。
sudo dnf clean all
sudo rm -rf /var/cache/dnf/*
sudo journalctl --vacuum-size=80M
sudo docker image prune -f
sudo docker builder prune -f
df -hT /
# 根分区有空位之后：
WORK=/home/redroid-binder-build sudo -E bash scripts/redroid_4u8g_stopwatch/build_host_binder.sh
```

默认不要写 `/root`（它在已满的根分区上）。内核必须是正在跑的那一颗（例如 `5.10.0-323.0.0.224.oe2203sp4.aarch64`），开发包名是同一串加上 `kernel-devel-`。

`kernel-devel` 通常只有头文件和 Makefile，**没有** `drivers/android/binder.c`。编模块必须有这些 `.c` 文件，但不必去 GitHub 拉上游 Linux 5.10：用和 `uname -r` 一致的 openEuler 内核源码包即可，例如 `kernel-5.10.0-323.0.0.224.oe2203sp4.src.rpm`。没有源码就编不出 `.ko`，换整颗内核同样需要这份源码。

验收仍然是：

```bash
grep binder /proc/filesystems
# 期望：nodev	binder
```

出现 `nodev binder` 之后，再去起 redroid。模块方案要写进第 5 节的开机加载。

若现场已经有华为云手机容器（Kbox）给 **openEuler 22.03 / Linux 5.10.0** 的补丁包，用他们编好的 `aosp_binder_linux.ko` 也可以，前提仍是开发包和 `uname -r` 一致。本仓库不附带那些补丁。

---

## 5. 开机自动加载

模块方案在重启后会丢，除非写进开机加载：

```bash
# 若发行版模块名是 binder_linux
echo 'binder_linux' | sudo tee /etc/modules-load.d/binder.conf

# 需要带三个逻辑设备名时，用 modprobe 配置
sudo tee /etc/modprobe.d/binder.conf >/dev/null <<'EOF'
options binder_linux devices=binder,hwbinder,vndbinder
EOF
```

内置进内核（第 3 节 `=y`）的机器不需要这两份文件。重启后再跑一次第 1 节，确认不是「这次手工加载过、下次开机又没了」。

---

## 6. Binder 有了仍起不来：先看安全增强型 Linux

鲲鹏 + openEuler 22 上，已经出现过：`/proc/filesystems` 里有 binder，`/proc/misc` 里也有 ashmem，redroid 仍然起不来。维护者给出的处理是先关掉安全增强型 Linux（SELinux）。

先确认 Binder 已经在，再试：

```bash
getenforce
# 若输出 Enforcing，先在测试机上临时放开：
sudo setenforce 0
getenforce
# 期望：Permissive
```

能起来之后，不要长期停在「整机关闭」。把 `audit.log` 里和 redroid / docker / binder 相关的拒绝记录留下来，再补一条针对性策略。测试床可以先用宽松模式把秒表环境拉起来。

另外：鲲鹏 920 是 64 位专用核，镜像必须用 `*_64only`，不要拉带 32 位客户机的 redroid 镜像。

---

## 7. 和秒表环境怎么接

1. 第 1 节通过：`grep binder /proc/filesystems` 有 `nodev binder`。
2. 第 6 节：测试机上安全增强型 Linux 不再挡住容器。
3. 再执行 [Stopwatch4U8GEnvironment.zh.md](Stopwatch4U8GEnvironment.zh.md) 里的 `scripts/redroid_4u8g_stopwatch/run.sh`。脚本启动前会再查一次 Binder；没有就直接失败，避免容器反复重启却看不出原因。
4. 共享内存继续用脚本里的 `androidboot.use_memfd=true`，不要因为「还没有 ashmem」停住。

现场自检也可以只跑：

```bash
scripts/redroid_4u8g_stopwatch/check_host_binder.sh
```

---

## 8. 明确不要做的事

- 不要去找一个叫 `binder` 的 systemd 服务来「启动」。
- 不要在 5.10 上使用 redroid-modules 的 openEuler 20.03 / 4.19 分支。
- 不要把别的内核版本的 `.ko` 拷过来加载。
- 不要把「宿主机没有 `/dev/binder`」当成失败；看 `/proc/filesystems`。
- 不要把 ashmem 缺失和 Binder 缺失当成同一件事。秒表环境已经改用内存文件描述符。
- 不要在对比「换库之前 / 换库之后」的同一周里顺便换内核。换内核是另一份环境，数字不能和旧基线直接比。
