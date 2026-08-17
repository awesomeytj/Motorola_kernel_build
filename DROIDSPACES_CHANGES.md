# Droidspaces 支持改动记录

本次修改目的：让 `Build Kernel (KernelSU)` 工作流能正常编译，并让编出来的内核支持 **Droidspaces**（Linux 容器运行时）。

目标设备：`Aessd/kernel_motorola_sm8250`（sm8250 "nio"，内核 **4.19，非 GKI**），属于 Droidspaces 官方文档里最简单的配置路径。

---

## 一、修复构建报错

**报错现象**（KernelSU 阶段）：

```
bash: line 1: 404:: command not found
Error: Process completed with exit code 127.
```

这一阶段经历了三个逐步排查出的问题：

**问题 1 — raw URL 限流**：原脚本用 `curl raw.githubusercontent.com/.../setup.sh | bash`。该地址不可靠：先返回 404（默认分支从 `next` 改名为 `stable`），换 `stable` 后又遇到 `429: Too Many Requests`。`curl | bash` 把错误页文本当命令执行，于是报 `404:` / `429: command not found`。
→ 改用 `git clone`（走稳定传输通道，不受 raw URL 限流影响）。

**问题 2 — 浅克隆无 tag**：`git clone --depth=1` 下没有 tag，setup.sh 的 `git describe --tags` 失败，会停在未指定提交上。
→ 改用完整克隆。

**问题 3 — KernelSU 版本与 4.19 不兼容（真正卡住构建的原因）**：Build kernel 阶段报
```
drivers/kernelsu/feature/sucompat.c:7:10: fatal error: 'linux/pgtable.h' file not found
```
`linux/pgtable.h` 是内核 **5.8** 才引入的头文件，4.19 没有。KernelSU-Next v3.x 及其 legacy 系列、tiann/KernelSU v3.x 都无条件 include 了它，因此在 4.19 上必然编译失败。
→ **改用经典 KernelSU（tiann）并锁定到 `v2.1.2`**：本地逐 tag 排查确认，`v2.1.2` 是最后一个不含 `pgtable.h`、带完整版本门控、能在 4.19 编译的稳定版（`v3.0.0` 起引入该头文件）。

**最终改动**（`.github/workflows/Build Kernel (KernelSU).yml`）：

```bash
git clone https://github.com/tiann/KernelSU.git   # 经典 KernelSU，完整克隆
sh KernelSU/kernel/setup.sh v2.1.2                 # 显式锁定 4.19 兼容版本
```

> 本地已在真实内核树副本上验证：v2.1.2 正确检出，symlink / drivers Makefile / Kconfig 均正确接入，`sucompat.c` 无 `pgtable.h` 引用。

**问题 4 — v2.1.2 的 `MODULE_IMPORT_NS` 未对 <5.4 内核做门控**：换到 v2.1.2 后 pgtable.h 问题消失，但 Build kernel 阶段又报
```
drivers/kernelsu/ksu.c:80:18: error: a parameter list without types is only allowed in a function definition
```
对应源码：
```c
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("VFS_internal_..._NOT_a_driver");
#else
MODULE_IMPORT_NS(VFS_internal_..._NOT_a_driver);   // <- 4.19 没有这个宏
#endif
```
`MODULE_IMPORT_NS` 宏是内核 **5.4** 才引入的。v2.1.2 的作者只区分了 6.13+（带引号）和更早（不带引号），没考虑 <5.4 根本没有这个宏——在 4.19 上裸宏无法展开，被当成 K&R 函数声明报错。（已确认该宏在 4.19 内核树中不存在。）
→ 在 workflow 里 clone KernelSU 后用 `sed` 把 `#else` 改成 `#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)`，让这行只在 ≥5.4 的内核上生成，4.19 直接跳过。该宏仅在编成模块（`.ko`）时有意义，此处是 built-in（`CONFIG_KSU=y`），跳过无副作用。本地已验证 sed 精准命中且不破坏代码块结构。

