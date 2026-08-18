# 开启 User namespace —— 构建脚本变更说明

日期：2026-08-19
设备：nio (XT2125-4)，sm8250，Linux 4.19.157 非 GKI
背景：Droidspaces v6.5.0 需求检查中唯一未通过的 OPTIONAL 项是
**User namespace [✗]**（`CONFIG_USER_NS` 未开）。Docker / Flatpak /
沙盒浏览器等场景需要它。本次变更目的：在内核里打开 User namespace，
并让构建结果可被核对。

> 注：`FLASHING_RESULT.md` 保持原样未动，本变更单独记于此文档。

---

## 一、变更清单

| 文件 | 变更 | 目的 |
|---|---|---|
| `droidspaces.config` | 新增 `CONFIG_USER_NS=y` | 打开 User namespace |
| `droidspaces.config` | 新增 `CONFIG_IKCONFIG=y` / `CONFIG_IKCONFIG_PROC=y` | 让设备端有 `/proc/config.gz`，可随时核对内核配置 |
| `.github/workflows/build_kernel-NoKernelSU.yml` | 新增 "Verify Droidspaces config" 步骤 | 编译后打印 `out/.config` 中关键符号是否被 olddefconfig 保留 |
| `.github/workflows/build_kernel-NoKernelSU.yml` | 新增 "Upload resolved .config to artifact" 步骤 | 把定稿 `.config` 传成 artifact 离线留档 |

---

## 二、config 片段变更

`droidspaces.config` 的核心 namespace 段之后新增：

```
# User namespace (Docker/Flatpak/沙盒浏览器等; --allow-userns) - OPTIONAL
CONFIG_USER_NS=y

# Kernel config accessible at runtime via /proc/config.gz (方便设备端核对配置)
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
```

这些符号在 build 时经 `merge_config` 并入 `nio_defconfig`，再由
`olddefconfig` 解析依赖。`CONFIG_USER_NS` 依赖 `CONFIG_NAMESPACES=y`
（已开），4.19 上无冲突，理论上会保留。

---

## 三、workflow 变更

### 1. 编译后校验（Verify Droidspaces config）

位于 "Build kernel" 之后。读取构建产物 `out/.config`
（`O=../out` 从 `kernel-source` 看即仓库根的 `out/`），逐个检查
`USER_NS / IKCONFIG / IKCONFIG_PROC / NAMESPACES`，日志打印
`[OK]` 或 `[MISS]`；若有符号被反选，抛一条 `::warning::`。
**只做可见性，不影响构建成败。**

### 2. 上传 .config（Upload resolved .config to artifact）

把 `out/.config` 传成名为 `kernel_config_droidspaces` 的 artifact，
`if-no-files-found: warn`。下载即得经 merge_config + olddefconfig
定稿的配置，可离线核对留档。

---

## 四、验证方式（三选一/可叠加）

1. **构建时**：看 workflow "Verify Droidspaces config" 日志，期望
   `[OK] CONFIG_USER_NS=y`；或下载 `kernel_config_droidspaces` artifact
   自行 `grep CONFIG_USER_NS`。
2. **设备端**：刷入后
   ```
   adb shell "zcat /proc/config.gz | grep USER_NS"
   ```
   （本次已开 IKCONFIG，故 `/proc/config.gz` 存在。）
3. **运行时实测**：
   ```
   adb shell "unshare -Ur id"
   ```
   成功显示 `uid=0(root) ...`。失败多为 SELinux 策略或
   `kernel.unprivileged_userns_clone` 等运行时限制，属策略问题，
   非编译未开。

---

## 五、注意事项

- sm8250 这类 Android 内核即便 `CONFIG_USER_NS=y`，运行时也可能被
  SELinux 策略限制，方式 3 的结果可能与方式 1/2 不一致。
- 若日志出现 `[MISS] CONFIG_USER_NS`，说明该符号被 olddefconfig
  反选，需检查 `nio_defconfig` 是否有显式 `# CONFIG_USER_NS is not set`
  或其依赖被关闭。
