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
2. **有换内核和重启权限时**：用同一条 openEuler 5.10 源码，把上面四个配置改成 `y`，编出新内核，安装并重启。配置项见第 3.1 节；**鲲鹏 + openEuler 22.03 SP4 / 323 现场已跑通的逐步命令见第 3.2 节**。

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

不要在 `/usr/src` 里 `make`（会弄脏软件包文件，也容易把根分区写满）。工作目录放 `/home`。以正在跑的 `/boot/config-$(uname -r)` 为底，只打开上面四项，编完把 `Image` 打成和发行版一样的 gzip `vmlinuz`，用 `dracut` 生成初始化内存盘，`grubby --copy-default` 加启动项，**默认启动仍指向正在跑的 323**。

之前用 `grubby` 加过、但没编成功或没能启动的试验内核，先只删名字里带 `binder` 的项，不要删正在跑的 323：

```bash
KEEP=/boot/vmlinuz-5.10.0-323.0.0.224.oe2203sp4.aarch64
grubby --set-default "$KEEP"
grubby --info=ALL
ls /boot/vmlinuz-*
# 确认列表后：
bash scripts/redroid_4u8g_stopwatch/remove_old_binder_kernels.sh
```

发行版 `.config` 会要模块签名密钥，`kernel-source` 里没有这份私钥。脚本会在 `/home/kbuild/certs/` 现编一颗一次性密钥。若编译报 `certs/x509.genkey` 不存在，不要重跑整份脚本（会删掉已编好的目标文件）；补上该文件后，只续跑 `make ... Image modules`。

仓库里的 `build_binder_kernel.sh` 已改成离线可跑，不再 `yum` / `curl`。没有外网时，把脚本拷到 `/home/build_binder_kernel.sh`（或在本机用编辑器写入），不要去 GitHub 下。`tmux` 里：

```bash
bash -n /home/build_binder_kernel.sh
bash /home/build_binder_kernel.sh
```

脚本结束且默认启动仍是 323 之后，打开 iBMC 控制台，再把新内核设为默认并重启。失败就在控制台选回 323。重启后再跑第 1 节：`grep binder /proc/filesystems` 必须出现 `nodev binder`。`uname -r` 会带 `binder`，第 4 节的树外模块就不必再加载。

这条路会换内核，影响面最大，但也是 redroid 文档承认的 openEuler 做法。现场若本来就要维护自有内核，优先走这里。**323 上已经跑通的逐步命令以第 3.2 节为准。**

---

## 3.2 现场已跑通：323 重编带 Binder 的内核

对象：openEuler 22.03 LTS-SP4、aarch64、正在跑 `5.10.0-323.0.0.224.oe2203sp4.aarch64`。下面是已经开机进到新内核、`/proc/filesystems` 出现 `nodev binder` 的那一套，按执行顺序列出。树外模块、官网下 `src.rpm`、把未压缩 `Image` 直接当 `vmlinuz`，都不在这条成功路径里。

约定：

| 名字 | 值 | 含义 |
|------|----|------|
| 旧内核 / 回退 | `5.10.0-323.0.0.224.oe2203sp4.aarch64` | 发行版正在跑的内核，全程保留 |
| 源码包目录 | `/usr/src/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64` | `yum` 装的 `kernel-source`，不要在这里 `make` |
| 工作源码 | `/home/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64` | 拷贝出来编，弄脏了可删 |
| 编译输出 | `/home/kbuild` | `O=` 目录，目标文件在这里 |
| 新内核 | `5.10.0-323.0.0.224.oe2203sp4-binder.aarch64` | 发布名必须同时带 `323` 和 `binder` |

整段长时间命令放进 `tmux`。不要把带 `exit` 的脚本贴进登录 shell。`/home` 至少留约 20 吉字节。不要动正在跑的 `kernel` / `kernel-devel`。

### 第 1 步：确认缺的是内核能力

```bash
uname -r
grep binder /proc/filesystems || echo "还没有 binder"
```

- `uname -r`：必须是 `5.10.0-323.0.0.224.oe2203sp4.aarch64`。版本不对不要套用后面的包名。
- `grep binder /proc/filesystems`：没有 `nodev binder` 才需要换内核。已经有了就停，不要重编。

### 第 2 步：从软件源重装同一颗干净源码

现场若在 `/usr/src` 里做过 `make` 或改过 `drivers/android/Makefile`，不要 `yum reinstall`（额外文件删不掉）。

```bash
yum remove -y kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
rm -rf /usr/src/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64
yum install -y kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
rm -rf /home/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64 /home/kbuild
```

- `yum remove`：卸掉已安装的源码包。
- `rm -rf /usr/src/linux-…`：删掉 `make` 留下、包管理器不管的文件。
- `yum install`：再装**同一颗** 323，不要装成别的版本。
- `rm -rf /home/linux-… /home/kbuild`：清掉上次失败的工作副本。

验收：

