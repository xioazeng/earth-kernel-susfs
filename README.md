# Redmi 12C / Poco C55 (earth / MT6768) 内核编译套件

**KernelSU（SUSFS 原生分支）+ SUSFS + Droidspaces** ｜ 基于 LineageOS 源码树 ｜ 云端编译，产出可直接刷入的 `boot.img`

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

### 1.2 为什么用「SUSFS 原生 KernelSU 分支」（4.19 的关键取舍）

这一点决定了整个方案能不能编译成功，值得单独说明：

- **KernelSU-Next 在 4.19 上做不了 SUSFS**，三条独立证据：
  1. 它自己的 SUSFS 是**可加载模块**：`kernel/susfs/Makefile` 写着
     `obj-m += susfs_guard_lkm.o`，注释是 "Build against DDK kernel headers
     (same image that builds kernelsu.ko)" —— 非 GKI、源码内建的内核用不了。
  2. 它的 **`legacy`（非 GKI）分支完全没有 SUSFS**（没有 `kernel/susfs/`，
     Kconfig/Kbuild 里没有任何 SUSFS 钩子）；而主线 `v3.4.x` 的源码还调用了
     4.19 不存在的接口（`linux/pgtable.h`、`strncpy_from_user_nofault`、
     `TWA_RESUME`），实测直接编译失败。
  3. 非 GKI 社区的多机型构建项目（NootFond/NonGKI_Kernel_Build_mix2s）把
     KernelSU-Next 标为 **"Not Supported ❌"**，它的机型表里 **4.19 + SuSFS ✅**
     用的是 SUSFS 原生分支（rsuntk、Magic 等）。
- 所以本套件用 **`rsuntk/KernelSU` 的 `susfs-rksu-master` 分支**：它是老布局
  KernelSU（正是 susfs4ksu `kernel-4.19` 补丁所针对的布局），而且 **SUSFS 已经
  内建**：`kernel/Kconfig` 有全套 `KSU_SUSFS*` 菜单，`kernel/supercalls.c`
  实现了全部 `CMD_SUSFS_*`（比冻结的 4.19 补丁还多：`ADD_SUS_MAP`、
  `ADD_SUS_PATH_LOOP`、`SET_SDCARD_ROOT_PATH`、`ENABLE_AVC_LOG_SPOOFING` …），
  `kernel/Makefile` 自带非 GKI 回移（`path_umount`、seccomp `filter_count`）。
  **因此 KSU 侧一个 hunk 都不需要我改写。**
- 仍然需要的是 **SUSFS 内核侧补丁**（susfs4ksu `kernel-4.19`：`fs/susfs.c`
  与 `fs/*` 里的钩子）。实测在这棵 LineageOS 树上 **69/72 hunk 直接可用**，
  剩下 3 个由 `setup-kernel.sh` 修复：`fs/proc/task_mmu.c` 的 include，
  以及 `include/linux/sched.h` 里 `struct task_struct` 的两个字段
  （`susfs_task_state`、`susfs_last_fake_mnt_id`）。
- 钩子方式没有可选项：这个 KSU 代际用 **kprobes + LSM hooks**，所以只需
  `CONFIG_KPROBES=y`。
- 4.19 仍有一处兼容补丁：**arm64 4.19 没有 `user_stack_pointer()`**，而
  `include/linux/ptrace.h` 的 `current_user_stack_pointer()` 基于它定义，
  `sucompat.c` 在用。`setup-kernel.sh` 会先检查内核树里到底有没有这个函数，
  确认没有才注入 arm64 兼容实现（优先复用内核自带的 `GET_USP()`）。

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
| `kernelsu_ref` | `susfs-rksu-master` | KernelSU ref。必须带内建 SUSFS（`rsuntk/KernelSU` 的 `susfs-rksu-master`，或同类 SUSFS 原生分支）；setup 阶段会检查 `kernel/supercalls.c` 里的 `CMD_SUSFS_*` 与 Kconfig 菜单，没有就直接报错 |
| `susfs_ref` | `kernel-4.19` | SUSFS 分支（4.19 线的最新就是它） |
| `susfs_enable` | `1` | 是否打 SUSFS 内核侧补丁（默认开） |
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

