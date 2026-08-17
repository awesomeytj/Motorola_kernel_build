# Droidspaces 支持改动记录

本次修改目的：让 `Build Kernel (KernelSU-Next)` 工作流能正常编译，并让编出来的内核支持 **Droidspaces**（Linux 容器运行时）。

目标设备：`Aessd/kernel_motorola_sm8250`（sm8250 "nio"，内核 **4.19，非 GKI**），属于 Droidspaces 官方文档里最简单的配置路径。

---

## 一、修复构建报错

**报错现象**（KernelSU-Next 阶段）：

```
bash: line 1: 404:: command not found
Error: Process completed with exit code 127.
```

**根因**：KernelSU-Next 已将默认分支从 `next` 改名为 `stable`，旧的 setup.sh URL（`refs/heads/next/…`）返回一个 GitHub 404 页面。`curl | bash` 把页面里的 "404: Not Found" 文本当成命令执行，于是报 `404: command not found`。此外 `bash -s next` 传入的 `next` 作为 git tag/commit 也已不存在。

**改动**（`.github/workflows/Build Kernel (KernelSU-Next).yml`）：

| 改动前 | 改动后 |
|--------|--------|
| `.../KernelSU-Next/refs/heads/next/kernel/setup.sh` | `.../KernelSU-Next/stable/kernel/setup.sh` |
| `\| bash -s next` | `\| bash -s`（默认检出最新 tagged release） |

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

确保 KernelSU-Next 真正编进内核。

---

## 需要注意

- **`CONFIG_ANDROID_PARANOID_NETWORK=n`**：Droidspaces 容器联网必需。会改变 Android 网络栈对 socket 权限的门控行为，自定义内核上通常没问题，但属于行为变更。
- **未在本地验证**：受 GitHub 限流影响，未能本地拉取目标内核源码实测合并结果。`make foo_defconfig frag.config` 的合并语法是 Droidspaces 官方文档推荐的标准做法。请在 GitHub Actions 上手动触发验证。
- **KernelSU-Next 版本**：当前用最新 tagged release。如需更可控，可将 setup.sh 参数改为固定 tag，例如 `| bash -s v1.0.x`。

---

## 验证方法

1. 在 GitHub Actions 手动触发 `Build Kernel (KernelSU-Next)` 工作流。
2. 构建成功后刷入设备。
3. 打开 Droidspaces app → Settings（齿轮）→ Requirements → Check Requirements，所有必需项应显示绿勾。
   或终端执行：`su -c droidspaces check`

---

## 参考

- [Droidspaces Kernel Configuration](https://github.com/MGHazz/Droidspaces/blob/main/Documentation/Kernel-Configuration.md)
- [KernelSU-Next setup.sh](https://github.com/rifsxd/KernelSU-Next/blob/stable/kernel/setup.sh)