```bash
rpm --verify kernel-source-5.10.0-323.0.0.224.oe2203sp4.aarch64
ls /usr/src/linux-$(uname -r)/Makefile
ls /usr/src/linux-$(uname -r)/drivers/android/binder.c
head -n 8 /usr/src/linux-$(uname -r)/drivers/android/Makefile
```

- `rpm --verify`：没有输出才干净。
- `Makefile`、`binder.c`：源码树完整。
- Android `Makefile` 必须是 `binder.o binder_alloc.o`，不能再出现 `binder_linux`。

### 第 3 步：开 tmux，把源码拷到 /home

```bash
tmux ls
tmux new -s kbuild
```

- `tmux ls`：看有没有已有会话。
- `tmux new -s kbuild`：新建。已有则 `tmux attach -t kbuild`。
- 离开不停任务：`Ctrl-b` 再按 `d`。

```bash
SRC_PKG=/usr/src/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64
SRC=/home/linux-5.10.0-323.0.0.224.oe2203sp4.aarch64
OUT=/home/kbuild
mkdir -p "$OUT"
if command -v rsync >/dev/null; then
	rsync -a "$SRC_PKG/" "$SRC/"
else
	mkdir -p "$SRC"
	cp -a "$SRC_PKG/." "$SRC/"
fi
```

- 拷到 `/home`：根分区往往被 Docker 占满；也不要在 rpm 拥有的 `/usr/src` 里 `make`。
- 本机 `cp` 若被别成 `cp -i`，覆盖时用 `\cp -f`。

若工作副本里已经有上次 `make` 的痕迹：

```bash
make -C "$SRC" mrproper
```

- 只清 `/home` 这份拷贝，不动 `/usr/src` 里的软件包。

### 第 4 步：版本号只加 -binder

```bash
rm -f "$SRC"/localversion "$SRC"/localversion-*
EV=$(sed -n 's/^EXTRAVERSION[[:space:]]*=[[:space:]]*//p' "$SRC/Makefile" | tr -d '[:space:]')
echo "EXTRAVERSION=$EV"
echo '-binder' > "$SRC/localversion"
```

- openEuler 的 `Makefile` 里 `EXTRAVERSION` 已带 `323.0.0.224.oe2203sp4.aarch64`。
- 再写 `localversion` 为 `-binder`，发布名才会是 `5.10.0-323.0.0.224.oe2203sp4-binder.aarch64`。
- 只写 `-binder`、却把 `EXTRAVERSION` 弄丢，会变成以前那种无法启动的 `5.10.0-binder`。

### 第 5 步：以正在跑的 323 配置为底，只开 Binder

```bash
cp -f /boot/config-5.10.0-323.0.0.224.oe2203sp4.aarch64 "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" --enable ANDROID --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS
"$SRC/scripts/config" --file "$OUT/.config" --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder"
"$SRC/scripts/config" --file "$OUT/.config" --disable ANDROID_BINDER_IPC_SELFTEST
"$SRC/scripts/config" --file "$OUT/.config" --disable GCC_PLUGINS
command -v pahole >/dev/null || "$SRC/scripts/config" --file "$OUT/.config" --disable DEBUG_INFO_BTF
make -C "$SRC" O="$OUT" olddefconfig
```

- `/boot/config-323`：和正在跑的内核对齐，只改 Binder，不从零选配置。
- `ANDROID*`：编进内核镜像（`=y`）。开机即有 binderfs，不必 `modprobe`。
- `GCC_PLUGINS=n`：本机 GCC 插件头文件常和对发行版时不一致，会停在 `(NEW)` 提问或编失败。Binder 不依赖插件。试验内核先关。
- 没有 `pahole` 时关 `DEBUG_INFO_BTF`：否则链接阶段报 BTF 失败。
- `olddefconfig`：其余新符号用默认值，不再一项项问。

若 `make` 仍停在 `GCC plugins (GCC_PLUGINS) [Y/n/?] (NEW)`：输入 `n`，或 `Ctrl-C` 后再跑一遍上面的 `scripts/config --disable GCC_PLUGINS` 和 `olddefconfig`。

### 第 6 步：补模块签名材料

发行版 `.config` 要 `certs/signing_key.pem`，`kernel-source` 不带私钥。

```bash
mkdir -p "$OUT/certs" "$SRC/certs"
cat > "$OUT/certs/x509.genkey" <<'EOF'
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
CN = Build time autogenerated kernel key

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
\cp -f "$OUT/certs/x509.genkey" "$SRC/certs/x509.genkey"
openssl req -new -nodes -utf8 -sha256 -days 36500 -batch -x509 \
	-config "$OUT/certs/x509.genkey" \
	-outform PEM -out "$OUT/certs/signing_key.pem" \
	-keyout "$OUT/certs/signing_key.pem"
grep -E 'CONFIG_SYSTEM_TRUSTED_KEYS|CONFIG_SYSTEM_REVOCATION_KEYS|CONFIG_MODULE_SIG_KEY' "$OUT/.config"
```

