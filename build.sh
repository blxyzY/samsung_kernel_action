#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration ---
SECONDS=0
USER="rsuntk"
HOSTNAME="yukiprjkt-lab"
DEVICE_TARGET=${DEVICE_TARGET:-"a12snsxx"}
TC_DIR="$HOME/neutron-clang"
OUT_DIR="$(pwd)/out"
KCFLAGS_W=${KCFLAGS_W:-"false"}

# Colors for output
export TERM=xterm
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
reset='\033[0m'

msg() { echo -e "${blue}INFO: ${reset}$1"; }
error() {
    echo -e "${red}ERROR: ${reset}$1"
    exit 1
}

# --- Telegram Function ---
send_telegram() {
    local file="$1"
    local md5="$2"
    local time="$(($3 / 60))"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        msg "Telegram credentials missing. Skipping upload."
        return
    fi

    local msg_bar="Device: ${DEVICE_TARGET}
MD5: ${md5}

Build done in ${time} minutes"

    msg "Uploading to Telegram..."
    curl -s -F document=@$file "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=markdownv2" \
        -F caption="$msg_bar"
    msg "Upload completed!"
}

# --- Dependencies Setup ---
setup_deps() {
    local deps_lists=(aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget)
    sudo apt update -y
    sudo apt install "${deps_lists[@]}" -y
    sudo aptitude install libssl-dev -y
}

# --- Toolchain Setup ---
_setup_toolchain() {
    #msg "Downloading AOSP-LLVM 21.0.0..."
    #wget -q https://www.kernel.org/pub/tools/crosstool/files/bin/x86_64/15.2.0/x86_64-gcc-15.2.0-nolibc-aarch64-linux.tar.gz -O /tmp/gcc.tar.gz
    #wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/d0e0a3882edb1acc193263ae98fce706e82aca38/clang-r574158.tar.gz -O /tmp/clang.tar.gz
    #git clone --depth=1 --single-branch https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b.git $TC_DIR
    msg "Downloading Neutron Clang 23 ..."
    wget -q https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/26052026/neutron-clang-26052026.tar.zst -O /tmp/neutron.tar.zst
    [ ! -d "$TC_DIR" ] && mkdir -p "$TC_DIR"
    #tar -xzf /tmp/clang.tar.* -C "$TC_DIR"
    #rm /tmp/clang.tar.*
    tar -xvf /tmp/neutron.tar.zst -C "$TC_DIR"
    msg "Toolchain extracted to $TC_DIR"
}

setup_toolchain() {
    if [ "$UPDATE_TOOLCHAINS" = "true" ]; then
        msg "Cleaning up old toolchains cache.."
        rm -rf $TC_DIR
        if [ -d ~/.ccache ]; then
            rm -rf ~/.ccache
            mkdir -p ~/.ccache
        fi
    fi
    if [ ! -d "$TC_DIR" ]; then
        _setup_toolchain
    else
        msg "Toolchain already exist"
    fi
    exit 0
}

# --- Regenerate savedefconfig ---
regen_defconfig() {
    [ -z "$DEVICE_TARGET" ] && error "DEVICE_TARGET is required to regen!"
    mkdir -p "$OUT_DIR"
    msg "Generating minimal defconfig for $DEVICE_TARGET..."

    make $BUILD_FLAGS "$DEFCONFIG"
    make $BUILD_FLAGS savedefconfig

    msg "Done!"
}

# --- Arguments Check ---
case "$1" in
"--setup-deps")
    setup_deps
    exit 0
    ;;
"--fetch-toolchains")
    setup_toolchain
    exit 0
    ;;
"--clean")
    msg "Cleaning..."
    rm -rf "$OUT_DIR" AnyKernel3
    make clean mrproper
    exit 0
    ;;
esac

[ -z "$DEVICE_TARGET" ] && error "DEVICE_TARGET cannot be empty!"

# --- Build Environment ---
export KBUILD_BUILD_USER=$USER
export KBUILD_BUILD_HOST=$HOSTNAME
export PATH="$TC_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$TC_DIR/lib"
export LLVM_IAS=1
export LLVM=1

## WORKAROUND
#git clone https://github.com/rsuplaygrnd/toolchains --depth=1 --single-branch -b androidcc-4.9 $HOME/androidcc
#export CROSS_COMPILE=$HOME/androidcc/bin/aarch64-linux-android-
#export CLANG_TRIPLE=aarch64-linux-gnu-
#export CC=$TC_DIR/bin/clang
#export LD=$TC_DIR/bin/ld.lld
## END WORKAROUND

msg "KCFLAGS=-w is $KCFLAGS_W"
[ "$KCFLAGS_W" = "true" ] && export KCFLAGS=-w
DEFCONFIG="exynos850-${DEVICE_TARGET}_defconfig"

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
[ -z "$CI_ZIPNAME" ] && ZIPNAME="rsuntk_$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT_HASH.zip" || ZIPNAME=$CI_ZIPNAME
BUILD_FLAGS="O=$OUT_DIR ARCH=arm64 -j$(nproc --all)"

# --- Build Process ---
if [ "$1" = "--regen-defconfig" ]; then
    regen_defconfig
    exit 0
fi

mkdir -p "$OUT_DIR"
msg "Starting compilation for $DEVICE_TARGET..."
make $BUILD_FLAGS $DEFCONFIG
make $BUILD_FLAGS

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANYKERNEL_DIR="$ROOT_DIR/external/anykernel3"

if [ -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
    msg "Kernel compiled successfully! Packaging..."

    if [ ! -d "$ANYKERNEL_DIR" ]; then
        error "AnyKernel3 directory not found at: $ANYKERNEL_DIR"
    fi

    rm -f "$ANYKERNEL_DIR/Image"*
    cp "$OUT_DIR/arch/arm64/boot/Image" "$ANYKERNEL_DIR/"

    pushd "$ANYKERNEL_DIR" >/dev/null
    zip -r9 "$ROOT_DIR/$ZIPNAME" ./*
    popd >/dev/null

    MD5_CHECK=$(md5sum "$ROOT_DIR/$ZIPNAME" | cut -d' ' -f1)

    send_telegram "$ROOT_DIR/$ZIPNAME" "$MD5_CHECK" "$SECONDS"

    [ "$DO_CLEAN" = "true" ] && rm -rf "$OUT_DIR"

    echo -e "\n${green}Build completed in $((SECONDS / 60)) minute(s)!${reset}"
    msg "Output Zip: $ZIPNAME (at $ROOT_DIR)"
else
    error "Compilation failed! Image file not found."
fi
