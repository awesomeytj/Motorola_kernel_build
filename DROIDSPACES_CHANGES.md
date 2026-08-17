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