- `x509.genkey`：openssl 生成密钥用的模板。缺了会报 `Can't open certs/x509.genkey`。
- `signing_key.pem`：这颗试验内核自己的模块签名密钥。
- 现场成功时这三项是：`MODULE_SIG_KEY="certs/signing_key.pem"`，`SYSTEM_TRUSTED_KEYS=""`，`SYSTEM_REVOCATION_KEYS=""`。若后两项指向不存在的文件，改成空再 `olddefconfig`。

编到一半才发现缺密钥：**不要重跑会 `rm -rf /home/kbuild` 的整份脚本**，只补证书再续 `make`。

### 第 7 步：编译

```bash
make -s -C "$SRC" O="$OUT" kernelrelease
make -C "$SRC" O="$OUT" -j64 Image modules
ls -l "$OUT/arch/arm64/boot/Image"
cat "$OUT/include/config/kernel.release"
grep -E 'CONFIG_ANDROID_BINDER_IPC|CONFIG_ANDROID_BINDERFS' "$OUT/.config"
```

- `kernelrelease`：动手编之前先看发布名。必须带 `323` 和 `binder`。
- `Image modules`：编内核镜像和模块。`O=$OUT` 把产物写到 `/home/kbuild`。
- `-j64`：并行度，可按核数改。不要在源码目录裸 `make`。
- 现场成功时：`Image` 约 35MB；发布名 `5.10.0-323.0.0.224.oe2203sp4-binder.aarch64`；`CONFIG_ANDROID_BINDER_IPC=y`、`CONFIG_ANDROID_BINDERFS=y`。

### 第 8 步：安装，默认启动仍指向 323

```bash
OLD=/boot/vmlinuz-5.10.0-323.0.0.224.oe2203sp4.aarch64
KREL=$(cat "$OUT/include/config/kernel.release")
make -C "$SRC" O="$OUT" modules_install
gzip -9 -c "$OUT/arch/arm64/boot/Image" > /boot/vmlinuz-"$KREL"
chmod 755 /boot/vmlinuz-"$KREL"
file /boot/vmlinuz-"$KREL"
dracut -f --kver "$KREL" /boot/initramfs-"$KREL".img
grubby --remove-kernel=/boot/vmlinuz-"$KREL" 2>/dev/null || true
grubby --add-kernel=/boot/vmlinuz-"$KREL" \
	--title="openEuler ${KREL} (binder gzip)" \
	--initrd=/boot/initramfs-"$KREL".img \
	--copy-default
grubby --set-default "$OLD"
```

- `modules_install`：模块装到 `/lib/modules/$KREL`，并跑 `depmod`。
- `gzip -9 -c Image`：发行版 `vmlinuz` 是 gzip 包着的 `Image`。直接拷未压缩 `Image` 会在 EFIstub 对不上。
- `file`：应看到 `gzip compressed data, was "Image"`。现场新品约 11MB，和 323 的 `vmlinuz` 同一量级。
- `dracut`：按新内核版本生成初始化内存盘。
- `grubby --copy-default`：启动参数（`root=`、`console=` 等）从正在跑的 323 拷过来，避免早期无控制台像挂死。
- `grubby --set-default`：默认仍是旧 323。没打开 iBMC 之前不要改默认。

验收（此时还未重启，`uname -r` 仍是旧的）：

```bash
uname -r
grubby --default-kernel
grubby --info=/boot/vmlinuz-"$KREL"
file /boot/vmlinuz-"$KREL"
ls -l /boot/vmlinuz-"$KREL" "$OLD" /boot/initramfs-"$KREL".img
```

`uname -r` 和默认启动都必须还是 `…323.0.0.224.oe2203sp4.aarch64`。`args` 应和 323 接近。

### 第 9 步：iBMC 里切到新内核并重启

打开 iBMC 能看到 GRUB 之后：

```bash
grubby --set-default /boot/vmlinuz-5.10.0-323.0.0.224.oe2203sp4-binder.aarch64
grubby --default-kernel
reboot
```

- 没有控制台不要 `reboot`。失败就在 GRUB 选回 323。

进来后：

```bash
uname -r
grep binder /proc/filesystems
```

期望：

```text
5.10.0-323.0.0.224.oe2203sp4-binder.aarch64
nodev	binder
```

有 `nodev binder` 就可以去跑 redroid / 秒表脚本。不必再 `insmod` 树外模块。测试机上若 SELinux 仍挡住容器，见第 6 节。

失败回退（在 iBMC 选回 323 之后）：

```bash
grubby --set-default /boot/vmlinuz-5.10.0-323.0.0.224.oe2203sp4.aarch64
```

### 不要做

- 不要在 `/usr/src` 里 `make`。
- 不要把未压缩 `Image` 拷成 `vmlinuz`。
- 不要让发布名变成 `5.10.0-binder`。
- 不要 `yum reinstall kernel-source` 当「恢复干净」（额外文件还在）。
- 不要在编到一半时重跑会清空 `/home/kbuild` 的脚本。
- 不要用 `/boot/vmlinuz-*binder*` 一把删除；会把这颗已成功的 `323-binder` 也删掉。只删没有 `323` 的旧试验项。
- 不要去 GitHub 拉主线 5.10 或 redroid-modules 的 4.19 分支。

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
