#!/usr/bin/env bash
# =============================================================================
#  build.sh -- configure and build the earth (MT6768, 4.19) kernel
#
#  Usage:  ./build.sh /path/to/kernel/root
#
#  Expects setup-kernel.sh to have been run first, and these env vars set by
#  the caller (see .github/workflows/build-kernel.yml):
#     CLANG_PATH, GCC64_PATH, GCC32_PATH, BUILDTOOLS_PATH, JOBS
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/../configs/earth-droidspaces.fragment"

JOBS="${JOBS:-$(nproc)}"
# Cap default parallelism: linking and some MTK translation units are memory
# heavy, and exceeding runner RAM gets the job OOM-killed with no message.
if [ "${ALLOW_HIGH_JOBS:-0}" != "1" ] && [ "$JOBS" -gt 3 ]; then
	echo "[i] capping jobs $JOBS -> 3 (set ALLOW_HIGH_JOBS=1 to override)"
	JOBS=3
fi
# DEFCONFIG is passed by the workflow (defaults to "earth" -> earth_defconfig)
DEFCONFIG_TARGET="${DEFCONFIG:-earth}_defconfig"

echo "=============================================================="
echo " Building earth kernel"
echo "   root    : $KERNEL_ROOT"
echo "   jobs    : $JOBS"
echo "   clang   : ${CLANG_PATH:-<PATH>}"
echo "=============================================================="

# ---------------------------------------------------------------------------
# Toolchain environment
# ---------------------------------------------------------------------------
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export SUBARCH=arm64

if [ -n "${CLANG_PATH:-}" ]; then
	export PATH="$CLANG_PATH/bin:$PATH"
fi

MAKE_ARGS=(
	ARCH=arm64
	LLVM=1
	LLVM_IAS=1
	O=out
)
if [ -n "${GCC64_PATH:-}" ]; then
	MAKE_ARGS+=("CROSS_COMPILE=aarch64-linux-gnu-")
	export PATH="$GCC64_PATH/bin:$PATH"
fi
if [ -n "${GCC32_PATH:-}" ]; then
	export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
	export PATH="$GCC32_PATH/bin:$PATH"
fi
if [ -n "${BUILDTOOLS_PATH:-}" ]; then
	MAKE_ARGS+=("BUILD_TOOLS_PATH=$BUILDTOOLS_PATH")
fi

echo "[i] clang version:"
clang --version | head -n2 | sed 's/^/    /'
echo

cd "$KERNEL_ROOT"

# ---------------------------------------------------------------------------
# 1) Configure: earth_defconfig + Droidspaces fragment
# ---------------------------------------------------------------------------
echo "[1/4] Generating .config"

# CONFIG_DEBUG_INFO makes the compiler emit full DWARF for every object. On a
# 7 GB runner that is the single biggest memory and time cost, and it buys
# nothing for a kernel we are going to flash. Disable it unless explicitly
# asked for (DEBUG_INFO=1).
DEBUG_INFO="${DEBUG_INFO:-0}"
if [ "$DEBUG_INFO" != "1" ]; then
	if grep -q '^CONFIG_DEBUG_INFO=y' "$KERNEL_ROOT/arch/arm64/configs/${DEFCONFIG_TARGET}" 2>/dev/null; then
		sed -i 's/^CONFIG_DEBUG_INFO=y$/# CONFIG_DEBUG_INFO is not set/' \
			"$KERNEL_ROOT/arch/arm64/configs/${DEFCONFIG_TARGET}"
		echo "[i] CONFIG_DEBUG_INFO disabled (smaller/faster build; set DEBUG_INFO=1 to keep)"
	fi
fi

# Start from a clean output dir so stale configs cannot leak in.
rm -rf out
mkdir -p out

make "${MAKE_ARGS[@]}" "$DEFCONFIG_TARGET"

if [ ! -f "$FRAGMENT" ]; then
	echo "ERROR: Droidspaces fragment missing: $FRAGMENT"
	exit 2
fi

# Merge the fragment. Fragment entries take precedence over the defconfig.
./scripts/kconfig/merge_config.sh -m -O out out/.config "$FRAGMENT"

