#!/usr/bin/env bash
# =============================================================================
#  repack-bootimg.sh -- replace the kernel inside the STOCK boot.img
#
#  Why this instead of AnyKernel3:
#    boot.img for this device is a raw-kernel (non-GKI) image: no vendor_boot,
#    no generic ramdisk split. The safest way to change the kernel is to take
#    the user's original boot.img, keep its ramdisk + header + cmdline
#    untouched, and swap only the kernel payload. That is exactly what
#    magiskboot does, and it is how KernelSU boot images are normally made.
#
#  Usage:
#    ./repack-bootimg.sh <stock_boot.img> <new_kernel> [output_boot.img] [dtb]
#
#  <new_kernel> may be Image.gz-dtb (preferred), Image.gz, or Image.
# =============================================================================
set -euo pipefail

BOOT_IN="${1:?usage: repack-bootimg.sh <stock_boot.img> <new_kernel> [out.img] [dtb]}"
KERNEL_IN="${2:?usage: repack-bootimg.sh <stock_boot.img> <new_kernel> [out.img] [dtb]}"
BOOT_OUT="${3:-boot-new.img}"
DTB_IN="${4:-}"

# ---------------------------------------------------------------------------
# Resolve every path to an absolute one BEFORE we chdir into the temp workdir.
#
# magiskboot only works on the current directory, so this script cd's away --
# and any relative argument the caller passed then points somewhere else. That
# is exactly what broke the last run:
#     cp: cannot stat 'kernel/dist/Image.gz-dtb': No such file or directory
# (the caller passed a repo-relative path; the script had already cd'ed to /tmp).
# realpath -m also tolerates not-yet-existing output paths.
# ---------------------------------------------------------------------------
abspath() {
	local p="$1"
	if command -v realpath >/dev/null 2>&1; then
		local r
		if r="$(realpath -m -- "$p" 2>/dev/null)"; then
			printf '%s\n' "$r"
			return 0
		fi
	fi
	case "$p" in
	/*) printf '%s\n' "$p" ;;
	*) printf '%s/%s\n' "$PWD" "$p" ;;
	esac
}

BOOT_IN="$(abspath "$BOOT_IN")"
KERNEL_IN="$(abspath "$KERNEL_IN")"
BOOT_OUT="$(abspath "$BOOT_OUT")"
if [ -n "$DTB_IN" ]; then
	DTB_IN="$(abspath "$DTB_IN")"
fi

if [ ! -f "$BOOT_IN" ]; then echo "ERROR: stock boot.img not found: $BOOT_IN"; exit 2; fi
if [ ! -f "$KERNEL_IN" ]; then echo "ERROR: kernel image not found: $KERNEL_IN"; exit 2; fi
if ! command -v magiskboot >/dev/null 2>&1; then
	echo "ERROR: magiskboot not in PATH. Download it from the Magisk release:"
	echo "       https://github.com/topjohnwu/Magisk/releases  (lib/arm64-v8a/magiskboot for arm64)"
	exit 2
fi

WORK="$(mktemp -d)"
echo "workdir: $WORK"

# magiskboot operates on the current directory
cp "$BOOT_IN" "$WORK/boot.img"
cd "$WORK"

echo
echo "=== 1) Unpacking stock boot.img ==="
magiskboot unpack boot.img

echo
echo "=== 2) Stock boot contents ==="
ls -la | sed 's/^/    /'
if [ -f kernel ]; then
	echo "    stock kernel size : $(stat -c%s kernel) bytes"
	strings kernel 2>/dev/null | grep -m1 'Linux version' | sed 's/^/    stock kernel ver  : /' || true
fi
if [ -f dtb ]; then
	echo "    stock dtb size    : $(stat -c%s dtb) bytes"
fi
if [ -f ramdisk.cpio ]; then
	echo "    ramdisk present   : yes (preserved unchanged)"
else
	echo "    ramdisk present   : no"
fi

# ---------------------------------------------------------------------------
# Kernel payload can only be replaced wholesale: the boot header stores a
# single kernel size field, and magiskboot rewrites it.
# ---------------------------------------------------------------------------
echo
echo "=== 3) Replacing kernel ==="
rm -f kernel
cp "$KERNEL_IN" kernel
echo "    new kernel size   : $(stat -c%s kernel) bytes"
strings kernel 2>/dev/null | grep -m1 'Linux version' | sed 's/^/    new kernel ver    : /' || true

# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE means the DTB is already glued to the
# kernel, so the boot.img dtb field is normally left as-is. Only overwrite it
# when an explicit dtb was passed in.
if [ -n "$DTB_IN" ]; then
	if [ -f "$DTB_IN" ]; then
		echo "    replacing boot.img dtb with: $DTB_IN"
		cp "$DTB_IN" dtb
	else
		echo "    WARNING: dtb argument '$DTB_IN' not found, keeping stock dtb"
	fi
elif [ -f dtb ]; then
	echo "    keeping stock boot.img dtb (kernel already carries appended DTB)"
fi

echo
echo "=== 4) Repacking ==="
# --orig is not used: we deliberately keep the stock ramdisk and header.
magiskboot repack boot.img
if [ ! -f new-boot.img ]; then
	echo "ERROR: magiskboot did not produce new-boot.img"
	exit 3
fi

# BOOT_OUT is absolute (resolved above), so this works from inside $WORK.
mkdir -p "$(dirname "$BOOT_OUT")"
cp new-boot.img "$BOOT_OUT"
echo
echo "=== 5) Result ==="
echo "    output        : $BOOT_OUT"
[ -f "$BOOT_OUT" ] && echo "    size          : $(stat -c%s "$BOOT_OUT") bytes"
echo "    stock size    : $(stat -c%s "$BOOT_IN") bytes"

echo
echo "=== 6) Verify repacked image ==="
# Copy the packed image back into the workdir and let magiskboot parse it: this
# is the cheapest end-to-end sanity check that the header is still readable.
cp "$BOOT_OUT" verify.img
if magiskboot unpack verify.img >/dev/null 2>&1; then
	echo "    unpack of repacked image: OK"
else
	echo "    WARNING: magiskboot could not re-unpack the repacked image"
fi

echo
echo "Done. Flash with:"
echo "    fastboot flash boot $(basename "$BOOT_OUT")"
echo
echo "WARNING: booting a repacked raw-kernel boot.img on a MediaTek device"
echo "         with a locked/rolled-back AVB state may need:"
echo "           fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification"
echo "         (or your device's usual vbmeta procedure)."
