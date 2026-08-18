# 接手指南

给接手这个 GitHub Actions 内核构建项目的人。目标：让你在 10 分钟内知道该跑什么、坑在哪、结论有哪些。

---

## 1. 这个项目在做什么

用 GitHub Actions 交叉编译 **Motorola EdgeS / G100（代号 nio，骁龙 sm8250）** 的 Android 内核，产出可用 TWRP/OrangeFox 刷入的 AnyKernel3 包。

当前目标：让内核支持 **Droidspaces**（一个 LXC 类的 Linux 容器运行时），可选叠加 **KernelSU**（root）。

**关键前提认知：Droidspaces 与 KernelSU 是两件独立的事。** Droidspaces 只要求内核开启一组配置（命名空间、cgroups、seccomp、netfilter/NAT、OverlayFS 等）+ 系统里有 root；KernelSU 只是 root 方案之一。别把 Droidspaces 当成 KernelSU 的功能——这是本项目早期走过的弯路。

---

## 2. 关键事实（不要重新踩坑）

| 项 | 值 |
|---|---|
| 设备 | Motorola EdgeS / G100，代号 **nio**，SoC sm8250 |
| 内核源码 | `https://github.com/Aessd/kernel_motorola_sm8250.git` 分支 `erofs` |
| 内核版本 | **4.19.157，非 GKI** |
| defconfig | `arch/arm64/configs/nio_defconfig` |
| 驱动目录布局 | `drivers/`（**不是** `common/drivers/`） |
| 编译器 | 预编译 Snapdragon-LLVM clang（`CC=clang`） |
| Runner | `ubuntu-22.04`（实际镜像已向 24.04 靠拢，见坑 #2） |
| 完整构建耗时 | 约 12–15 分钟 |

"4.19 非 GKI" 是理解一切问题的钥匙：Droidspaces 因此走最简单路径，KernelSU 因此处处碰壁。

---

## 3. 该跑哪个工作流

仓库里有三个，**只有一个是当前推荐的**：

| 工作流文件 | 状态 | 说明 |
|---|---|---|
| `build_kernel-NoKernelSU.yml`<br>→ *Build Kernel (nio, Droidspaces, no KernelSU)* | ✅ **推荐，先跑这个** | 纯 Droidspaces 内核。含全部已验证修复。产物 artifact：`AnyKernel3_droidspaces_nokernelsu` |
| `Build Kernel (KernelSU).yml`<br>→ *Build Kernel (KernelSU)* | ⚠️ 已修 4 项，仍失败 | 卡在 `path_umount`（4.19 无此符号）。保留是为了不丢失进度 |
| `build-kernel.yml`<br>→ *Build Kernel* | ❌ **过时，别用** | 仍用失效的 `curl raw.githubusercontent.com \| bash`（会被限流）+ 已被移除的 `python2`/`libncurses5`。是历史遗留 |

三个都是 `workflow_dispatch`（只能手动触发），在 GitHub 网页 Actions 页面点 Run workflow。

---

## 4. 六个已踩过的坑（省你几小时）

### 坑 1：`curl raw.githubusercontent.com/... | bash` 不可靠
raw 域名会限流，返回 **404/429 错误页**，而错误页文本被 `bash` 当命令执行，报出 `404: command not found` 这类离谱错误。

→ **一律改用 `git clone`**（走不同的、稳定的传输通道），再从本地磁盘执行脚本。且要**完整克隆**，不能 `--depth=1`——浅克隆没有 tag，KernelSU 的 `setup.sh` 里 `git describe --tags` 会失败。

### 坑 2：runner 镜像已移除 `python2` / `libncurses5` / `libtinfo5`
`ubuntu-22.04` 标签的实际镜像向 24.04 迁移（ncurses 5 → 6），这三个包装不上。

- **`python2` 确实不需要**：唯一消费者是内核的 `scripts/gcc-wrapper.py`（Makefile 里 `CC = $(PYTHON) gcc-wrapper.py $(REAL_CC)`，`REAL_CC=gcc`），但命令行传入的 `CC=clang` 覆盖了该赋值，wrapper 根本不被调用。
- **`libncurses5` / `libtinfo5` 必须要**（别学早期的我判断成"只给 menuconfig 用"）：预编译的 Snapdragon-LLVM clang 动态链接 `libtinfo.so.5`，缺了会报 `clang: error while loading shared libraries: libtinfo.so.5`。

→ 从 Ubuntu pool 直接下 deb 装。**文件名在运行时动态解析**，别写死版本号（pool 会清理旧版导致 404）：
```bash
POOL="http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses"
for pkg in libtinfo5 libncurses5; do
  deb=$(curl -sSL "$POOL/" | grep -oE "${pkg}_[^\"]*_amd64\.deb" | sort -V | tail -n1)
  curl -sSLO "$POOL/$deb"
done
sudo dpkg -i libtinfo5_*_amd64.deb libncurses5_*_amd64.deb
```

### 坑 3：`config.env` 里 `BUILD_ARGS` 用的是冒号
```
BUILD_ARGS:CC=clang     # ← 冒号，不是等号！其他行都是等号
```
所以工作流里它用 `cut -d ":" -f 2` 解析，其他变量用 `cut -d "=" -f 2`。改这个文件时注意别"顺手修正"成等号，会让解析拿到空值。

### 坑 4：真正的编译错误藏在日志中间，不在末尾
并行编译（`make -j`）下，报错后其他任务还在继续输出，所以**日志末尾只有无关的 `AR`/`CC` 行**。别只看 tail。

