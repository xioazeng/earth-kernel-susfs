# Redmi 12C / Poco C55 (earth / MT6768) 内核编译套件

**KernelSU-Next（legacy / 非 GKI 分支）+ SUSFS + Droidspaces** ｜ 基于 LineageOS 源码树 ｜ 云端编译，产出可直接刷入的 `boot.img`

> 📖 零基础走一遍：直接看第 3 节「使用步骤（云端编译）」和下面这段总结。
>
> 本文件是技术参考（原理、风险、参数调整）。

---

## 快速开始（4 步）

1. **建仓库**：新建 GitHub 仓库，把 `.github/`、`configs/`、`patches/`、`scripts/`、
   `.gitattributes`、`README.md` 上传到仓库根目录。
2. **给 boot.img 直链**（想要可直接刷的 `boot.img` 才需要）：
   把 `E:\Chormedownload\earth_global_images_V14.0.7.0.TCVMIXM_13.0\images\boot.img`
   上传到一个 Release，复制附件下载直链。
3. **跑 workflow**：`Actions` → 选本 workflow → `Run workflow`，
   `stock_boot_img_url` 填上面的直链。
4. **下载产物**：`earth-boot-img` → `earth-boot-new.img`，然后
   `fastboot flash boot_a/boot_b`。

> **如果失败了**：把 `earth-build-logs` 里的 `setup.log` 和 `build.log` 发我。
> 首次编译这类三方补丁组合通常需要 1–2 轮适配，我改脚本、你重跑即可。

---

## 1. 先说清楚三件事

### 1.1 你的设备信息（已核实）

| 项目 | 值 |
|---|---|
| 机型 | Redmi 12C / Poco C55，代号 `earth` |
| SoC | MediaTek MT6768 (Helio G85) |
| 内核版本 | **Linux 4.19**（LineageOS 官方 wiki 确认 `version: '4.19'`） |
| 你的固件 | `V14.0.7.0.TCVMIXM`（MIUI 14 / Android 13） |
| 分区 | A/B 机型，内核在 `boot` 分区 |
| 基线源码 | `LineageOS/android_kernel_xiaomi_earth` 分支 `lineage-21` |

> **重要更正：** 我最初提到过 `lineage-20`。实际上 LineageOS 为 `earth` **没有** lineage-20 分支，
> 最低就是 `lineage-21`。已核实 `lineage-21` 依然是 **Linux 4.19**，与你的官方固件内核线一致，
> 所以它就是正确的基线。（LineageOS 21 虽然是 Android 14，但对 MTK 4.19 内核来说，
> 内核本身与 Android 13 的 vendor 分区是可以配套工作的——见第 6 节的风险说明。）

### 1.2 为什么是这种方案（KernelSU-Next 在 4.19 上的关键细节）

这一点决定了整个方案能不能编译成功，值得单独说明：

- **KernelSU-Next 主线的发行版（`v3.4.x` 标签）在本树上编译不过**，实测报错：
  ```
  ../drivers/kernelsu/feature/sucompat.c:8:10: fatal error:
  'linux/pgtable.h' file not found
  ```
  原因不是配置问题，而是源码本身调用了 4.19 里根本不存在的接口：
  `linux/pgtable.h`（5.8 才有）、`strncpy_from_user_nofault()`（5.8）、
  `TWA_RESUME`（5.8）、`user_stack_pointer()`（arm64 5.10 才有）。
  这些是 GKI/新内核的写法。
- 所以本套件使用 KernelSU-Next 的 **`legacy` 分支**（同代 KernelSU-Next 的
  非 GKI 移植，自带 `kernel/compat/`：TWA_RESUME、nofault 拷贝、
  `path_mount/path_umount` 兼容层，并把 `linux/pgtable.h` 用版本宏包住）。
  `v3.4.0-legacy` 这类标签也可以用，并且可以固定到具体 commit。
- `legacy` 分支仍有一处空缺：**arm64 4.19 没有 `user_stack_pointer()`**，
  而 `include/linux/ptrace.h` 的 `current_user_stack_pointer()` 正是基于它定义的，
  `feature/sucompat.c`、`feature/adb_root.c` 都在用。
  `setup-kernel.sh` 会先检查内核树里到底有没有这个函数，确认没有才注入一个
  arm64 兼容实现（优先复用内核自带的 `GET_USP()`，保证 32 位 compat 进程的栈指针也对）。
- 钩子方式可选：默认 `kprobe`（kprobe + tracepoint，官方对非 GKI 的推荐做法），
  如果这台设备上 kprobe 有问题（表现为刷完卡开机），把工作流输入
  `ksu_hook` 改成 `syscall_table`（直接改 `sys_call_table`，不需要 kprobe）。