> **KernelSU 管理器**：内核用的是 `rsuntk/KernelSU`（SUSFS 原生分支，内核版本号
> `32359`），管理器 APK 取同源：
> [rsuntk/KernelSU Releases](https://github.com/rsuntk/KernelSU/releases)
> （该分支只含内核代码，`main` 分支里才有管理器源码）。
> 管理器与内核的**签名/版本要配套**，若提示不兼容就用与内核同一代的 APK。
> 注意不同 KernelSU 分支的包名/签名可能不同，装之前先卸载旧管理器，
> 但**不要卸载已授权的 root 应用**。

---

## 6. 已知风险与应对（请务必读）

### 风险 1：SUSFS 内核侧补丁有 3 个 hunk 打不上（已自动修复）

`50_add_susfs_in_kernel-4.19.patch` 在这棵 LineageOS 树上实测 **69/72 hunk 直接可用**，
3 个失败项已经由 `setup-kernel.sh` 自动补上：

1. `fs/proc/task_mmu.c` —— 补丁想加 `#include <linux/susfs_def.h>`，但周围上下文移动了；
   脚本会在首个 `asm/` include 前幂等插入（否则后面会报 `INODE_STATE_SUS_KSTAT` 未定义）。
2. `include/linux/sched.h` 的**两个** hunk —— 补丁想把 `struct task_struct` 里两个
   `ANDROID_KABI_RESERVE()` 换成 `ANDROID_KABI_USE(...)` 承载
   `susfs_task_state` / `susfs_last_fake_mnt_id`，但这棵树的 tail 不同（reserve 6 被
   `#ifdef __GENKSYMS__` 包着，后面还有 MTK 的 `CONFIG_MTK_TASK_TURBO` 字段）。
   非 GKI 内核没有 vendor kABI 需要保，所以脚本改为把这两个 `u64` 字段加在
   `randomized_struct_fields_end` 之前（正是补丁在无 `ANDROID_KABI_RESERVE` 时的做法）。

**注意**：`setup.log` 里那行 `PATCH FAILED` 现在属于**预期**，紧接着就会打印修复结果；
只要末尾是 `RESULT: OK` 且能看到 `verified: susfs_task_state + susfs_last_fake_mnt_id present`
就说明修复到位。

### 风险 2：SUSFS 与内核的 `ANDROID_KABI_*` / MTK 字段差异

上面的第 2 条已经说明：这棵树的 `task_struct` tail 被 MTK 改过，这正是补丁失败的原因，
也是脚本必须自己插字段的原因。`include/linux/mount.h` 那个 hunk **可以正常应用**。

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

### 风险 4：KernelSU 会在"编译过程中"改内核源码（build.sh 已提前处理）

KernelSU-Next 的 `Kbuild` 是在 **make 解析它的时候**去改内核源码的，包括：

| 被改的源文件 | 改动 |
|---|---|
| `fs/namespace.c` | 补上 `path_umount()` / `can_umount()`（5.9+ 才有） |
| `fs/internal.h` | 补上 `path_umount()` 声明 |
| `include/linux/seccomp.h` | 给 `struct seccomp` 加一个字段 |
| `security/selinux/*` | 补 `selinux_cred()` / `selinux_inode()` |

而 make 只有在**进入 `drivers/` 目录**时才会解析它——并行编译下这已经是 `fs/`、`security/` 都编完之后了。后果有两层：

1. `fs/namespace.o` 用的还是没打补丁的源码，但 KSU 那边因为看到 `fs/namespace.c` 里有 `path_umount` 就开了 `KSU_HAS_PATH_UMOUNT`，于是去调用它 → 最终链接失败：
   ```
   ld.lld: error: undefined symbol: path_umount
   >>> referenced by kernel_umount.c
   ```
2. 更隐蔽的是 `struct seccomp`：补丁前后编译出来的目标文件对同一个结构体大小理解不一致，这类问题不一定在编译期暴露，可能在开机后随机崩。

`build.sh` 现在多了一步 `[1b/4]`：配置完成后先 `make prepare`、`make security/selinux/`（KSU 要用的 `flask.h` 是生成文件），
再 `make drivers/kernelsu/` —— 让 KSU 的补丁在**任何 C 文件被编译之前**就落到内核树上，主流程再编译就是一棵一致的树。

### 风险 5：首次编译失败是正常的

这类三方补丁 + 新版本 KSU 的组合，第一次几乎一定需要 1–2 轮迭代。
**直接把 `setup.log` / `build.log` 发我**，我来改脚本，你只需重跑 workflow。

---

## 7. 和你的参考项目的关系

你原来用的 [Oscar1640/android_kernel_xiaomi_earth](https://github.com/Oscar1640/android_kernel_xiaomi_earth)
（`Earth-v1.0`，KSU-Next 1.0.8）本身就是 LineageOS 树的 fork。

本套件按你的要求**不基于他的树**，而是：

- 源码改用 **LineageOS 上游** `lineage-21`（更干净、更新，且无 Android 16 混合提交）；
- 在他的思路基础上，改用 **SUSFS 原生 KernelSU 分支**（`rsuntk/KernelSU` 的
  `susfs-rksu-master`）—— 4.19 上唯一能同时拿到"新 SUSFS + 能编译"的路线；
- **SUSFS 默认开启**（`susfs_enable=1`），内核侧走 susfs4ksu `kernel-4.19` 补丁；
- 用「替换 stock boot.img 内核」代替整包打包，降低刷机风险。

---

## 8. 常用调整

**换 KernelSU 分支**：改 `kernelsu_ref`（默认 `susfs-rksu-master`）。
必须是带**内建 SUSFS** 的分支——setup 阶段会检查 `kernel/supercalls.c` 里的
`CMD_SUSFS_*` 和 `kernel/Kconfig` 的 SUSFS 菜单，没有就直接报错并说明原因。
也可以填某个 commit 的 SHA（脚本会 fetch 下来 checkout，便于复现构建）。

**只想先要 root、不要 SUSFS**：这条路在当前 KSU 分支上**走不通**——
`rsuntk/KernelSU` 的 `kernel/Makefile` 在没有 `fs/susfs.c` 时直接
`$(error ...)` 终止（SUSFS_ENABLE=0 会被 `setup-kernel.sh` 提前拦下并说明原因）。
要纯 root，请把 `kernelsu_ref` 指向不带 SUSFS 的 KernelSU 分支。

**换源码树**：改 `kernel_repo` / `kernel_ref`。
例如想更贴近 MIUI 基线，可试 `mt6768-dev/android_kernel_xiaomi_earth`。

**Droidspaces 自检**：刷完后打开 App → Settings → Requirements → Check Requirements，
或 `adb shell droidspaces check`，让 "must have"/"recommended" 全绿。

**关掉不需要的 Droidspaces 功能**：编辑 `configs/earth-droidspaces.fragment`，
删掉对应行即可（例如不需要容器内防火墙就删掉文件末尾的 UFW/Fail2Ban 段）。

**关掉 SUSFS 日志**：在 `scripts/setup-kernel.sh` 里把
`CONFIG_KSU_SUSFS_ENABLE_LOG=y` 改成 `n`，可减少 dmesg 噪音。

---

## 9. 最后一句提醒

⚠️ **刷内核有变砖风险，请先备份 `boot.img`、`vbmeta.img` 和你的数据。**
本套件已尽量按「最小改动」设计（保留原厂 ramdisk、只换内核、保留 MTK 配置），
但首次刷入仍建议确认 fastboot 和固件包随时可用。
