#!/usr/bin/env bash

set -e

SECONDS=0
USER="vlzdrt"
HOSTNAME="velprjkt-lab"
DEVICE_TARGET=${DEVICE_TARGET:-"a23nsxx"}
DEFCONFIG=${DEFCONFIG:-"a23_eur_open_defconfig"}
LTO=${LTO:-"none"}
TC_DIR="$HOME/neutron-clang"
GCC_DIR="$HOME/androidcc"
OUT_DIR="$(pwd)/out"
KCFLAGS_W=${KCFLAGS_W:-"false"}
BUILD_STOCK=${BUILD_STOCK:-"false"}

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

send_telegram() {
    local file="$1"
    local md5="$2"
    local time="$(($3 / 60))"

    if [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        msg "Telegram credentials missing. Skipping upload."
        return
    fi

    local branch="${BRANCH:-unknown}"
    local device="${DEVICE_TARGET:-unknown}"
    local defconfig="${DEFCONFIG:-unknown}"
    local lto="${LTO:-none}"
    local date_now=$(date '+%a %b %d %H:%M:%S %Z %Y')
    local clang_ver=$($TC_DIR/bin/clang --version 2>/dev/null | head -1 | cut -d'(' -f1 | sed 's/[[:space:]]*$//' || echo "unknown")

    local msg_bar="Branch: ${branch}
Device: ${device}
Defconfig: ${defconfig}
LTO: ${lto}
MD5: ${md5}
Compiler: ${clang_ver}
Date: ${date_now}
Build done in ${time} minutes"

    msg "Uploading to Telegram..."
    curl -s -F document=@$file \
        -F chat_id="$TG_CHAT_ID" \
        -F caption="$msg_bar" \
        -F "disable_web_page_preview=true" \
        "https://api.telegram.org/bot$TG_TOKEN/sendDocument"
    msg "Upload completed!"
}

setup_deps() {
    local deps_lists=(aptitude bc bison ccache cpio curl flex git lz4 perl python-is-python3 tar wget)
    sudo apt update -y
    sudo apt install "${deps_lists[@]}" -y
    sudo aptitude install libssl-dev -y
}

_setup_toolchain() {
    msg "Downloading Neutron Clang 23 ..."
    wget -q https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/26052026/neutron-clang-26052026.tar.zst -O /tmp/neutron.tar.zst
    [ ! -d "$TC_DIR" ] && mkdir -p "$TC_DIR"
    tar -xvf /tmp/neutron.tar.zst -C "$TC_DIR"
    
    msg "Downloading GCC (AndroidCC) ..."
    git clone --depth=1 https://github.com/blxyzY/toolchain -b androidcc-4.9 "$GCC_DIR" 2>/dev/null || \
    git clone --depth=1 https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 -b master "$GCC_DIR"
    
    cd "$GCC_DIR/bin"
    if [ ! -f "aarch64-linux-android-gcc" ]; then
        ln -sf "$(ls | grep aarch64-linux-android-gcc | head -1)" aarch64-linux-android-gcc
    fi
    cd ../..
    
    msg "Toolchain extracted"
}

setup_toolchain() {
    if [ "$UPDATE_TOOLCHAINS" = "true" ]; then
        msg "Cleaning up old toolchains cache.."
        rm -rf $TC_DIR $GCC_DIR
        if [ -d ~/.ccache ]; then
            rm -rf ~/.ccache
            mkdir -p ~/.ccache
        fi
    fi
    if [ ! -d "$TC_DIR" ] || [ ! -d "$GCC_DIR" ]; then
        _setup_toolchain
    else
        msg "Toolchain already exist"
    fi
    exit 0
}

configure_lto() {
    msg "Configuring LTO: ${LTO:-none}"
    case "${LTO:-none}" in
        "thin")
            ./scripts/config --file out/.config --disable LTO_NONE
            ./scripts/config --file out/.config --enable LTO
            ./scripts/config --file out/.config --enable THINLTO
            ./scripts/config --file out/.config --enable LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_THINLTO
            msg "LTO: Thin mode enabled"
            ;;
        "full")
            ./scripts/config --file out/.config --disable LTO_NONE
            ./scripts/config --file out/.config --enable LTO
            ./scripts/config --file out/.config --disable THINLTO
            ./scripts/config --file out/.config --enable LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_THINLTO
            msg "LTO: Full mode enabled"
            ;;
        *)
            ./scripts/config --file out/.config --enable LTO_NONE
            ./scripts/config --file out/.config --disable LTO
            ./scripts/config --file out/.config --disable THINLTO
            ./scripts/config --file out/.config --disable LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_LTO_CLANG
            ./scripts/config --file out/.config --enable ARCH_SUPPORTS_THINLTO
            msg "LTO: Disabled"
            ;;
    esac
}

regen_defconfig() {
    [ -z "$DEVICE_TARGET" ] && error "DEVICE_TARGET is required to regen!"
    mkdir -p "$OUT_DIR"
    msg "Generating minimal defconfig for $DEVICE_TARGET..."
    make $BUILD_FLAGS "$DEFCONFIG"
    make $BUILD_FLAGS savedefconfig
    msg "Done!"
}

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
    rm -rf "$OUT_DIR" *.zip 2>/dev/null
    make clean mrproper
    exit 0
    ;;
esac

[ -z "$DEVICE_TARGET" ] && error "DEVICE_TARGET cannot be empty!"
[ -z "$DEFCONFIG" ] && error "DEFCONFIG cannot be empty!"

msg "Using defconfig: $DEFCONFIG"
msg "LTO: ${LTO:-none}"