# merge_config only warns on symbols whose dependencies are unmet; those
# silently disappear. Surface that explicitly for the runtime-critical ones.
make "${MAKE_ARGS[@]}" olddefconfig

echo
echo "[i] config verification (critical Droidspaces + KSU symbols):"
check_cfg() {
	local sym="$1" want="$2"
	local got
	got=$(grep -E "^${sym}=|^# ${sym} is not set" out/.config || true)
	got=${got:-"<absent>"}
	if [ "$want" = "y" ]; then
		case "$got" in
			"${sym}=y") echo "    OK      $sym=y" ;;
			*)          echo "    MISSING $sym (want y, got: $got)" ;;
		esac
	else
		case "$got" in
			"# ${sym} is not set"|"<absent>") echo "    OK      $sym is not set" ;;
			*) echo "    UNEXPECTED $sym (want unset, got: $got)" ;;
		esac
	fi
}

for sym in \
	CONFIG_NAMESPACES CONFIG_PID_NS CONFIG_UTS_NS CONFIG_IPC_NS CONFIG_NET_NS \
	CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_SECCOMP CONFIG_SECCOMP_FILTER \
	CONFIG_CGROUPS CONFIG_CGROUP_DEVICE CONFIG_MEMCG CONFIG_CFS_BANDWIDTH \
	CONFIG_CGROUP_PIDS CONFIG_DEVTMPFS CONFIG_OVERLAY_FS CONFIG_VETH CONFIG_BRIDGE \
	CONFIG_NF_NAT CONFIG_NF_TABLES \
	CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE CONFIG_MACVLAN \
	CONFIG_USER_NS CONFIG_FUSE_FS CONFIG_TUN CONFIG_EXT4_FS \
	CONFIG_KSU
do
	check_cfg "$sym" y
done

# IPv4 MASQUERADE: the symbol name depends on the kernel generation.
# Modern trees have NETFILTER_XT_TARGET_MASQUERADE; this 4.19 MTK tree only
# carries the iptables-era IP_NF_TARGET_MASQUERADE, which selects
# NF_NAT_MASQUERADE_IPV4. Checking only the modern name reports a bogus
# "MISSING" on a config that is in fact fine, so accept any of the three.
if grep -q '^CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y' out/.config; then
	echo "    OK      CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y"
elif grep -q '^CONFIG_IP_NF_TARGET_MASQUERADE=y' out/.config; then
	echo "    OK      CONFIG_IP_NF_TARGET_MASQUERADE=y (this tree's name for the MASQUERADE target)"
elif grep -q '^CONFIG_NF_NAT_MASQUERADE_IPV4=y' out/.config; then
	echo "    OK      CONFIG_NF_NAT_MASQUERADE_IPV4=y (MASQUERADE support present)"
else
	echo "    MISSING IPv4 MASQUERADE support: none of NETFILTER_XT_TARGET_MASQUERADE,"
	echo "            IP_NF_TARGET_MASQUERADE, NF_NAT_MASQUERADE_IPV4 is enabled"
fi

# KernelSU hook mode. The legacy Kconfig offers a choice; setup-kernel.sh wrote
# the symbol matching KSU_HOOK_MODE (kprobe | syscall_table). Verifying it here
# matters because a silently dropped symbol means a kernel that boots without
# working root -- the hardest kind of failure to notice before flashing.
KSU_HOOK_MODE="${KSU_HOOK_MODE:-kprobe}"
echo "    --- KernelSU hook mode: $KSU_HOOK_MODE ---"
case "$KSU_HOOK_MODE" in
kprobe)
	check_cfg CONFIG_KPROBES y
	check_cfg CONFIG_KSU_KPROBES_HOOK y
	;;
syscall_table)
	check_cfg CONFIG_KSU_SYSCALL_TABLE_HOOK y
	;;
*)
	echo "    UNKNOWN KSU_HOOK_MODE '$KSU_HOOK_MODE' (expected kprobe or syscall_table)"
	;;
esac

# SUSFS symbols only exist when SUSFS was actually applied.
if grep -q '^CONFIG_KSU_SUSFS' out/.config 2>/dev/null; then
	echo "    --- SUSFS enabled, verifying its switches ---"
	check_cfg CONFIG_KSU_SUSFS y
	check_cfg CONFIG_KSU_SUSFS_SUS_PATH y
	check_cfg CONFIG_KSU_SUSFS_SUS_MOUNT y
	check_cfg CONFIG_KSU_SUSFS_SUS_KSTAT y
