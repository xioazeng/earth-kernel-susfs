#!/usr/bin/env bash
# =============================================================================
#  setup-kernel.sh
#  Inserts KernelSU (+SUSFS) and Droidspaces support into the LineageOS
#  android_kernel_xiaomi_earth tree (Linux 4.19, non-GKI, MT6768 "earth").
#
#  Usage:  ./setup-kernel.sh /path/to/kernel/root
#
#  Order matters and is deliberate:
#    1) KernelSU (SUSFS-native fork, old layout) -> kernel/ + drivers/kernelsu
#       plus the 4.19 compatibility fixups described in section 1a/1b below
#    2) SUSFS kernel-side patch (susfs4ksu kernel-4.19) -> requires the KSU tree
#       from (1); the KSU-side half is already inside the fork
#    3) Droidspaces non-GKI patches               -> independent kernel patches
#    4) Droidspaces config fragment               -> merged at config time
#
#  Environment knobs:
#    KSU_REF       KernelSU ref to check out   (default: susfs-rksu-master)
#    KSU_REPO      KernelSU repository         (default: rsuntk/KernelSU)
#    SUSFS_ENABLE  1 | 0                       (default: 1, see section 2)
#    DEFCONFIG     defconfig name without _defconfig (default: earth)
# =============================================================================
set -euo pipefail

KERNEL_ROOT="${1:-$(pwd)}"
KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"

# ---------------------------------------------------------------------------
# KernelSU source: a fork that has SUSFS *built into* its kernel code.
#
# Why not KernelSU-Next?
#   * KernelSU-Next's own SUSFS is a loadable module built against DDK/GKI
#     headers (kernel/susfs/Makefile: "obj-m += susfs_guard_lkm.o", "Build
#     against DDK kernel headers") -- impossible on a non-GKI 4.19 kernel that
#     is built from source.
#   * Its `legacy` branch (the non-GKI one) has no SUSFS support at all, and the
#     classic susfs4ksu glue patch targets the *old* KernelSU layout
#     (kernel/core_hook.c, ksu.c, allowlist.c, supercalls via prctl) which no
#     longer exists there: measured 0/58 hunks applicable.
#   * The non-GKI community build project (NootFond/NonGKI_Kernel_Build_mix2s)
#     marks KernelSU-Next "Not Supported" for SUSFS and lists 4.19 + SuSFS as
#     working with the SUSFS-native forks instead.
#
# rsuntk/KernelSU branch `deprecated/susfs-legacy` is the one that MATCHES the
# frozen 4.19 SUSFS line (v1.5.5):
#   * old KernelSU layout (core_hook.c, ksu.c, ksud.c, allowlist.c, sucompat.c)
#     = what the classic susfs4ksu design expects, and its SUSFS command
#     handlers live in kernel/core_hook.c;
#   * kernel/Kconfig carries the full classic SUSFS menu, including
#     KSU_SUSFS_HAS_MAGIC_MOUNT / KSU_SUSFS_AUTO_ADD_* / KSU_SUSFS_SUS_OVERLAYFS;
#   * kernel/Makefile already does the non-GKI backports (path_umount, seccomp
#     filter_count) and requires fs/susfs.c;
#   * KSU_VERSION 12311 = the KernelSU generation SUSFS 4.19 was written for.
#
# Why not the newer `susfs-rksu-master`: it tracks SUSFS 2.x, and a symbol-by-
# symbol comparison against the 4.19 SUSFS headers leaves 13 undefined functions
# (susfs_add_sus_map, susfs_set_avc_log_spoofing, susfs_add_sus_path_loop,
# susfs_set_current_proc_umounted, ...) because there is no SUSFS 2.x branch for
# 4.19 at all. `deprecated/susfs-legacy` leaves 0.
KSU_REPO="${KSU_REPO:-https://github.com/Oscar1640/android_kernel_xiaomi_earth.git}"
KSU_REF="${KSU_REF:-ksu-next}"
# NOTE: this is a whole kernel tree, not a KernelSU-only repo -- the KernelSU
# sources live in drivers/kernelsu/ and are sparse-cloned from it (step 1).