export KBUILD_BUILD_USER=$USER
export KBUILD_BUILD_HOST=$HOSTNAME
export PATH="$TC_DIR/bin:$GCC_DIR/bin:$PATH"
export ARCH=arm64
export LLVM_IAS=1
export LLVM=1
export CROSS_COMPILE="$GCC_DIR/bin/aarch64-linux-android-"
export CLANG_TRIPLE="aarch64-linux-gnu-"

msg "KCFLAGS=-w is $KCFLAGS_W"
[ "$KCFLAGS_W" = "true" ] && export KCFLAGS="-w"

export KCFLAGS="$KCFLAGS -Wno-error=unused-command-line-argument -Wno-error=gnu -Wno-error=register -Wno-error=unknown-attributes -Wno-error=incompatible-pointer-types -Wno-error=pedantic -Wno-error=deprecated-declarations -Wno-error=incompatible-function-pointer-types"

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "untracked")
[ -z "$CI_ZIPNAME" ] && ZIPNAME="rsuntk_$DEVICE_TARGET-$(date '+%Y%m%d-%H%M')-$COMMIT_HASH.zip" || ZIPNAME=$CI_ZIPNAME
BUILD_FLAGS="O=$OUT_DIR ARCH=arm64 -j$(nproc --all)"

if [ "$1" = "--regen-defconfig" ]; then
    regen_defconfig
    exit 0
fi

mkdir -p "$OUT_DIR"
msg "Starting compilation for $DEVICE_TARGET using $DEFCONFIG..."
make $BUILD_FLAGS $DEFCONFIG
configure_lto
make $BUILD_FLAGS

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANYKERNEL_DIR="$ROOT_DIR/external/anykernel3"

if [ ! -d "$ANYKERNEL_DIR" ]; then
    error "AnyKernel3 directory not found at: $ANYKERNEL_DIR"
fi

DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

if [ -f "$DEFCONFIG_PATH" ]; then
    if [ "$SELINUX_CHOICE" = "permissive" ]; then
        echo "Mengonfigurasi kernel ke SELinux Permissive..."
        sed -i 's/CONFIG_CMDLINE=""/CONFIG_CMDLINE="androidboot.selinux=permissive"/' "$DEFCONFIG_PATH"
        sed -i 's/# CONFIG_SECURITY_SELINUX_DEVELOP is not set/CONFIG_SECURITY_SELINUX_DEVELOP=y/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=y/# CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE is not set/' "$DEFCONFIG_PATH" 2>/dev/null || true
        if grep -q "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "$DEFCONFIG_PATH"; then
            sed -i 's/# CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE is not set/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y/' "$DEFCONFIG_PATH"
        else
            echo "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y" >> "$DEFCONFIG_PATH"
        fi
        sed -i 's/CONFIG_INTEGRITY=y/# CONFIG_INTEGRITY is not set/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_SECURITY_DEFEX=y/# CONFIG_SECURITY_DEFEX is not set/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_PROCA=y/# CONFIG_PROCA is not set/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_FIVE=y/# CONFIG_FIVE is not set/' "$DEFCONFIG_PATH"
    else
        echo "Mengonfigurasi kernel ke SELinux Enforcing..."
        sed -i 's/CONFIG_CMDLINE="androidboot.selinux=permissive"/CONFIG_CMDLINE=""/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_SECURITY_SELINUX_DEVELOP=y/# CONFIG_SECURITY_SELINUX_DEVELOP is not set/' "$DEFCONFIG_PATH"
        sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y/# CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE is not set/' "$DEFCONFIG_PATH"
    fi
else
    echo "Warning: Defconfig not found at $DEFCONFIG_PATH"
fi

if [ -f "$OUT_DIR/arch/arm64/boot/Image" ]; then
    msg "Kernel compiled successfully! Packaging..."

    cp "$OUT_DIR/arch/arm64/boot/Image" "$ANYKERNEL_DIR/"

    cat > utsrelease.c << 'EOF'
#include <stdio.h>
#include "out/include/generated/utsrelease.h"
int main() { printf("%s\n", UTS_RELEASE); return 0; }
EOF
    
    UTSRELEASE=""
    if gcc -CC utsrelease.c -o getutsrel 2>/dev/null && [ -f "./getutsrel" ]; then
        UTSRELEASE=$(./getutsrel)
        rm -f getutsrel utsrelease.c
    fi

    if [ -z "$UTSRELEASE" ]; then
        UTSRELEASE=$(make kernelversion 2>/dev/null || echo "unknown")
    fi

    if [ -f "$ANYKERNEL_DIR/anykernel.sh" ]; then
        sed -i "s/kernel\.string=.*/kernel.string=$UTSRELEASE/" "$ANYKERNEL_DIR/anykernel.sh"
        msg "Updated kernel.string to: $UTSRELEASE"
    fi

    pushd "$ANYKERNEL_DIR" >/dev/null
    zip -r9 "$ROOT_DIR/$ZIPNAME" ./*
    popd >/dev/null

    msg "ZIP created: $ZIPNAME"

    MD5_CHECK=$(md5sum "$ROOT_DIR/$ZIPNAME" | cut -d' ' -f1)
    msg "MD5: $MD5_CHECK"

    send_telegram "$ROOT_DIR/$ZIPNAME" "$MD5_CHECK" "$SECONDS"

    [ "$DO_CLEAN" = "true" ] && rm -rf "$OUT_DIR"

    echo -e "\n${green}Build completed in $((SECONDS / 60)) minute(s)!${reset}"
    msg "Output Zip: $ZIPNAME (at $ROOT_DIR)"
else
    error "Compilation failed! Image file not found."
fi