- 主线 **KernelSU-Next 的 `kernel/susfs/` 目录是 GKI/LKM 模式的实现**，
  依赖 GKI 的符号解析与模块加载机制，**4.19 非 GKI 内核用不了**；
  4.19 必须走 SUSFS 官方的 **`kernel-4.19` 分支**静态补丁路线。
- 而 SUSFS 官方 `kernel-4.19` 分支的 KSU 侧胶水补丁是针对 **旧版 KernelSU
  的文件布局**（`kernel/core_hook.c`、`kernel/allowlist.c`、`kernel/apk_sign.c` …）写的，
  KernelSU-Next 新布局（`kernel/core/`、`kernel/hook/`、`kernel/policy/` …）与它不一致，
  所以 SUSFS 目前默认关闭（`susfs_enable=0`），先把 KernelSU 根跑通。

### 1.3 关于上次「Android 系统出现问题」和 fpsgo 刷屏

你之前的树里混入了大量 **Android 16 的提交**。把新内核代码硬塞进 4.19 老树，
很容易造成驱动或结构体 ABI 不一致，典型症状就是某个驱动初始化失败后无限重试——
fpsgo（`CONFIG_MTK_FPSGO_V3`，MTK 的帧率调度器）刷了 5000+ 条警告正是这个模式：
**驱动反复重试 → 拖死 system_server → 开机卡在「Android 系统出现问题」**。

本套件的规避做法：

1. **基线是干净的 LineageOS `lineage-21`**，不含任何 Android 16 混合提交。
2. **只做加法**：只应用 KSU / SUSFS / Droidspaces 三种补丁，不改动 fpsgo 及其依赖。
3. **配置只做追加**：通过 fragment 合并，`CONFIG_MTK_FPSGO_V3=y` 等 MTK 配置原样保留。
4. **关闭 `CONFIG_LOCALVERSION_AUTO`**：避免每次构建因 git 哈希变化而改变
   vermagic，导致 MTK 预编译 vendor 模块拒绝加载（这是另一个常见的开机故障源）。
   `CONFIG_LOCALVERSION="-perf"` 原样保留，尽量贴近原厂版本字符串。
5. **每次构建都打印内核版本指纹**，方便和原厂 `boot.img` 对比。

---

## 2. 套件内容

```
earth-kernel-build/
├── .github/workflows/build-kernel.yml   # GitHub Actions 云端编译流程
├── configs/
│   └── earth-droidspaces.fragment       # Droidspaces 所需内核开关（非 GKI 版）
├── patches/
│   ├── 01.fix_kernel_panic_in_xt_qtaguid.patch
│   └── 02.fix_restore_cgroup_file_prefix_handling.patch
├── scripts/
│   ├── setup-kernel.sh                  # 注入 KSU-Next + SUSFS + Droidspaces
│   ├── build.sh                         # 配置 + 编译 + 收集产物
│   └── repack-bootimg.sh                # 用 magiskboot 替换 stock boot.img 里的内核
└── README.md
```

**Droidspaces 内核开关**完全依照官方文档非 GKI（3.18–4.19）章节配置，
并额外开启了容器内防火墙（UFW / Fail2Ban）所需选项。
`CONFIG_ANDROID_PARANOID_NETWORK=n` 也已按官方要求处理。

---

## 3. 使用步骤（云端编译）

### 步骤 1：创建仓库并上传本套件

在 GitHub 新建一个仓库（私有也可以），把 `earth-kernel-build/` 里的
`.github/`、`configs/`、`patches/`、`scripts/` 全部上传到仓库根目录。

> GitHub Actions 对私有仓库同样免费可用。

### 步骤 2：准备 stock boot.img（想直接拿到可刷 boot.img 就必做）

工作流需要你原厂 `boot.img` 的**直链**，才能把新内核塞进去并保留原厂 ramdisk。

你本地文件在：
```
E:\Chormedownload\earth_global_images_V14.0.7.0.TCVMIXM_13.0\images\boot.img
```

任选一种方式拿到直链：

- **方式 A（推荐）**：在仓库里新建一个 Release，把 `boot.img` 作为附件上传，
  然后右键复制该附件的下载链接。
- **方式 B**：上传到任意网盘/对象存储，取直链。

如果不填直链也能编译，只是产物只有裸内核 `Image.gz-dtb`，需要你自己 repack。

### 步骤 3：运行工作流

`Actions` → `Build earth kernel (KernelSU-Next + SUSFS + Droidspaces)` → `Run workflow`。