# KernelSU hooks: this layout has no hook-mode Kconfig choice -- it uses the
# kernel's kprobes (CONFIG_KPROBES) plus LSM hooks, which is what 4.19 needs.

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
	# --fuzz=0 is deliberate: with the default fuzz, patch can land a hunk in a
	# place that merely "looks similar", which is how the SUSFS sched.h hunk got
	# applied 175 lines away from where it belonged (inside the
	# "#ifdef __GENKSYMS__" block) and then defeated the repair that follows.
	# Exact context only: anything that does not match is left as a .rej for the
	# explicit repairs below to handle deterministically.
	if (cd "$dir" && patch -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch <"$file" >"$log" 2>&1); then
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
echo " earth kernel: KernelSU + SUSFS + Droidspaces setup"
echo "=============================================================="
echo " kernel root : $KERNEL_ROOT"
echo " KSU         : $KSU_REPO @ $KSU_REF (SUSFS-native, old layout / non-GKI)"
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
# 1) KernelSU (SUSFS-native fork, old layout / non-GKI)
# =============================================================================
# We do NOT use upstream setup.sh: it hard-resets to the repo's default branch
# and does a `git pull`, which would silently move us off the pinned release.
# Instead we replicate exactly what legacy setup.sh does, on the pinned tag.
# =============================================================================
echo "[1/4] KernelSU ($KSU_REF)"
KSU_DIR="$KERNEL_ROOT/KernelSU"

