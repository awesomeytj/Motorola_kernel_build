# nio (XT2125-4) — Droidspaces 内核 + Magisk root 落地记录

日期：2026-08-18
设备：Motorola Edge S / Moto G100，代号 **nio**，SoC **sm8250**
内核：**Linux 4.19.157，非 GKI**
系统：Android 12，原厂固件 `RETCN S1RN32.55-16-13`

---

## 一句话结论

**目标达成。** 最终状态 = **Droidspaces 内核 + Magisk root**，Droidspaces v6.5.0 系统需求检查全绿。

关键路线（用了三步，验证成功）：

1. 从**原厂固件**提取干净 `boot.img`（内核 4.19.157，无 KSU）。
2. 手机 Magisk App 修补该原厂 boot → 刷入 → 正常开机、拿到 Magisk root。
3. kernel flasher 刷 Droidspaces 的 AnyKernel3（只换内核 Image、保留 Magisk ramdisk）→ Droidspaces 内核 + Magisk root 共存。

---

## 为什么是这条路（踩过的坑）

- **root 不能靠内核里的 KSU**：目标 Droidspaces 内核不含 KernelSU；KSU 在 4.19 非 GKI 上移植受阻（`path_umount` 等，详见 [DIRECTION.md](DIRECTION.md)）。
- **内置 KSU 的内核 + Magisk 会 bootloop**：曾拿一个内核内置 KernelSU 的 boot 给 Magisk 修补，内核里的 KSU 与 ramdisk 里的 Magisk 在早期 init 打架，无限重启。教训：Magisk 底座的内核必须不含 KSU。
- **正解 = 干净原厂 boot 做 Magisk 底座**：内核无 KSU，Magisk 单独接管 ramdisk，不冲突；内核之后由 AnyKernel3 换成 Droidspaces。root 与内核彻底解耦。

---

## Droidspaces v6.5.0 检查结果

- MUST HAVE：全部 [✓]（root、各 namespace、pivot_root、seccomp 等）
- RECOMMENDED：全部 [✓]（cgroup v2、devtmpfs、loop、ext4 等）
- OPTIONAL：仅 **User namespace [✗]**（`CONFIG_USER_NS` 未开；Docker/Flatpak/沙盒浏览器等才需要，核心功能不受影响）
- 汇总：**All required features found!**

> 如需 User namespace：在 `droidspaces.config` 加 `CONFIG_USER_NS=y` 重编内核；或按 Droidspaces 提示对单个容器用 `--allow-userns`。

---

## 现有镜像 / 资源清单

放置目录：`/home/qwerty/code/Motorola_kernel_build/`

| 文件 | 大小 | MD5 | 说明 / 用途 |
|---|---|---|---|
| `AnyKernel3_droidspaces_nokernelsu1.zip` | 21,513,003 B | `8c6f7887ce60c2e90659dc826400d805` | **本次目标产物**。我们编的 Droidspaces 内核（无 KSU），AnyKernel3 包。第 3 步用 kernel flasher 刷它换内核。原名带空格的 `(1).zip` 曾因手机端解压 I/O error，改无空格名后成功。 |
| `stock_boot/boot.img` | 100,663,296 B | `58a18a9cddfa2ca18016668087a275e5` | **干净原厂 boot**，内核 4.19.157-perf+，无 KSU。从原厂固件提取。Magisk 修补的底座；也是终极救砖底座。 |
| `magisk_fix_boot/magisk_patched-30700_Sd4Ar.img` | 100,663,296 B | `5dd81d5afb70502abfaffccdd91ce681` | 上面原厂 boot 经 **Magisk App 修补**后的镜像。刷入后正常开机 + Magisk root。**已验证能开机的救砖底座，勿删。** |
| `XT2125-4_..._S1RN32.55-16-13_...CFC.xml.zip` | 3,975,311,269 B | `605535d2c77a5277eee7cfa0abf835b3` | **原厂固件全包**（RETCN, Android 12, S1RN32.55-16-13）。含 boot/vendor_boot/dtbo/super 等。原厂 boot.img 由此提取。 |

