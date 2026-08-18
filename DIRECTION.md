# 工作方向决定：先纯 Droidspaces，后 KernelSU

日期：2026-08-18

---

## 一句话结论

**先产出一个能用的纯 Droidspaces 内核**（不含 KernelSU），验证容器功能跑通；**KernelSU（root）作为独立的后续任务**处理。

---

## 为什么这样决定

目标设备 `Aessd/kernel_motorola_sm8250`（sm8250 "nio"，Moto EdgeS/G100）是 **内核 4.19.157，非 GKI**。

Droidspaces 侧非常顺利：它对 4.19 非 GKI 是官方文档里最简单的路径，只需合并一个配置片段，且合并结果已在本地真实内核树上验证通过（详见 [DROIDSPACES_CHANGES.md](DROIDSPACES_CHANGES.md) 问题 1–6）。

KernelSU 侧则是持续的版本兼容拉锯。KernelSU 近年主要面向 GKI（5.10+）内核，对 4.19 的支持已实质性退化：

- 最新版（KernelSU-Next v3.3.0、tiann v3.x）无条件 `#include <linux/pgtable.h>` —— 该头文件内核 5.8 才有，4.19 直接编不过。
- 退到 **tiann v2.1.2**（逐 tag 排查确认的最后一个不含该头文件的版本）后，又暴露出至少四类 4.19 API 差异，分布在 6 个源文件。
- 其中 **`path_umount` 在 4.19 上没有可用替代**（该符号内核 5.9 引入，4.19 内核未导出任何等价物）。它服务于 KernelSU 隐藏 root 挂载点的功能。

继续攻下去，本质上是**把 KernelSU v2.1.2 手工移植到 4.19**，而不是配置一次构建。这与"编译一个支持 Droidspaces 的内核"这个原始目标已经脱节。

关键认知：**Droidspaces 不是 KernelSU 的功能**。Droidspaces 是独立的 Linux 容器运行时（类似 LXC），只要求内核开启一组特定选项；KernelSU 只是 root 方案之一。两者解耦，因此可以先交付前者。

---

## 当前进展

### Droidspaces 侧：就绪

`droidspaces.config` 已就位并验证。工作流 **Build Kernel (nio, Droidspaces, no KernelSU)** 已具备全部已验证修复，可直接触发。

配置合并的本地验证结果（对真实 `nio_defconfig`）：

- `CONFIG_ANDROID_PARANOID_NETWORK` 成功从 `=y` 覆盖为关闭 —— 容器联网的关键一条
- 命名空间（PID/UTS/IPC/NET）、cgroups、seccomp、VETH/BRIDGE、OverlayFS、devtmpfs、NF_NAT 全部正确进入合并结果

### KernelSU 侧：已解决 4 项，剩 2 项

工作流 **Build Kernel (KernelSU)** 保留，并已打上全部已攻克的补丁。

| 问题 | 状态 |
|---|---|
| `pgtable.h`（5.8+） | ✅ 锁定 tiann v2.1.2 |
| `MODULE_IMPORT_NS`（5.4+） | ✅ 版本门控 sed |
| `put_task_struct` 缺 include | ✅ 补 `<linux/sched/task.h>` |
| `TWA_RESUME`（5.8+，4 个文件） | ✅ `allowlist.h` 共享头兼容宏 |
| `struct seccomp.filter_count`（5.9+） | ✅ 版本门控 sed |
| `strncpy_from_user_nofault`（5.8+，3 文件 8 处） | ⬜ 待做：可改名为 4.19 的 `strncpy_from_unsafe_user`（签名一致） |
| `path_umount`（5.9+） | ❌ **卡点**：4.19 无替代 |

---

## 后续 KernelSU 的三条可选路径

若日后要继续攻 root，按代价从低到高：

1. **禁用依赖 `path_umount` 的功能** —— 该符号只被 `kernel_umount.c` 使用（KernelSU 卸载/隐藏挂载点，用于对抗 root 检测）。若不需要隐藏 root，可用 `#if` 门控掉整个 `ksu_umount_mnt` 路径。代价：失去隐藏能力，核心 root 功能保留。这是最现实的一条。

2. **改用更老的 KernelSU v1.x** —— 例如 v1.0.9。那个时期代码带 `kernel_compat` 兼容层、有 <5.8 的版本门控，对 4.19 适配得多。代价：功能较旧。

3. **换非 KernelSU 的 root 方案** —— 例如 Magisk（不需要改内核）。Droidspaces 只要求"有 root"，不限定来源。这也是当前纯 Droidspaces 内核的配套建议。

---

## 验收标准

刷入纯 Droidspaces 内核后，在 Droidspaces app 里 Settings（齿轮）→ Requirements → Check Requirements：

- **应当为绿**：PID/MNT/UTS/IPC 命名空间、cgroup device、devtmpfs、OverlayFS、网络命名空间、VETH/Bridge、seccomp、PTY/devpts、loop device、ext4
- **预期为红**：Root access —— 纯内核不提供 root，需另配 root 方案后才通过

即：这次内核改动要验证的是那些**内核能力项**，Root 一项的红色是预期结果，不代表构建失败。