else
	echo "    --- SUSFS not present in this build (KernelSU-Next only) ---"
	if grep -q '^CONFIG_KSU_SUSFS' arch/arm64/configs/*_defconfig 2>/dev/null; then
		echo "    WARNING: defconfig requests SUSFS but .config has no CONFIG_KSU_SUSFS"
	fi
fi

check_cfg CONFIG_ANDROID_PARANOID_NETWORK n

# These must not be "not set"; they are commonly built-in (=y) on MTK kernels.
echo "    --- loop device / overlay (informational) ---"
grep -E '^CONFIG_(BLK_DEV_LOOP|OVERLAY_FS)=' out/.config | sed 's/^/    /' || \
	echo "    WARNING: BLK_DEV_LOOP / OVERLAY_FS not enabled (sparse-image containers need them)"

echo
echo "[i] key kernel version / preempt settings:"
grep -E '^CONFIG_(LOCALVERSION|PREEMPT|MODVERSIONS|MTK_FPSGO)' out/.config | sed 's/^/    /' || true
echo

# ---------------------------------------------------------------------------
# run_make: stream output live (tee) AND keep a copy for the failure summary.
#
# Defined here (not further down) because step 1b below uses it too.
#
# An earlier revision redirected make entirely into a file and only printed
# the tail once make returned. For a 30-45 minute kernel build that made the
# CI log look completely frozen after the "=== make ===" banner, which is
# indistinguishable from a hang. tee keeps both properties.
# ---------------------------------------------------------------------------
BUILD_ERRLOG="$KERNEL_ROOT/build-error.log"
: >"$BUILD_ERRLOG"

run_make() {
	echo
	echo "=== make ${MAKE_ARGS[*]} $* ===" | tee -a "$BUILD_ERRLOG"
	echo "=== started $(date -u +%H:%M:%S) ===" | tee -a "$BUILD_ERRLOG"
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL make "${MAKE_ARGS[@]}" "$@" 2>&1 | tee -a "$BUILD_ERRLOG"
		STATUS=${PIPESTATUS[0]}
	else
		make "${MAKE_ARGS[@]}" "$@" 2>&1 | tee -a "$BUILD_ERRLOG"
		STATUS=${PIPESTATUS[0]}
	fi
	echo "=== finished $(date -u +%H:%M:%S) (status $STATUS) ===" | tee -a "$BUILD_ERRLOG"
	if [ "$STATUS" -ne 0 ]; then
		echo
		echo "############################################################"
		echo " make FAILED: make ${MAKE_ARGS[*]} $*"
		echo " exit status: $STATUS"
		echo " last 60 lines of output:"
		echo "############################################################"
		tail -n 60 "$BUILD_ERRLOG"
		echo "############################################################"
		echo " full output saved to build-error.log"
		echo "############################################################"
		exit "$STATUS"
	fi
	tail -n 5 "$BUILD_ERRLOG"
}

# ---------------------------------------------------------------------------
# 1b) Apply KernelSU's kernel-tree patches BEFORE the first C file is compiled.
#
# KernelSU-Next's Kbuild patches the kernel tree *while it is being parsed*:
#   fs/namespace.c        + path_umount()/can_umount()  (5.9+ backport)
#   fs/internal.h         + the matching declaration
#   include/linux/seccomp.h + a struct seccomp field
#   security/selinux/*    + selinux_cred()/selinux_inode() backports
#
# make only parses drivers/kernelsu/Kbuild when it descends into drivers/ --
# which, in a parallel build, is long after fs/ and security/ were compiled.
# Consequences of that ordering (both were real in the previous run):
#   * fs/namespace.o keeps the *unpatched* source, while KSU sees path_umount()
#     in the header-produced flag KSU_HAS_PATH_UMOUNT and calls it, so the final
#     link dies with:
#         ld.lld: error: undefined symbol: path_umount
#         >>> referenced by kernel_umount.c
#   * objects compiled before the struct seccomp backport and objects compiled
#     after it disagree about a kernel structure layout.
# Parsing that one directory here -- after the tree is configured, before dtbs
# and the image -- applies every patch up front, so the rest of the build
# compiles one consistent tree.
# ---------------------------------------------------------------------------
echo "[1b/4] Applying KernelSU kernel-tree patches (before any C file is built)"
run_make -j"$JOBS" prepare

# KernelSU's sources include security/selinux headers, and flask.h /
# av_permissions.h are *generated* by scripts/selinux/genheaders -- they only
# appear when that directory is built. So it has to be prepared first, otherwise
# the drivers/kernelsu step below dies on "flask.h: No such file or directory".
run_make -j"$JOBS" security/selinux/

# Now parse (and build) drivers/kernelsu. This is the step that applies the
# patches listed above -- the Kbuild does it while make parses it -- and because
# it happens here, fs/, security/ and everything else are still uncompiled and
# will be built from the patched sources.
run_make -j"$JOBS" drivers/kernelsu/

if grep -q '^int path_umount' "$KERNEL_ROOT/fs/namespace.c"; then
	echo "    OK      fs/namespace.c carries the path_umount() backport (fs/ builds it below)"
else
	echo "    note    fs/namespace.c has no path_umount(): KernelSU uses its ksys_umount() fallback"
fi
if grep -q 'atomic_t filter_count;' "$KERNEL_ROOT/include/linux/seccomp.h"; then
	echo "    OK      struct seccomp backport present before any consumer compiles"
fi
if grep -q 'path_umount' "$KERNEL_ROOT/fs/internal.h"; then
	echo "    OK      fs/internal.h declares path_umount()"
fi
echo

# ---------------------------------------------------------------------------
# 2) Build
# ---------------------------------------------------------------------------
echo "[2/4] Compiling (this takes a while)"
START=$(date +%s)

# ---------------------------------------------------------------------------
# Memory watchdog. A kernel build on a 4-core / 7 GB runner can hit OOM, and
# when the OOM killer fires the build dies with no message at all. Log free
# memory every 30s so any future failure has evidence attached to it.
# ---------------------------------------------------------------------------
FREE_LOG="$KERNEL_ROOT/memory.log"
: >"$FREE_LOG"
(
	while true; do
		# `|| true` matters: this subshell inherits `set -e` from the script,
		# so a transient failure of free/awk would silently kill the watchdog.
		LINE=$(free -m 2>/dev/null | awk '/Mem:/ {print "used="$3"MB free="$4"MB avail="$7"MB"}' 2>/dev/null) || LINE="free unavailable"
		echo "[$(date -u +%H:%M:%S)] $LINE" >>"$FREE_LOG" || true
		sleep 30
	done
) &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# run_make() is defined above, before step 1b (which needs it too).
# ---------------------------------------------------------------------------

# dtbs first: the appended-DTB image target depends on them.
run_make -j"$JOBS" dtbs

# Which final image to build depends on arch/arm64/Makefile:
#   ifeq ($(CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE),y)
#   KBUILD_IMAGE := $(boot)/$(CONFIG_BUILD_ARM64_APPENDED_KERNEL_IMAGE_NAME)
#
# This device sets CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y, so the flashable
# payload is Image.gz-dtb (kernel + appended DTB), NOT Image.gz.
KIMG="Image.gz-dtb"
if [ -f out/include/config/auto.conf ]; then
	CFG_IMG=$(sed -n 's/^CONFIG_BUILD_ARM64_APPENDED_KERNEL_IMAGE_NAME="\(.*\)"/\1/p' out/include/config/auto.conf | head -1)
	if [ -n "$CFG_IMG" ]; then
		KIMG="$CFG_IMG"
	fi
fi
echo "[i] building kernel image target: $KIMG"
echo "[i] jobs: $JOBS"
run_make -j"$JOBS" "$KIMG"

# Sanity-check what the kernel build actually produced.
if [ ! -f out/vmlinux ]; then
	echo
	echo "ERROR: out/vmlinux is missing - the kernel itself was never linked."
	echo "       contents of out/arch/arm64/boot:"
	ls -la out/arch/arm64/boot 2>/dev/null | sed 's/^/         /' || true
	tail -n 40 "$BUILD_ERRLOG"
	exit 4
fi
if [ ! -f "out/arch/arm64/boot/$KIMG" ]; then
	echo
	echo "ERROR: kernel linked, but target '$KIMG' was not produced."
	echo "       contents of out/arch/arm64/boot:"
	ls -la out/arch/arm64/boot 2>/dev/null | sed 's/^/         /' || true
	echo "       (KBUILD_IMAGE=$KIMG)"
	exit 4
fi

END=$(date +%s)
echo "[i] build finished in $(( (END - START) / 60 )) min"
echo

# ---------------------------------------------------------------------------
# 3) Collect artifacts
# ---------------------------------------------------------------------------
echo "[4/4] Collecting artifacts"
DIST="$KERNEL_ROOT/dist"
mkdir -p "$DIST"

shopt -s nullglob
IMAGES=("$KERNEL_ROOT"/out/arch/arm64/boot/Image*)
DTBS=("$KERNEL_ROOT"/out/arch/arm64/boot/dts/mediatek/*.dtb)
DTBO=("$KERNEL_ROOT"/out/arch/arm64/boot/dtbo.img)

if [ ${#IMAGES[@]} -eq 0 ]; then
	echo "ERROR: no kernel image produced under out/arch/arm64/boot/"
	exit 3
fi

for f in "${IMAGES[@]}"; do
	cp -v "$f" "$DIST/"
done

# Flatten dtbs into a folder (handy for debugging / manual repack).
mkdir -p "$DIST/dtb"
for f in "${DTBS[@]}"; do
	cp -v "$f" "$DIST/dtb/"
done
for f in "${DTBO[@]}"; do
	cp -v "$f" "$DIST/"
done

cp -v out/.config "$DIST/kernel.config"
if [ -f out/System.map ]; then cp -v out/System.map "$DIST/"; fi
if [ -f out/vmlinux ]; then cp -v out/vmlinux "$DIST/"; fi

# Resolve the flashable payload explicitly and fail loudly if we cannot.
# This device sets CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y, so the payload MUST
# be Image.gz-dtb (kernel + appended DTB). A bare Image.gz would produce a
# boot.img with no device tree, which is exactly the kind of silent breakage
# we want to catch here rather than on the phone.
PAYLOAD=""
for cand in "$KERNEL_ROOT/out/arch/arm64/boot/$KIMG" \
            "$KERNEL_ROOT/out/arch/arm64/boot/Image.gz-dtb"; do
	if [ -f "$cand" ]; then
		PAYLOAD="$cand"
		break
	fi
done

if [ -z "$PAYLOAD" ]; then
	echo
	echo "ERROR: no usable kernel payload found."
	echo "       expected: $KERNEL_ROOT/out/arch/arm64/boot/$KIMG"
	echo "       actual contents of out/arch/arm64/boot:"
	ls -la "$KERNEL_ROOT/out/arch/arm64/boot/" 2>/dev/null | sed 's/^/         /' || echo "         <directory missing>"
	echo "       If only Image.gz exists, CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE"
	echo "       is not taking effect; the appended-DTB target did not build."
	exit 3
fi

cp -v "$PAYLOAD" "$DIST/$(basename "$PAYLOAD")"
echo "[i] flashable payload  : $(basename "$PAYLOAD")"
echo "[i] payload size       : $(stat -c%s "$PAYLOAD") bytes"

if [ "$(basename "$PAYLOAD")" != "Image.gz-dtb" ]; then
	echo "[!] note: payload is $(basename "$PAYLOAD"), not Image.gz-dtb."
	echo "    The boot.img dtb field will be preserved from stock instead."
fi

# Report the fingerprint we will compare against the boot header in CI.
KREL="unknown"
if [ -f out/include/config/kernel.release ]; then
	KREL=$(cat out/include/config/kernel.release)
fi
echo "$KREL" >"$DIST/kernel.release"
echo
echo "[i] kernel release string : $KREL"
if [ -f "$DIST/Image.gz-dtb" ]; then
	echo "[i] kernel fingerprint    : $(strings "$DIST/Image.gz-dtb" | grep -m1 'Linux version' || echo '<not found>')"
fi
echo
echo "[i] artifacts in $DIST:"
ls -la "$DIST" | sed 's/^/    /'
