#!/usr/bin/env bash
# =============================================================================
#  setup-kernel.sh
#  Inserts KernelSU-Next + SUSFS + Droidspaces support into the LineageOS
#  android_kernel_xiaomi_earth tree (Linux 4.19, non-GKI, MT6768 "earth").
#
#  Usage:  ./setup-kernel.sh /path/to/kernel/root
#
#  Order matters and is deliberate:
#    1) KernelSU-Next in "legacy" (non-GKI) mode -> provides kernel/ + drivers/kernelsu
#    2) SUSFS kernel-side patches                 -> requires the KSU tree from (1)
#    3) Droidspaces non-GKI patches               -> independent kernel patches
#    4) Droidspaces config fragment               -> merged at config time
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"

KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_REF="v3.4.2"                       # latest KernelSU-Next release
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_REF="kernel-4.19"                # official 4.19 branch (non-GKI)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/../configs/earth-droidspaces.fragment"
PATCH_DIR="$SCRIPT_DIR/../patches"

# -- Failure tracking ---------------------------------------------------------
CRITICAL_FAILURES=0
WARNINGS=0

fail_critical() { echo "!! CRITICAL: $*"; CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1)); }
note_warning()   { echo "!! WARNING : $*"; WARNINGS=$((WARNINGS + 1)); }

apply_patch() {
	local dir="$1" file="$2" label="$3" log="$4"
	echo "   -> applying $label"
	if (cd "$dir" && patch -p1 --forward --batch --no-backup-if-mismatch <"$file" >"$log" 2>&1); then
		echo "      OK"
		return 0
	fi
	# Some hunks may have failed. Report precisely, and count rejects.
	local rej
	rej=$(find "$dir" -name '*.rej' 2>/dev/null | wc -l)
	echo "      PATCH FAILED (reject files found: $rej) -- see $log"
	sed -n '1,60p' "$log" | sed 's/^/      | /'
	return 1
}

# =============================================================================
echo "=============================================================="
echo " earth kernel: KernelSU-Next + SUSFS + Droidspaces setup"
echo "=============================================================="
echo " kernel root : $KERNEL_ROOT"
echo " KSU         : $KSU_REPO @ $KSU_REF (legacy / non-GKI mode)"
echo " SUSFS       : $SUSFS_REPO @ $SUSFS_REF"
echo

# -- Sanity check the kernel tree --------------------------------------------
for f in Makefile drivers/Kconfig drivers/Makefile arch/arm64; do
	if [ ! -e "$KERNEL_ROOT/$f" ]; then
		echo "ERROR: '$KERNEL_ROOT/$f' not found. Is KERNEL_ROOT a Linux kernel tree?"
		exit 2
	fi
done

KVER=$(sed -n 's/^VERSION *= *//p'      "$KERNEL_ROOT/Makefile" | head -n1)
KPAT=$(sed -n 's/^PATCHLEVEL *= *//p'   "$KERNEL_ROOT/Makefile" | head -n1)
KSUB=$(sed -n 's/^SUBLEVEL *= *//p'     "$KERNEL_ROOT/Makefile" | head -n1)
echo "[i] kernel version detected: ${KVER}.${KPAT}.${KSUB}"
if [ "$KVER" != "4" ] || [ "$KPAT" != "19" ]; then
	echo "ERROR: this pipeline is written for Linux 4.19.x (found ${KVER}.${KPAT})."
	echo "       SUSFS branch '$SUSFS_REF' and the Droidspaces non-GKI patches target 4.19."
	exit 2
fi
echo

# =============================================================================
# 1) KernelSU-Next, legacy (non-GKI) integration
# =============================================================================
# We do NOT use upstream setup.sh: it hard-resets to the repo's default branch
# and does a `git pull`, which would silently move us off the pinned release.
# Instead we replicate exactly what legacy setup.sh does, on the pinned tag.
# =============================================================================
echo "[1/4] KernelSU-Next ($KSU_REF, legacy mode)"
KSU_DIR="$KERNEL_ROOT/KernelSU"

if [ -d "$KSU_DIR" ]; then
	echo "   -> removing pre-existing $KSU_DIR"
	rm -rf "$KSU_DIR"
fi

git clone --depth 1 --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR"
KSU_DESC=$(git -C "$KSU_DIR" describe --tags --always 2>/dev/null || echo "$KSU_REF")
echo "   -> cloned $KSU_DESC"