| 输入项 | 默认值 | 说明 |
|---|---|---|
| `kernel_repo` | `LineageOS/android_kernel_xiaomi_earth` | 内核源码仓库 |
| `kernel_ref` | `lineage-21` | 分支/标签 |
| `defconfig` | `earth` | 对应 `arch/arm64/configs/earth_defconfig` |
| `kernelsu_ref` | `legacy` | **必须是非 GKI 的 ref**：`legacy` 分支，或 `v3.4.0-legacy` 这类标签/具体 commit；填主线的 `v3.4.2` 一定编不过（见 1.2） |
| `ksu_hook` | `kprobe` | `kprobe`（默认）或 `syscall_table`（kprobe 有问题、刷完卡开机时改这个） |
| `susfs_ref` | `kernel-4.19` | SUSFS 分支 |
| `susfs_enable` | `0` | 是否打 SUSFS（当前 KSU 侧胶水补丁还在适配，默认关） |
| `jobs` | `3` | 并行编译任务数，调高更快但可能 OOM |
| `stock_boot_img_url` | 空 | 填了才产出 `boot.img` |

### 步骤 4：下载产物

- `earth-boot-img` → **`earth-boot-new.img`**（可直接刷）
- `earth-kernel-images` → `Image.gz-dtb`、`kernel.config`、`kernel.release`
- `earth-build-logs` → `setup.log`、`build.log`、`repack.log`（**出问题时把这三个发我**）

---

## 4. 刷入

A/B 机型，两个槽都要刷：

```bash
fastboot flash boot_a earth-boot-new.img
fastboot flash boot_b earth-boot-new.img
fastboot reboot
```

如果开机后卡在 AVB 校验（dm-verity），刷一次 vbmeta：

```bash
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
```

> `vbmeta.img` 就在你固件的 `images/` 目录里，**先备份原厂 boot.img**！

**回滚**：`fastboot flash boot_a boot.img` + `boot_b`，或直接用你固件目录里的
`flash_all_except_data_storage.bat`。

---

## 5. 刷入后怎么验证功能

```bash
# 1) KernelSU 是否工作
adb shell su -c id                      # 应返回 uid=0
# 或直接打开 KernelSU-Next 管理器，应显示「已安装 / 工作中」

# 2) SUSFS 是否生效
adb shell su -c "cat /proc/version"     # 看内核版本
adb shell su -c "ksu_susfs --version"   # 装了 SUSFS 模块后可用

# 3) 内核版本指纹
adb shell cat /proc/version

# 4) Droidspaces 需求自检（最重要）
#    打开 Droidspaces App -> Settings -> Requirements -> Check Requirements
#    "must have" 和 "recommended" 应全部通过
```