### 固件包内主要分区镜像
`boot.img`(100M)、`vendor_boot.img`(64M)、`dtbo.img`(24M)、`vbmeta.img`、`vbmeta_system.img`、`bootloader.img`、`super.img_sparsechunk.0~11`(约 5.7G，system/vendor/product 等逻辑分区)、`flashfile.xml`、`servicefile.xml`。

### 原厂固件下载

来源：lolinet 镜像站（lenomola / nio_retcn / RETCN）。约 3.98 GB。

```
https://mirrors-obs-1.lolinet.com/firmware/lenomola/2021/nio_retcn/official/RETCN/XT2125-4_NIO_RETCN_12_S1RN32.55-16-13_subsidy-DEFAULT_regulatory-DEFAULT_CFC.xml.zip
```

下载脚本：仓库内 `download_firmware.sh`（带断点续传 `-C -`、自动重试、下完校验 zip 完整性）。中断后重跑同一脚本会接着下。

```
./download_firmware.sh
# 或手动：
curl -L -C - --retry 5 --progress-bar -O \
  "https://mirrors-obs-1.lolinet.com/firmware/lenomola/2021/nio_retcn/official/RETCN/XT2125-4_NIO_RETCN_12_S1RN32.55-16-13_subsidy-DEFAULT_regulatory-DEFAULT_CFC.xml.zip"
```

下完校验：`md5 = 605535d2c77a5277eee7cfa0abf835b3`，大小 `3,975,311,269` B。

---

## 复现 / 恢复操作

### 从零复现最终状态
```
# 1. 提取原厂 boot（若 stock_boot/ 已在可跳过）
unzip -o XT2125-4_*.zip boot.img -d stock_boot

# 2. 手机 Magisk App → 安装 → 选择并修补 stock_boot/boot.img
#    生成 magisk_patched-xxxxx.img，拷回电脑

# 3. 刷入 Magisk boot
adb reboot bootloader
fastboot flash boot magisk_fix_boot/magisk_patched-30700_Sd4Ar.img
fastboot reboot

# 4. 开机确认 Magisk root 后，用 kernel flasher 刷 Droidspaces 内核到 slot a
#    AnyKernel3_droidspaces_nokernelsu1.zip
```

### 验证
```
adb shell uname -a          # 应含 KBUILD_BUILD_USER=hiahia（我们编的 Droidspaces 内核）
                            # 原厂为 nobody@android-build
# Magisk App 显示已安装；Droidspaces App 需求检查全绿
```

### 救砖后路（任选其一，进 fastboot 刷）
```
fastboot flash boot magisk_fix_boot/magisk_patched-30700_Sd4Ar.img  # 回到 Magisk root（原厂内核）
fastboot flash boot stock_boot/boot.img                             # 回到纯原厂（无 root）
```

---

## 构建相关

- 工作流：`.github/workflows/build_kernel-NoKernelSU.yml`
- 内核源：`Aessd/kernel_motorola_sm8250` 分支 `erofs`（见 `config.env`）
- 配置合并：`nio_defconfig` + `droidspaces.config`
- AnyKernel3 配置：仓库内 `anykernel.sh`（`device.name1=nio`, `do.devicecheck=1`, `BLOCK=boot`, `IS_SLOT_DEVICE=1`），构建时覆盖 osm0sis 默认模板——否则刷机报 "Unsupported device"。

## 后续可选项

- 开 User namespace：`droidspaces.config` 加 `CONFIG_USER_NS=y` 重编。
- KSU + Droidspaces 单内核方案：需把 Droidspaces config 叠到带 KSU 的内核源码上重编（见 [DIRECTION.md](DIRECTION.md) 路线讨论），目前 Magisk 方案已满足 root 需求。