# If the kernel tree being built already ships KernelSU (for example a MIUI
# kernel tree with drivers/kernelsu committed), use that copy untouched. The
# clone below would otherwise fight with the in-tree sources -- and on such a
# tree the in-tree copy is the one whose protocol matches the kernel.
if [ -f "$KERNEL_ROOT/drivers/kernelsu/Kconfig" ] && [ -f "$KERNEL_ROOT/drivers/kernelsu/Makefile" ]; then
	echo "   -> kernel tree already carries KernelSU (drivers/kernelsu), using it as-is"
	KSU_SRC="$KERNEL_ROOT/drivers/kernelsu"
	KSU_DESC="in-tree (from $(basename "$KERNEL_ROOT"))"
	KSU_SHA=$(git -C "$KERNEL_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
	KSU_BRANCH="in-tree"
	echo "   -> in-tree KernelSU at $KSU_SRC (sha=$KSU_SHA)"
else

if [ -d "$KSU_DIR" ]; then
	echo "   -> removing pre-existing $KSU_DIR"
	rm -rf "$KSU_DIR"
fi

# Sparse + blobless clone: the source repo is a ~1.9 GB kernel tree and we only
# need drivers/kernelsu. The commit history is kept on purpose -- this
# generation of kernel/Makefile derives KSU_VERSION from
#     git rev-list --count HEAD
# so a --depth 1 clone would report version 10199 and the manager would call the
# kernel too old. Blobs are fetched on demand, so the checkout stays tiny.
if ! git clone --filter=blob:none --sparse --branch "$KSU_REF" "$KSU_REPO" "$KSU_DIR" 2>/dev/null; then
	echo "   -> sparse/filtered clone unavailable, retrying as a commit/plain clone"
	rm -rf "$KSU_DIR"
	if ! git clone --branch "$KSU_REF" --single-branch "$KSU_REPO" "$KSU_DIR" 2>/dev/null; then
		git clone --filter=blob:none "$KSU_REPO" "$KSU_DIR"
		git -C "$KSU_DIR" checkout --detach "$KSU_REF"
	fi
fi
git -C "$KSU_DIR" sparse-checkout set drivers/kernelsu 2>/dev/null || true

KSU_SRC="$KSU_DIR/drivers/kernelsu"
KSU_DESC=$(git -C "$KSU_DIR" describe --tags --always 2>/dev/null || echo "$KSU_REF")
KSU_SHA=$(git -C "$KSU_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
KSU_BRANCH=$(git -C "$KSU_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)
KSU_GITCOUNT=$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
echo "   -> cloned $KSU_DESC  (ref=$KSU_BRANCH sha=$KSU_SHA)"
echo "   -> commit count $KSU_GITCOUNT => KernelSU version $((10000 + KSU_GITCOUNT + 198)) (manager must be >= this)"

# KernelSU-Next 1.0.x layout: Kconfig, Makefile and the .c files sit directly
# in the directory we symlink into the kernel tree.
if [ ! -f "$KSU_SRC/Kconfig" ] || [ ! -f "$KSU_SRC/Makefile" ]; then
	fail_critical "KernelSU sources not found: $KSU_SRC/{Kconfig,Makefile} missing."
	echo "   listing of $KSU_DIR:"
	ls -la "$KSU_DIR" | sed 's/^/      /' || true
	echo "   listing of $KSU_SRC:"
	ls -la "$KSU_SRC" 2>/dev/null | sed 's/^/      /' || true
else
	echo "   -> KernelSU sources confirmed ($KSU_SRC)"
fi
fi  # end: in-tree KernelSU vs. sparse-cloned KernelSU

# This KernelSU generation derives its version from
#     git rev-list --count HEAD
# which is meaningless here: with a shallow kernel clone it reports 1 (version
# 10199 => "kernel too old" for the manager), and when the number comes from the
# whole kernel history it reports nonsense such as 835856. Pin it to the version
# of the manager generation that is known to work with this kernel.
if grep -q 'eval KSU_VERSION' "$KSU_SRC/Makefile" 2>/dev/null; then
	sed -i 's|^$(eval KSU_VERSION=.*$|$(eval KSU_VERSION=12701)|' "$KSU_SRC/Makefile"
	echo "   -> pinned KSU_VERSION=12701 (manager v1.0.8 era)"
fi

# -----------------------------------------------------------------------------
# 1a) SUSFS preflight.
#
# This kit deliberately uses a KernelSU fork that has the SUSFS plumbing already
# inside its kernel code (see the header comment). Verify that here: building a
# KSU without it and then wondering why ksu_susfs cannot talk to the kernel is
# the exact failure this check exists to prevent.
# -----------------------------------------------------------------------------
KSU_SUSFS_OK=1
if ! grep -q 'config KSU_SUSFS$' "$KSU_SRC/Kconfig" 2>/dev/null; then
	KSU_SUSFS_OK=0
fi
# The command handlers moved between generations (core_hook.c here, supercalls.c
# in the newer SUSFS-2.x branches), so search the whole kernel tree.
if ! grep -rqs 'CMD_SUSFS_ADD_SUS_PATH' "$KSU_SRC" 2>/dev/null; then
	KSU_SUSFS_OK=0
fi
if [ "$KSU_SUSFS_OK" -eq 1 ]; then
	echo "   -> SUSFS plumbing confirmed (Kconfig menu + CMD_SUSFS_* handlers)"
else
	fail_critical "ref '$KSU_REF' has no built-in SUSFS plumbing."
	echo "      Expected a SUSFS-native branch whose command set matches the"
	echo "      frozen 4.19 SUSFS line (v1.5.5), e.g. rsuntk/KernelSU"
	echo "      'deprecated/susfs-legacy' (kernel/Kconfig: 'config KSU_SUSFS',"
	echo "      kernel/core_hook.c: CMD_SUSFS_*). Branches tracking SUSFS 2.x"
	echo "      (e.g. susfs-rksu-master) call functions 4.19 does not provide."
fi

# -----------------------------------------------------------------------------
# 1b) Linux 4.19 compatibility fixups applied to the KernelSU sources.
#
#     (i)  arm64 kernels before 5.10 do not provide user_stack_pointer(), yet
#          include/linux/ptrace.h defines current_user_stack_pointer() on top of
#          it. sucompat.c (userspace_stack_buffer) uses it, so the build stops
#          with "call to undeclared function 'user_stack_pointer'".
#          Inject the upstream v5.10 arm64 implementation -- but only when the
#          kernel tree really does not define it (verified by grep, not assumed).
#     (ii) an unguarded "#include <linux/pgtable.h>" (the header appeared in 5.8)
#          cannot resolve on 4.19; asm/pgtable.h is its 4.19 equivalent.
#
#     Both fixups are idempotent and printed, so a re-run is harmless.
# -----------------------------------------------------------------------------
# The arch header moved between KernelSU generations: kernel/arch.h (old layout,
# what this kit uses) vs kernel/include/arch.h (v3 layout).
if [ -f "$KSU_SRC/include/arch.h" ]; then
	KSU_INC_DIR="$KSU_SRC/include"
else
	KSU_INC_DIR="$KSU_SRC"
fi
KSU_ARCH_H="$KSU_INC_DIR/arch.h"
KSU_419_H="$KSU_INC_DIR/ksu_419_compat.h"
echo "   -> KernelSU arch header: $KSU_ARCH_H"

if [ -f "$KSU_ARCH_H" ]; then
	# Look for an actual DEFINITION, not for a use: include/linux/ptrace.h on
	# this tree defines "#define current_user_stack_pointer() \
	# user_stack_pointer(current_pt_regs())", which mentions the name without
	# providing it. Only "#define user_stack_pointer" or a
	# "user_stack_pointer(struct pt_regs ..." definition counts.
	if grep -rEqs '#define[[:space:]]+user_stack_pointer|user_stack_pointer[[:space:]]*\(struct pt_regs' \
			"$KERNEL_ROOT/arch/arm64/include" "$KERNEL_ROOT/include" 2>/dev/null; then
		echo "   -> user_stack_pointer() already provided by the kernel tree"
	elif [ -f "$KSU_419_H" ]; then
		echo "   -> arm64 user_stack_pointer() compat already injected"
	else
		echo "   -> injecting arm64 user_stack_pointer() compat (kernel < 5.10)"
		cat >"$KSU_419_H" <<'EOF'
/* ksu_419_compat.h -- injected by the earth build kit (setup-kernel.sh).
 *
 * arm64 kernels before 5.10 do not define user_stack_pointer(), even though
 * include/linux/ptrace.h defines current_user_stack_pointer() in terms of it.
 * KernelSU's feature/sucompat.c (userspace_stack_buffer) and feature/adb_root.c
 * call it, so without this shim the module fails to compile on 4.19:
 *     error: call to undeclared function 'user_stack_pointer'
 *
 * Preference order:
 *   1. the kernel's own GET_USP() macro (present in ACK/MTK arm64 trees),
 *   2. the upstream v5.10 implementation (compat-aware),
 *   3. plain regs->sp as a last resort.
 */
#ifndef __KSU_419_COMPAT_H
#define __KSU_419_COMPAT_H

#include <linux/version.h>
#include <asm/ptrace.h>

#if defined(__aarch64__) && LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef user_stack_pointer
#if defined(GET_USP)
#define user_stack_pointer(regs) GET_USP(regs)
#elif defined(compat_sp) && defined(compat_user_mode)
static inline unsigned long user_stack_pointer(struct pt_regs *regs)
{
	if (compat_user_mode(regs))
		return (unsigned long)regs->compat_sp;
	return (unsigned long)regs->sp;
}
#else
#define user_stack_pointer(regs) ((unsigned long)((regs)->sp))
#endif
#endif
#endif

#endif /* __KSU_419_COMPAT_H */
EOF
		# Appended after arch.h's closing #endif on purpose: ksu_419_compat.h
		# carries its own include guard, so repeated inclusion is a no-op.
		printf '\n#include "ksu_419_compat.h"\n' >>"$KSU_ARCH_H"
		if grep -q 'ksu_419_compat.h' "$KSU_ARCH_H" && [ -f "$KSU_419_H" ]; then
			echo "      verified: ksu_419_compat.h created and hooked into arch.h"
		else
			fail_critical "could not install the arm64 user_stack_pointer() compat header"
		fi
	fi
else
	fail_critical "missing $KSU_ARCH_H - unexpected KernelSU layout"
fi

if [ ! -f "$KERNEL_ROOT/include/linux/pgtable.h" ]; then
	PG_FIXED=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		# Skip includes that are already behind a LINUX_VERSION_CODE guard.
		if grep -B3 '^#include <linux/pgtable.h>$' "$f" | grep -q 'KERNEL_VERSION'; then
			continue
		fi
		sed -i 's|^#include <linux/pgtable.h>$|\/* 4.19: linux/pgtable.h is 5.8+, asm/pgtable.h is the local equivalent *\/\n#include <asm/pgtable.h>|' "$f"
		echo "      patched $f"
		PG_FIXED=$((PG_FIXED + 1))
	done < <(grep -rl '^#include <linux/pgtable.h>$' "$KSU_SRC" 2>/dev/null || true)
	if [ "$PG_FIXED" -eq 0 ]; then
		echo "   -> no unguarded linux/pgtable.h include found (nothing to fix)"
	else
		echo "   -> linux/pgtable.h rewritten to asm/pgtable.h in $PG_FIXED file(s)"
	fi
fi

# Provide the exact paths legacy setup.sh creates.
if [ "$KSU_SRC" = "$KERNEL_ROOT/drivers/kernelsu" ]; then
	echo "   -> KernelSU already lives at drivers/kernelsu (in-tree), no symlink needed"
else
	ln -sfn "$KSU_SRC" "$KERNEL_ROOT/drivers/kernelsu"
	echo "   -> symlink: drivers/kernelsu -> $KSU_SRC"
fi

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
#
# SUSFS_ENABLE=1 (default) applies it; SUSFS_ENABLE=0 skips it entirely.
#
# Division of labour:
#   * KSU side  -- already inside the KernelSU branch we build (the KSU_SUSFS*
#                  menu in kernel/Kconfig plus the CMD_SUSFS_* handlers), verified
#                  in step 1a above. Nothing to patch here.
#   * kernel side -- the classic susfs4ksu kernel-4.19 patch set: fs/* hooks via
#                  50_add_susfs_in_kernel-4.19.patch plus fs/susfs.c and the
#                  headers, which are copied in below.
# Measured against the LineageOS earth tree: 69 of 72 hunks apply directly; the
# 3 exceptions are repaired further down (fs/proc/task_mmu.c include, and the two
# include/linux/sched.h task_struct hunks).
# =============================================================================
SUSFS_ENABLE="${SUSFS_ENABLE:-1}"

if [ "$SUSFS_ENABLE" != "1" ]; then
	echo "[2/4] SUSFS - SKIPPED (SUSFS_ENABLE=$SUSFS_ENABLE)"
	# This KSU generation only builds with the kernel-side SUSFS: core_hook.c
	# includes <linux/susfs.h> and calls susfs_* directly, so skipping SUSFS
	# means a wall of "implicit declaration" errors. Fail here with the reason
	# instead of letting the KSU compile die later.
	if grep -rqs 'linux/susfs\.h\|linux/susfs_def\.h' "$KSU_SRC" 2>/dev/null; then
		fail_critical "KSU_REF '$KSU_REF' requires the SUSFS kernel-side patch."
		echo "      Its sources include <linux/susfs.h>, so SUSFS_ENABLE=1 is"
		echo "      mandatory with this KernelSU source."
		echo "      For a root-only build, point KSU_REF at a non-SUSFS KernelSU."
	else
		echo "   -> building KernelSU without SUSFS"
	fi
	echo
else

echo "[2/4] SUSFS ($SUSFS_REF)"
SUSFS_SRC="$KERNEL_ROOT/.susfs4ksu"

if [ -d "$SUSFS_SRC" ]; then rm -rf "$SUSFS_SRC"; fi
if ! git clone --depth 1 --branch "$SUSFS_REF" "$SUSFS_REPO" "$SUSFS_SRC"; then
	fail_critical "could not clone SUSFS branch '$SUSFS_REF' from $SUSFS_REPO"
else
	SUSFS_KP="$SUSFS_SRC/kernel_patches"

	# 2a) KernelSU-side glue: NOT applied here.
	#
	# susfs4ksu ships kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch for
	# the old KernelSU layout. We no longer need it (and it does not apply to the
	# v3 KernelSU-Next layout: measured 0/58 hunks), because the KernelSU branch we
	# build already contains the whole thing -- the KSU_SUSFS* menu in
	# kernel/Kconfig and the CMD_SUSFS_* handlers (kernel/core_hook.c in this
	# generation, kernel/supercalls.c in the newer SUSFS-2.x ones). Step 1a
	# already verified that tree-wide; repeat it briefly so this stage is
	# self-contained.
	if grep -rqs 'CMD_SUSFS_ADD_SUS_PATH' "$KSU_SRC" 2>/dev/null &&
	   grep -q 'config KSU_SUSFS$' "$KSU_SRC/Kconfig" 2>/dev/null; then
		echo "   -> KernelSU SUSFS glue: provided by the KSU source itself (no patch needed)"
	else
		fail_critical "the KernelSU source in use has no SUSFS glue (see step 1a)."
	fi

	# 2b) Kernel-side susfs implementation
	if [ -f "$SUSFS_KP/50_add_susfs_in_kernel-4.19.patch" ]; then
		if ! apply_patch "$KERNEL_ROOT" "$SUSFS_KP/50_add_susfs_in_kernel-4.19.patch" \
				"kernel susfs core (50_add_susfs_in_kernel-4.19)" \
				"$KERNEL_ROOT/.patch-kernel-susfs.log"; then
			echo "      (expected: the task_mmu.c and sched.h hunks, repaired below)"
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
	# BIT() availability check.
	#
	# susfs_def.h does "#include <linux/bits.h>" and then uses BIT().
	# On 4.19, BIT() is defined in include/vdso/bits.h, which linux/bits.h
	# pulls in -- so the include chain is already correct. Check the whole
	# chain rather than assuming which file holds the definition (an earlier
	# revision only looked in bits.h/bitops.h and produced a false alarm).
	# ---------------------------------------------------------------------
	echo "   -> BIT() availability check:"
	BIT_FOUND=0
	for H in include/linux/bits.h include/vdso/bits.h include/linux/bitops.h; do
		if [ -f "$KERNEL_ROOT/$H" ] && grep -Eq '#define[[:space:]]+BIT\(' "$KERNEL_ROOT/$H"; then
			echo "        OK      BIT() defined in $H"
			BIT_FOUND=1
		fi
	done
	if [ "$BIT_FOUND" -ne 1 ]; then
		fail_critical "BIT() is not defined anywhere in include/ - SUSFS cannot build"
	else
		echo "        include chain OK (susfs_def.h -> linux/bits.h)"
	fi

	# ---------------------------------------------------------------------
	# Repair the hunks of 50_add_susfs_in_kernel-4.19.patch that failed to
	# apply against this tree.
	#
	# The patch adds "#include <linux/susfs_def.h>" to fs/proc/task_mmu.c in
	# hunk #1 of 3, which fails because the surrounding context has moved.
	# Without that include, INODE_STATE_SUS_KSTAT and friends are undeclared
	# and the kernel build stops with:
	#     fs/proc/task_mmu.c: error: use of undeclared identifier
	#                          'INODE_STATE_SUS_KSTAT'
	# The rest of the task_mmu hunks (the actual logic) DO apply, so only the
	# include line is missing. Insert it idempotently.
	# ---------------------------------------------------------------------
	TM="$KERNEL_ROOT/fs/proc/task_mmu.c"
	if [ -f "$TM" ]; then
		if grep -q 'linux/susfs_def.h' "$TM"; then
			echo "   -> fs/proc/task_mmu.c already includes susfs_def.h"
		else
			echo "   -> repairing failed hunk: adding susfs_def.h include to fs/proc/task_mmu.c"
			# Insert immediately before the first asm/ include, matching the
			# placement the original patch intended (top include block).
			if grep -q '^#include <asm/elf.h>' "$TM"; then
				sed -i '0,/^#include <asm\/elf.h>/s//#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux\/susfs_def.h>\n#endif\n#include <asm\/elf.h>/' "$TM"
				echo "        inserted before <asm/elf.h>"
			else
				# Fallback: after the last leading #include line.
				sed -i '0,/^#include/s//#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux\/susfs_def.h>\n#endif\n#include/' "$TM"
				echo "        inserted before the first include"
			fi
			if grep -q 'linux/susfs_def.h' "$TM"; then
				echo "        verified: susfs_def.h is now included"
			else
				fail_critical "could not insert susfs_def.h include into fs/proc/task_mmu.c"
			fi
		fi
	else
		fail_critical "fs/proc/task_mmu.c not found"
	fi

	# ---------------------------------------------------------------------
	# Repair the include/linux/sched.h hunks (both fail on this tree).
	#
	# 50_add_susfs_in_kernel-4.19.patch wants to turn two ANDROID_KABI_RESERVE()
	# slots of struct task_struct into ANDROID_KABI_USE(...) holding
	#     u64 susfs_task_state;
	#     u64 susfs_last_fake_mnt_id;
	# The earth tree's task_struct tail differs (it wraps reserve 6 in
	# "#ifdef __GENKSYMS__", and MTK appends CONFIG_MTK_TASK_TURBO fields), so
	# the patch's context does not match and neither hunk applies.
	#
	# On a non-GKI kernel there is no vendor kABI to preserve, so the plain
	# fields are added at the end of the randomized section instead -- the same
	# thing the patch does for kernels without ANDROID_KABI_RESERVE at all.
	# Keeping the fields inside "<start> .. <end>" is what the patch intends.
	# ---------------------------------------------------------------------
	SCHED_H="$KERNEL_ROOT/include/linux/sched.h"
	if [ -f "$SCHED_H" ]; then
		# Check each field on its own. (An earlier revision tested only
		# susfs_task_state and then skipped the whole repair -- exactly what
		# happens when patch lands hunk 1 but not hunk 2.)
		SCHED_MISSING=0
		# Insert one field, keeping the anchor line's indentation.
		add_sched_field() {
			local field="$1"
			sed -i "s|^\([[:space:]]*\)randomized_struct_fields_end[[:space:]]*\$|\1#if defined(CONFIG_KSU_SUSFS)\n\1\tu64 ${field};\n\1#endif\n\1randomized_struct_fields_end|" "$SCHED_H"
		}
		for field in susfs_task_state susfs_last_fake_mnt_id; do
			if grep -q "\b${field}\b" "$SCHED_H"; then
				echo "   -> include/linux/sched.h already has ${field}"
			elif grep -q 'randomized_struct_fields_end' "$SCHED_H"; then
				echo "   -> repairing failed hunk: adding ${field} to struct task_struct"
				add_sched_field "$field"
				if grep -q "\b${field}\b" "$SCHED_H"; then
					echo "        verified: ${field} present"
				else
					fail_critical "could not add ${field} to include/linux/sched.h"
					SCHED_MISSING=1
				fi
			else
				fail_critical "include/linux/sched.h has no randomized_struct_fields_end anchor"
				SCHED_MISSING=1
			fi
		done
		if [ "$SCHED_MISSING" -eq 0 ]; then
			echo "   -> susfs task fields OK (susfs_task_state, susfs_last_fake_mnt_id)"
		fi
	else
		fail_critical "include/linux/sched.h not found"
	fi

	# Prove the macro is now actually in scope for that translation unit:
	# the include must exist AND the identifier must be used only under a
	# guard that pulls it in.
	if grep -q 'INODE_STATE_SUS_KSTAT' "$TM" && ! grep -q 'linux/susfs_def.h' "$TM"; then
		fail_critical "task_mmu.c uses INODE_STATE_SUS_KSTAT without including susfs_def.h"
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

fi  # end SUSFS_ENABLE
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
	#
	# Patch 01 touches net/netfilter/xt_qtaguid.c. Many trees (including this
	# LineageOS 4.19 tree) no longer ship that driver at all, in which case the
	# patch can never apply and "No file to patch" is the expected, harmless
	# outcome -- not a build problem. Report it as informational, not as a
	# failure, so the log stays readable.
	if [ ! -f "$KERNEL_ROOT/net/netfilter/xt_qtaguid.c" ]; then
		echo "      skip: net/netfilter/xt_qtaguid.c is not in this tree"
		echo "            (patch 01 targets trees that still ship qtaguid; nothing to fix)"
	elif apply_patch "$KERNEL_ROOT" "$PATCH_DIR/01.fix_kernel_panic_in_xt_qtaguid.patch" \
			"xt_qtaguid kernel-panic fix" "$KERNEL_ROOT/.patch-ds-01.log"; then
		:
	else
		note_warning "Droidspaces patch 01 did not apply (non-fatal)."
	fi

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
# -----------------------------------------------------------------------------
# 3b) Vendor VINTF (FCM) requirement: CONFIG_TRACE_GPU_MEM
#
# /system/etc/vintf/compatibility_matrix.6.xml, section <kernel version="4.19.191">,
# requires CONFIG_TRACE_GPU_MEM=y. This LineageOS-based tree has no such symbol,
# and a missing requirement makes Android show
#     "There's an internal problem with your device. Contact your manufacturer
#      for details."
# at every boot. The sources are vendored in this repo (trace-gpu-mem/), taken
# from a kernel that already boots this device without that dialog.
# -----------------------------------------------------------------------------
install_trace_gpu_mem() {
	local tsrc="$SCRIPT_DIR/../trace-gpu-mem"
	if [ ! -f "$tsrc/trace_gpu_mem.c" ] || [ ! -f "$tsrc/include/trace/events/gpu_mem.h" ]; then
		fail_critical "trace-gpu-mem/ sources are missing from the kit"
		return 1
	fi
	mkdir -p "$KERNEL_ROOT/drivers/gpu/trace" "$KERNEL_ROOT/include/trace/events"
	cp -f "$tsrc/trace_gpu_mem.c" "$KERNEL_ROOT/drivers/gpu/trace/trace_gpu_mem.c"
	cp -f "$tsrc/include/trace/events/gpu_mem.h" "$KERNEL_ROOT/include/trace/events/gpu_mem.h"

	# Upstream's Kconfig entry is a prompt-less bool (only reachable through
	# `select`), which a defconfig cannot turn on. Give it a prompt and default
	# it to y so CONFIG_TRACE_GPU_MEM=y really lands in .config.
	cat >"$KERNEL_ROOT/drivers/gpu/trace/Kconfig" <<'EOF'
# SPDX-License-Identifier: GPL-2.0-only
config TRACE_GPU_MEM
	bool "GPU memory tracepoints"
	default y
	help
	  Tracepoints for GPU memory usage (trace/events/gpu_mem.h). The vendor
	  VINTF compatibility matrix of this device requires this option, so it
	  must stay enabled.
EOF
	cat >"$KERNEL_ROOT/drivers/gpu/trace/Makefile" <<'EOF'
# SPDX-License-Identifier: GPL-2.0-only
obj-$(CONFIG_TRACE_GPU_MEM) += trace_gpu_mem.o
EOF

	# hook 1: let drivers/gpu/ descend into trace/
	if ! grep -q 'CONFIG_TRACE_GPU_MEM' "$KERNEL_ROOT/drivers/gpu/Makefile" 2>/dev/null; then
		printf 'obj-$(CONFIG_TRACE_GPU_MEM)\t\t+= trace/\n' >>"$KERNEL_ROOT/drivers/gpu/Makefile"
	fi
	# hook 2: make that Kconfig visible to the config system
	if ! grep -qs 'drivers/gpu/trace/Kconfig' "$KERNEL_ROOT/drivers/Kconfig" 2>/dev/null; then
		printf '\nsource "drivers/gpu/trace/Kconfig"\n' >>"$KERNEL_ROOT/drivers/Kconfig"
	fi

	# and select it in the config we actually build with
	local dc="$KERNEL_ROOT/arch/arm64/configs/${DEFCONFIG:-earth}_defconfig"
	if [ -f "$dc" ] && ! grep -q '^CONFIG_TRACE_GPU_MEM=y$' "$dc"; then
		printf '\n# vendor VINTF requirement (driver vendored under trace-gpu-mem/)\nCONFIG_TRACE_GPU_MEM=y\n' >>"$dc"
	fi
	echo "   -> TRACE_GPU_MEM vendored (driver + Kconfig/Makefile hooks + defconfig)"
}
install_trace_gpu_mem

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

	{
		cat <<'EOF'

# >>> earth-ksu-susfs >>>
# KernelSU-Next 1.0.x (old layout / non-GKI, built into the kernel)
CONFIG_KSU=y
# This generation selects its hook style with KSU_WITH_KPROBES (kprobe hooks on
# the syscall/setuid paths). We have kprobes, so we do not need manual hooks.
CONFIG_KSU_WITH_KPROBES=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_EXT4_FS=y
CONFIG_MODULES=y
EOF
	} >>"$DEFCONFIG"

	if [ "$SUSFS_ENABLE" = "1" ]; then
		cat >>"$DEFCONFIG" <<'EOF'

# SUSFS -- the menu this KernelSU generation defines in drivers/kernelsu/Kconfig
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
CONFIG_KSU_SUSFS_SUS_SU=y
EOF
	fi

	cat >>"$DEFCONFIG" <<'EOF'
# <<< earth-ksu-susfs <<<
EOF

	if [ "$SUSFS_ENABLE" = "1" ]; then
		echo "   -> KernelSU + SUSFS switches appended to $DEFCONFIG_NAME"
	else
		echo "   -> KernelSU switches appended to $DEFCONFIG_NAME (SUSFS disabled)"
	fi

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