→ 这样定位：
```bash
grep -niE "error:|fatal|implicit declaration|undefined" <log> | grep -vi warning
```

### 坑 5：KernelSU 新版本全部不兼容 4.19
KernelSU 已转向 GKI（5.10+）。**KernelSU-Next v3.3.0、tiann v3.x 都无条件 `#include <linux/pgtable.h>`**（内核 5.8 才有的头），4.19 必然编译失败。`-legacy` 系列也一样。

→ tiann **v2.1.2** 是逐 tag 排查确认的最后一个能在 4.19 编译的版本（`v3.0.0` 起引入该头文件）。用 `sh KernelSU/kernel/setup.sh v2.1.2` 显式锁定。

### 坑 6：sed 补丁要注意 tab 缩进
KernelSU 源码里部分文件用 **tab** 缩进（`ksud.c`、`app_profile.c`），部分用空格。`sed 's@^\( *\)...'` 只匹配空格会静默失效。

→ 用 `^\([[:space:]]*\)` 兼容两者。改完务必验证匹配数（`grep -c`），别假定成功。

---

## 5. 已确立的方法论

这次排查中被证明有效的做法，建议延续：

**在真实内核树上本地验证，别靠推断。** 克隆一份内核源码到本地（本项目用 `/home/qwerty/code/kernel_motorola_sm8250`），拿它核对 API 是否存在：
```bash
# 某符号 4.19 有没有？
grep -rw "filter_count" $KERNEL/include/
# 某函数签名是什么？
grep -n "int task_work_add" $KERNEL/include/linux/task_work.h
```
这比"改一版 → 推 → 等 12 分钟 → 看日志"快一个数量级。

**配置合并可以本地验证**（不需要交叉编译工具链）：
```bash
bash $KERNEL/scripts/kconfig/merge_config.sh -m -O /tmp/out \
  $KERNEL/arch/arm64/configs/nio_defconfig droidspaces.config
grep -E "^(CONFIG_X=|# CONFIG_X is not set)" /tmp/out/.config
```
注意本机可能缺 `bison`/`python`，跑不了完整的 `make nio_defconfig`，但 `merge_config.sh -m` 是纯文本合并，够用。

**别逐个试错，做前瞻扫描。** 与其一轮修一个错误，不如一次性列出所有可能缺失的符号并批量核对——这次靠它一次发现 `TWA_RESUME` 其实有 4 个调用点（而不是报错提示的 1 个），省了三轮往返。

**优先在共享头文件加兼容宏，而非逐行打补丁。** 例：`TWA_RESUME` 的 4 个调用点形式各异（赋值 / 在 `if` 内 / 缩进不同），逐行包裹 `#if` 很脆弱；在它们共同包含的 `allowlist.h` 里定义一次 `#define TWA_RESUME true` 就全部解决。

---

## 6. 文件地图

| 文件 | 作用 |
|---|---|
| `config.env` | 内核源码地址/分支、defconfig 名、构建参数。**注意坑 #3** |
| `droidspaces.config` | Droidspaces 所需的内核配置片段（官方必需项，已针对 4.19 标注版本差异）。构建时拷入 `arch/arm64/configs/` 并与 defconfig 合并 |
| `.github/workflows/*.yml` | 三个工作流，见第 3 节 |
| `DIRECTION.md` | **当前工作方向决策**：为何先做纯 Droidspaces、KernelSU 剩余卡点、后续三条路径 |
| `DROIDSPACES_CHANGES.md` | **完整排查日志**：8 个问题的现象、根因、修法，逐个可追溯 |
| `HANDOVER.md` | 本文件 |
| `rawlog*.txt` / `build-kernel*.txt` | 构建日志（未纳入版本控制，可随时删） |

---

## 7. 外部资源

- [Droidspaces 内核配置官方文档](https://github.com/MGHazz/Droidspaces/blob/main/Documentation/Kernel-Configuration.md) —— 配置片段的权威来源，含 GKI/非 GKI 区别说明
- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) —— 运行时本体
- [tiann/KernelSU](https://github.com/tiann/KernelSU) —— 经典 KernelSU（本项目锁定 v2.1.2）
- [rifsxd/KernelSU-Next](https://github.com/rifsxd/KernelSU-Next) —— 默认分支是 `stable`（不是 `next`，早期文档已过时）
- [Android Kernel Tutorials](https://github.com/ravindu644/Android-Kernel-Tutorials) —— 内核编译入门
- [Ubuntu ncurses pool](http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/) —— 坑 #2 的 deb 下载源
- [Droidspaces Telegram](https://t.me/Droidspaces) —— 内核相关问题支持

---

## 8. 下一步该做什么

1. **触发 Build Kernel (nio, Droidspaces, no KernelSU)**，拿到 artifact。
2. 刷入设备，在 Droidspaces app 里 Settings → Requirements → **Check Requirements**。
   - 内核能力项（命名空间、cgroups、devtmpfs、OverlayFS、VETH/Bridge…）应为绿
   - **Root access 预期为红** —— 纯内核不带 root，需另配（如 Magisk）。这不是构建失败
3. 若容器功能验证通过，再按 `DIRECTION.md` 第「后续三条路径」决定 root 方案。

> 提醒：`CONFIG_ANDROID_PARANOID_NETWORK` 被本项目从 `=y` 改为关闭（Droidspaces 容器联网必需）。这会改变 Android 网络栈对 socket 权限的门控行为，自定义内核上通常没问题，但属于行为变更，遇到网络异常时记得它。