# The "kernel/Kconfig" file is what the SUSFS KSU-side patch expects to patch.
if [ ! -f "$KSU_DIR/kernel/Kconfig" ]; then
	fail_critical "KernelSU-Next legacy layout not found: $KSU_DIR/kernel/Kconfig is missing."
	echo "   directory listing of $KSU_DIR:"
	ls -la "$KSU_DIR" | sed 's/^/      /' || true
else
	echo "   -> legacy layout confirmed (kernel/Kconfig present)"
fi

# Provide the exact paths legacy setup.sh creates.
ln -sfn "$KSU_DIR/kernel" "$KERNEL_ROOT/drivers/kernelsu"
echo "   -> symlink: drivers/kernelsu -> KernelSU/kernel"

if ! grep -q 'kernelsu' "$KERNEL_ROOT/drivers/Makefile"; then
	printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$KERNEL_ROOT/drivers/Makefile"
	echo "   -> drivers/Makefile updated"
fi
if ! grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_ROOT/drivers/Kconfig"; then
	sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_ROOT/drivers/Kconfig"
	echo "   -> drivers/Kconfig updated"
fi
echo

# =============================================================================
# 2) SUSFS
# =============================================================================
echo "[2/4] SUSFS ($SUSFS_REF)"
SUSFS_SRC="$KERNEL_ROOT/.susfs4ksu"

if [ -d "$SUSFS_SRC" ]; then rm -rf "$SUSFS_SRC"; fi
if ! git clone --depth 1 --branch "$SUSFS_REF" "$SUSFS_REPO" "$SUSFS_SRC"; then
	fail_critical "could not clone SUSFS branch '$SUSFS_REF' from $SUSFS_REPO"