> **KernelSU-Next 管理器**：APK 在
> [KernelSU-Next Releases](https://github.com/KernelSU-Next/KernelSU-Next/releases) 里下载。
> `legacy` 分支只含内核侧代码，没有自己的管理器，所以直接用官方最新 APK 即可；
> 若管理器提示内核版本不兼容，退一个版本（例如 v3.4.0）再试。
> （你之前用的 1.0.8 已经非常旧了。）注意 KSU-Next 的包名/签名与老 KernelSU 不同，
> 装之前先卸载旧管理器，但**不要卸载已授权的 root 应用**。

---

## 6. 已知风险与应对（请务必读）

### 风险 1：SUSFS→KernelSU 胶水补丁打不上 ⚠️ 目前 SUSFS 默认关闭的原因

SUSFS 的 `kernel-4.19` 分支最后更新于 2025-02，它的 KSU 侧补丁
（`10_enable_susfs_for_ksu.patch`）针对的是**旧版 KernelSU 的文件布局**
（`kernel/core_hook.c`、`kernel/allowlist.c`、`kernel/apk_sign.c` …），
而 KernelSU-Next 现在是 `kernel/core/`、`kernel/hook/`、`kernel/policy/` 新布局，
补丁里的路径和函数重命名都对不上，必然有 hunk 冲突。
这就是工作流里 `susfs_enable` 默认为 `0` 的原因：**先把 KernelSU 根跑通**，
SUSFS 需要按新布局重写胶水补丁（工作量在第 1 轮编译之后单独做）。

**处理方式**：`setup-kernel.sh` 会把失败原因和 `.rej` 文件数量打印到 `setup.log`，
并把最关键的符号重命名列出来。**把 `setup.log` 发我，我按实际报错适配。**

补丁涉及的旧→新符号名（可能需要对号入座）：
```
is_manager            -> ksu_is_manager
escape_to_root        -> ksu_escape_to_root
setup_selinux         -> ksu_setup_selinux
kernelsu_init         -> ksu_kernelsu_init
on_post_fs_data       -> ksu_on_post_fs_data
track_throne          -> ksu_track_throne
handle_sepolicy       -> ksu_handle_sepolicy
apply_kernelsu_rules  -> ksu_apply_kernelsu_rules
is_manager_apk        -> ksu_is_manager_apk
is_zygote             -> ksu_is_zygote
is_ksu_domain         -> ksu_is_ksu_domain
getenforce            -> ksu_getenforce
```

### 风险 2：内核侧 SUSFS 补丁依赖 `ANDROID_KABI_*` 宏

`50_add_susfs_in_kernel-4.19.patch` 会去改 `include/linux/mount.h` 和
`include/linux/sched.h` 里的 `ANDROID_KABI_RESERVE/USE` 字段。
这些宏是 Android 内核树特有的。LineageOS 的 `earth` 树基于 MTK 官方 Android 内核，
**大概率有**这些宏；若没有，补丁会在这里失败。同样看 `setup.log`。

### 风险 3：MIUI vendor 模块与 LineageOS 内核的兼容性

你刷的是 **MIUI 14 官方固件**，而内核源码来自 **LineageOS**。
MTK 机型部分驱动是预编译模块（`vendor` 分区），它们要求 vermagic 与
`CONFIG_MODVERSIONS` 符号 CRC 匹配。本套件通过以下方式降低风险：

- 保留原厂 `CONFIG_LOCALVERSION="-perf"`；
- 关闭 `CONFIG_LOCALVERSION_AUTO`（避免 vermagic 随 git 状态漂移）；
- 不改动 `CONFIG_MODVERSIONS` 与 `CONFIG_PREEMPT`。

如果 `Image.gz-dtb` 里的版本指纹和原厂 `boot.img` 差异很大，
并且开机后出现大量模块加载失败，那就要考虑改用 **mt6768-dev 的 MIUI 基线树**
（在 workflow 的 `kernel_repo` / `kernel_ref` 里换掉即可）。

### 风险 4：首次编译失败是正常的

这类三方补丁 + 新版本 KSU 的组合，第一次几乎一定需要 1–2 轮迭代。
**直接把 `setup.log` / `build.log` 发我**，我来改脚本，你只需重跑 workflow。

---

## 7. 和你的参考项目的关系

你原来用的 [Oscar1640/android_kernel_xiaomi_earth](https://github.com/Oscar1640/android_kernel_xiaomi_earth)
（`Earth-v1.0`，KSU-Next 1.0.8）本身就是 LineageOS 树的 fork。

本套件按你的要求**不基于他的树**，而是：

- 源码改用 **LineageOS 上游** `lineage-21`（更干净、更新，且无 Android 16 混合提交）；
- 在他的思路基础上，把 KernelSU-Next 从 `1.0.8` 换成 **新版 KernelSU-Next 的
  `legacy`（非 GKI）分支** —— 主线的 `v3.4.x` 在 4.19 上编不过，`legacy` 才是
  同代 KernelSU-Next 对老内核的移植；
- 新增 **SUSFS** 与 **Droidspaces** 支持（SUSFS 的 KSU 侧胶水补丁仍在适配，暂默认关）；
- 用「替换 stock boot.img 内核」代替整包打包，降低刷机风险。

---

## 8. 常用调整

**换 KernelSU-Next 版本**：改 `kernelsu_ref`。
只能填非 GKI 的 ref：`legacy`（默认，跟随上游修复）、
`v3.4.0-legacy` 这类标签，或某次 commit 的 SHA（脚本支持直接填 SHA，会把它
fetch 下来 checkout，便于复现某次构建）。
填主线标签（如 `v3.4.2`）会在 setup 阶段直接被拦下并提示原因。

**kprobe 有问题时换钩子方式**：把 `ksu_hook` 改成 `syscall_table`。
表现是刷完卡在开机（KernelSU 的 kprobe 钩子在这台机器上不工作），
换完重跑一次 workflow 即可，不需要改代码。

**换源码树**：改 `kernel_repo` / `kernel_ref`。
例如想更贴近 MIUI 基线，可试 `mt6768-dev/android_kernel_xiaomi_earth`。

**关掉不需要的 Droidspaces 功能**：编辑 `configs/earth-droidspaces.fragment`，
删掉对应行即可（例如不需要容器内防火墙就删掉文件末尾的 UFW/Fail2Ban 段）。

**关掉 SUSFS 日志**：在 `scripts/setup-kernel.sh` 里把
`CONFIG_KSU_SUSFS_ENABLE_LOG=y` 改成 `n`，可减少 dmesg 噪音。

---

## 9. 最后一句提醒

⚠️ **刷内核有变砖风险，请先备份 `boot.img`、`vbmeta.img` 和你的数据。**
本套件已尽量按「最小改动」设计（保留原厂 ramdisk、只换内核、保留 MTK 配置），
但首次刷入仍建议确认 fastboot 和固件包随时可用。
