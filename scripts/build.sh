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
	CONFIG_KSU CONFIG_KSU_SUSFS CONFIG_KPROBES
do
	check_cfg "$sym" y
done
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

# dtbs first: the appended-DTB image target depends on them.
make "${MAKE_ARGS[@]}" -j"$JOBS" dtbs
make "${MAKE_ARGS[@]}" -j"$JOBS" Image.gz

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

# The device uses CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE, so the flashable
# kernel is Image.gz-dtb (kernel + appended DTB in one blob).
if [ -f "$KERNEL_ROOT"/out/arch/arm64/boot/Image.gz-dtb ]; then
	echo
	echo "[i] appended-DTB image present -> boot.img kernel will be Image.gz-dtb"
	cp -v "$KERNEL_ROOT"/out/arch/arm64/boot/Image.gz-dtb "$DIST/Image.gz-dtb"
elif [ -f "$KERNEL_ROOT"/out/arch/arm64/boot/Image.gz ]; then
	echo
	echo "[!] Image.gz-dtb NOT found; falling back to Image.gz + separate dtb."
	echo "    If the device does not boot, check BUILD_ARM64_APPENDED_DTB_IMAGE."
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