else
	SUSFS_KP="$SUSFS_SRC/kernel_patches"

	# 2a) KernelSU-side glue patch (creates the CONFIG_KSU_SUSFS_* menu)
	if [ -f "$SUSFS_KP/KernelSU/10_enable_susfs_for_ksu.patch" ]; then
		cp "$SUSFS_KP/KernelSU/10_enable_susfs_for_ksu.patch" "$KSU_DIR/10_enable_susfs_for_ksu.patch"
		if ! apply_patch "$KSU_DIR" "$KSU_DIR/10_enable_susfs_for_ksu.patch" \
				"KernelSU SUSFS glue (10_enable_susfs_for_ksu)" \
				"$KERNEL_ROOT/.patch-ksu-susfs.log"; then
			fail_critical "SUSFS->KernelSU glue patch did not apply cleanly."
			echo "      The SUSFS 4.19 branch targets an older KernelSU-Next."
			echo "      Rejects that matter most (symbol renames):"
			echo "        is_manager -> ksu_is_manager, escape_to_root -> ksu_escape_to_root,"
			echo "        setup_selinux -> ksu_setup_selinux, kernelsu_init -> ksu_kernelsu_init,"
			echo "        on_post_fs_data -> ksu_on_post_fs_data, track_throne -> ksu_track_throne,"
			echo "        handle_sepolicy -> ksu_handle_sepolicy, apply_kernelsu_rules -> ksu_apply_kernelsu_rules,"
			echo "        is_manager_apk -> ksu_is_manager_apk, is_zygote -> ksu_is_zygote,"
			echo "        is_ksu_domain -> ksu_is_ksu_domain, getenforce -> ksu_getenforce"
		fi
	else
		fail_critical "missing $SUSFS_KP/KernelSU/10_enable_susfs_for_ksu.patch"
	fi

	# 2b) Kernel-side susfs implementation
	if [ -f "$SUSFS_KP/50_add_susfs_in_kernel-4.19.patch" ]; then
		if ! apply_patch "$KERNEL_ROOT" "$SUSFS_KP/50_add_susfs_in_kernel-4.19.patch" \
				"kernel susfs core (50_add_susfs_in_kernel-4.19)" \
				"$KERNEL_ROOT/.patch-kernel-susfs.log"; then
			fail_critical "kernel-side SUSFS patch did not apply cleanly."
		fi
	else
		fail_critical "missing $SUSFS_KP/50_add_susfs_in_kernel-4.19.patch"
	fi

	# 2c) susfs sources.
	# The SUSFS patches add #include <linux/susfs.h> / <linux/susfs_def.h> and
	# build fs/susfs.c, but the patch files do NOT carry the header bodies for
	# every kernel version, so they must be copied in explicitly.
	# If any of these is missing the build fails much later with a confusing
	# "use of undeclared identifier INODE_STATE_*" error, so verify hard here.
	echo "   -> installing susfs sources/headers"
	install_one() {
		local src="$1" dst="$2"
		if [ ! -f "$src" ]; then
			fail_critical "missing SUSFS file: $src"
			return 1
		fi
		cp -v "$src" "$dst"
		return 0
	}

	install_one "$SUSFS_KP/fs/susfs.c"                    "$KERNEL_ROOT/fs/susfs.c"
	install_one "$SUSFS_KP/include/linux/susfs.h"         "$KERNEL_ROOT/include/linux/susfs.h"
	install_one "$SUSFS_KP/include/linux/susfs_def.h"     "$KERNEL_ROOT/include/linux/susfs_def.h"
	# sus_su.h is referenced by some SUSFS versions; copy when present.
	if [ -f "$SUSFS_KP/include/linux/sus_su.h" ]; then
		cp -v "$SUSFS_KP/include/linux/sus_su.h" "$KERNEL_ROOT/include/linux/sus_su.h"
	fi

	# Prove the macros the patched kernel actually uses are reachable.
	echo "   -> verifying critical SUSFS macros are defined in the tree:"
	for MACRO in INODE_STATE_SUS_PATH INODE_STATE_SUS_MOUNT INODE_STATE_SUS_KSTAT \
	             INODE_STATE_OPEN_REDIRECT TASK_STRUCT_NON_ROOT_USER_APP_PROC; do
		if grep -q "^#define[[:space:]]*$MACRO" "$KERNEL_ROOT/include/linux/susfs_def.h" 2>/dev/null; then
			echo "        OK      $MACRO"
		else
			fail_critical "$MACRO is not defined in include/linux/susfs_def.h"
		fi
	done

	# ---------------------------------------------------------------------
	# 4.19 compatibility check for susfs_def.h
	#
	# susfs_def.h begins with "#include <linux/bits.h>" and then uses BIT().
	# On 4.19 that header exists but may not provide BIT(), in which case the
	# whole header body fails and every macro becomes undeclared -- which
	# surfaces much later as:
	#     fs/proc/task_mmu.c: error: use of undeclared identifier
	#                          'INODE_STATE_SUS_KSTAT'
	# Instead of assuming, print the evidence and only rewrite when it is
	# provably needed.
	# ---------------------------------------------------------------------
	echo "   -> BIT() availability diagnostics:"
	if [ -f "$KERNEL_ROOT/include/linux/bits.h" ]; then
		if grep -Eq '#define[[:space:]]+BIT\(' "$KERNEL_ROOT/include/linux/bits.h"; then
			echo "        bits.h exists and defines BIT() -> nothing to do"
		else
			echo "        bits.h exists but does NOT define BIT()"
			echo "        bits.h includes:"
			grep -E '^#include' "$KERNEL_ROOT/include/linux/bits.h" | sed 's/^/          /'
			if grep -Eq '#define[[:space:]]+BIT\(' "$KERNEL_ROOT/include/linux/bitops.h"; then
				echo "        BIT() found in <linux/bitops.h> -> pointing susfs_def.h at it"
				sed -i 's#include <linux/bits.h>#include <linux/bitops.h>#' \
					"$KERNEL_ROOT/include/linux/susfs_def.h"
				sed -i 's#include <linux/bits.h>#include <linux/bitops.h>#' \
					"$KERNEL_ROOT/include/linux/susfs.h" 2>/dev/null || true
				echo "        -> after fix, susfs_def.h includes:"
				grep -E '^#include' "$KERNEL_ROOT/include/linux/susfs_def.h" | sed 's/^/          /'
			else
				fail_critical "BIT() is not defined in bits.h or bitops.h - SUSFS cannot build"
			fi
		fi
	else
		echo "        include/linux/bits.h is absent (pre-5.0 tree)"
		if grep -Eq '#define[[:space:]]+BIT\(' "$KERNEL_ROOT/include/linux/bitops.h"; then
			echo "        BIT() found in <linux/bitops.h> -> switching susfs_def.h over"
			sed -i 's#include <linux/bits.h>#include <linux/bitops.h>#' \
				"$KERNEL_ROOT/include/linux/susfs_def.h"
		else
			fail_critical "BIT() is not defined in include/linux/bitops.h"
		fi
	fi

	if [ ! -f "$KERNEL_ROOT/fs/susfs.c" ]; then
		fail_critical "fs/susfs.c was not installed"
	fi
	if [ ! -f "$KERNEL_ROOT/include/linux/susfs.h" ]; then
		fail_critical "include/linux/susfs.h was not installed"
	fi

	SUSFS_VER=$(grep -E '^#define SUSFS_VERSION' "$KERNEL_ROOT/include/linux/susfs.h" 2>/dev/null | head -n1 || true)
	echo "   -> ${SUSFS_VER:-<SUSFS_VERSION not found>}"