**问题 5 — runner 镜像移除了 `python2` / `libncurses5`**：Setup environment 阶段报
```
E: Package 'python2' has no installation candidate
E: Unable to locate package libncurses5
```
GitHub 的 `ubuntu-22.04` runner 镜像已向 24.04 靠拢，把 `python2` 和 `libncurses5` 移除了（之前能装、现在不行）。经核对本地内核树：
- `python2` 唯一的消费者是 `scripts/gcc-wrapper.py`（Makefile 第 412 行 `CC = $(PYTHON) gcc-wrapper.py $(REAL_CC)`，其中 `REAL_CC=gcc`）。但 `config.env` 传入 `CC=clang`，命令行的 `CC` 覆盖了 Makefile 的赋值，wrapper 根本不会被调用 —— 所以 python2 用不到。
- `libncurses5` 只有交互式 `menuconfig` 需要，CI 用不到。
- `libselinux-dev` 在 24.04 仍可安装，保留。

→ 精简为只装 `libselinux-dev`（并改用 `apt-get install -y`，脚本里更稳定）。

---

## 二、新增 Droidspaces 内核配置

> **关键澄清**：Droidspaces 不是 KernelSU 的功能，而是一个独立的容器运行时（类似 LXC）。KernelSU 只负责提供 root。Droidspaces 需要内核开启一组特定选项（命名空间、cgroups、seccomp、netfilter/NAT、overlayfs 等），原工作流完全没开这些。

**新文件**：`droidspaces.config`（仓库根目录，版本受控）

包含官方要求的**必需**配置片段，针对 4.19 非 GKI 内核标注了各选项在不同内核版本的差异。主要类别：

- IPC 机制：`SYSVIPC`、`POSIX_MQUEUE`
- 核心命名空间（必需）：`NAMESPACES`、`PID_NS`、`UTS_NS`、`IPC_NS`
- Seccomp：`SECCOMP`、`SECCOMP_FILTER`
- 控制组（必需）：`CGROUPS`、`CGROUP_DEVICE`、`CGROUP_PIDS`、`MEMCG` 等
- 设备文件系统（必需）：`DEVTMPFS`
- Overlay 文件系统：`OVERLAY_FS`
- 网络隔离（NAT/none 模式）：`NET_NS`、`VETH`、`BRIDGE`、`NETFILTER`、`NF_NAT` 等
- `CONFIG_ANDROID_PARANOID_NETWORK is not set`（容器联网必需）

**新增工作流步骤** "Add Droidspaces kernel config"：把片段拷进 `kernel-source/arch/arm64/configs/`。

**构建步骤合并**：

```bash
make ${args} nio_defconfig droidspaces.config   # 合并 defconfig + 片段
```

内核构建系统会自动执行 merge_config，随后 `olddefconfig` 解析依赖。4.19 上不存在的符号（在更高版本被重命名/合并）会被 olddefconfig 无害地丢弃。

---

## 三、显式开启 KernelSU

setup.sh 只接好了 `drivers/` 下的 Kconfig 与 Makefile，并不会自动打开 `CONFIG_KSU`。因此新增：

```bash
./scripts/config --file ../out/.config --enable CONFIG_KSU
make ${args} olddefconfig
```

确保 KernelSU 真正编进内核。

---

## 需要注意

- **`CONFIG_ANDROID_PARANOID_NETWORK=n`**：Droidspaces 容器联网必需。会改变 Android 网络栈对 socket 权限的门控行为，自定义内核上通常没问题，但属于行为变更。
- **KernelSU 版本锁定**：使用经典 KernelSU（tiann）`v2.1.2`。这是最后一个兼容 4.19 内核的版本；`v3.0.0` 起引入 `linux/pgtable.h`（内核 5.8+ 才有），无法在 4.19 编译。升级 KernelSU 前请先确认新版是否支持 4.19。
- **本地验证范围**：defconfig + 片段的合并、以及 KernelSU v2.1.2 的 setup 接入均已在本地真实内核树副本上验证。完整交叉编译需在 GitHub Actions 上跑（本地无 Snapdragon-LLVM 工具链）。

---

## 验证方法

1. 在 GitHub Actions 手动触发 `Build Kernel (KernelSU)` 工作流。
2. 构建成功后刷入设备。
3. 打开 Droidspaces app → Settings（齿轮）→ Requirements → Check Requirements，所有必需项应显示绿勾。
   或终端执行：`su -c droidspaces check`

---

## 参考

- [Droidspaces Kernel Configuration](https://github.com/MGHazz/Droidspaces/blob/main/Documentation/Kernel-Configuration.md)
- [KernelSU (tiann)](https://github.com/tiann/KernelSU) · [v2.1.2 setup.sh](https://github.com/tiann/KernelSU/blob/v2.1.2/kernel/setup.sh)
