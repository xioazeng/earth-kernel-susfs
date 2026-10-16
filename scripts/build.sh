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
echo "[1/3] Generating .config"

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
	CONFIG_NF_NAT CONFIG_NF_TABLES CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
	CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE CONFIG_MACVLAN \
	CONFIG_USER_NS CONFIG_FUSE_FS CONFIG_TUN CONFIG_EXT4_FS \
	CONFIG_KSU CONFIG_KPROBES
do
	check_cfg "$sym" y
done

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
# 2) Build
# ---------------------------------------------------------------------------
echo "[2/3] Compiling (this takes a while)"
START=$(date +%s)

# Capture the real make output so a failure is self-explanatory, instead of
# only being discoverable by digging through the whole CI log.
BUILD_ERRLOG="$KERNEL_ROOT/build-error.log"
run_make() {
	echo
	echo "=== make ${MAKE_ARGS[*]} $* ===" | tee -a "$BUILD_ERRLOG"
	make "${MAKE_ARGS[@]}" "$@" >>"$BUILD_ERRLOG" 2>&1
	STATUS=$?
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
echo "[3/3] Collecting artifacts"
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