fi
echo

# =============================================================================
# 3) Droidspaces non-GKI kernel patches
# =============================================================================
echo "[3/4] Droidspaces patches (non-GKI)"
mkdir -p "$PATCH_DIR"

DL_OK=1
if [ ! -f "$PATCH_DIR/01.fix_kernel_panic_in_xt_qtaguid.patch" ] ||
   [ ! -f "$PATCH_DIR/02.fix_restore_cgroup_file_prefix_handling.patch" ]; then
	DL_OK=0
fi

if [ "$DL_OK" -eq 1 ]; then
	echo "   -> using vendored patches from $PATCH_DIR"
	# These are Droidspaces compatibility fixes, unrelated to root hiding.
	# If they do not apply, containers still work on most kernels -- not fatal.
	apply_patch "$KERNEL_ROOT" "$PATCH_DIR/01.fix_kernel_panic_in_xt_qtaguid.patch" \
		"xt_qtaguid kernel-panic fix" "$KERNEL_ROOT/.patch-ds-01.log" ||
		note_warning "Droidspaces patch 01 did not apply (non-fatal)."
	apply_patch "$KERNEL_ROOT" "$PATCH_DIR/02.fix_restore_cgroup_file_prefix_handling.patch" \
		"cgroup prefix fix" "$KERNEL_ROOT/.patch-ds-02.log" ||
		note_warning "Droidspaces patch 02 did not apply (non-fatal)."
else
	note_warning "vendored Droidspaces patches missing in $PATCH_DIR - skipped."
fi
echo

# =============================================================================
# 4) Config: KernelSU + SUSFS switches + Droidspaces fragment
# =============================================================================
echo "[4/4] Kernel configuration"

# 4a) KernelSU / SUSFS switches go straight into the device defconfig.
DEFCONFIG_NAME="${DEFCONFIG:-earth}_defconfig"
DEFCONFIG="$KERNEL_ROOT/arch/arm64/configs/$DEFCONFIG_NAME"
if [ ! -f "$DEFCONFIG" ]; then
	echo "   available defconfigs:"
	ls "$KERNEL_ROOT/arch/arm64/configs" | sed 's/^/      /'
	fail_critical "defconfig not found: $DEFCONFIG"
else
	# Remove any previous block so re-runs stay idempotent.
	sed -i '/^# >>> earth-ksu-susfs >>>$/,/^# <<< earth-ksu-susfs <<<$/d' "$DEFCONFIG"

	cat >>"$DEFCONFIG" <<'EOF'

# >>> earth-ksu-susfs >>>
# KernelSU-Next (non-GKI / legacy integration)
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_KSU_KPROBE_HOOKS=y
CONFIG_EXT4_FS=y
CONFIG_MODULES=y

# SUSFS
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
# <<< earth-ksu-susfs <<<
EOF
	echo "   -> KernelSU + SUSFS switches appended to earth_defconfig"

	# 4b) Keep the device's own local version string, but make builds
	#     reproducible: CONFIG_LOCALVERSION_AUTO adds the git SHA/date to
	#     the kernel release and recomputes the module vermagic.
	#     "-perf" is retained to stay as close to the vendor string as possible.
	sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$DEFCONFIG"
	echo "   -> LOCALVERSION_AUTO disabled (reproducible vermagic, LOCALVERSION kept)"
fi

# 4c) Droidspaces config fragment is merged during the build step.
if [ -f "$FRAGMENT" ]; then
	echo "   -> Droidspaces fragment staged: $FRAGMENT"
else
	fail_critical "Droidspaces fragment not found at $FRAGMENT"
fi
echo

# =============================================================================
echo "=============================================================="
if [ "$CRITICAL_FAILURES" -gt 0 ]; then
	echo " RESULT: FAILED ($CRITICAL_FAILURES critical problem(s), $WARNINGS warning(s))"
	echo "=============================================================="
	exit 1
fi
echo " RESULT: OK ($WARNINGS warning(s))"
echo "=============================================================="
