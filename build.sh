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
SELINUX_MODE=${SELINUX_MODE:-"enforcing"}

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

inject_selinux() {
    local defconfig_path="$1"
    local mode="${SELINUX_MODE:-enforcing}"
    
    msg "Injecting SELinux mode: $mode"
    
    cp "$defconfig_path" "${defconfig_path}.backup"
    
    if [ "$mode" = "permissive" ]; then
        msg "Configuring kernel to SELinux Permissive..."
        
        if grep -q "CONFIG_CMDLINE=" "$defconfig_path"; then
            sed -i 's/CONFIG_CMDLINE=".*"/CONFIG_CMDLINE="androidboot.selinux=permissive"/' "$defconfig_path"
        else
            echo 'CONFIG_CMDLINE="androidboot.selinux=permissive"' >> "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_DEVELOP" "$defconfig_path"; then
            sed -i 's/# CONFIG_SECURITY_SELINUX_DEVELOP is not set/CONFIG_SECURITY_SELINUX_DEVELOP=y/' "$defconfig_path"
            sed -i 's/CONFIG_SECURITY_SELINUX_DEVELOP=n/CONFIG_SECURITY_SELINUX_DEVELOP=y/' "$defconfig_path"
        else
            echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE" "$defconfig_path"; then
            sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=y/# CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE is not set/' "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "$defconfig_path"; then
            sed -i 's/# CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE is not set/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y/' "$defconfig_path"
            sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=n/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y/' "$defconfig_path"
        else
            echo "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y" >> "$defconfig_path"
        fi
        
        sed -i 's/CONFIG_INTEGRITY=y/# CONFIG_INTEGRITY is not set/' "$defconfig_path"
        sed -i 's/CONFIG_SECURITY_DEFEX=y/# CONFIG_SECURITY_DEFEX is not set/' "$defconfig_path"
        sed -i 's/CONFIG_PROCA=y/# CONFIG_PROCA is not set/' "$defconfig_path"
        sed -i 's/CONFIG_FIVE=y/# CONFIG_FIVE is not set/' "$defconfig_path"
        
    else
        msg "Configuring kernel to SELinux Enforcing..."
        
        if grep -q "CONFIG_CMDLINE=" "$defconfig_path"; then
            sed -i 's/CONFIG_CMDLINE=".*androidboot.selinux=permissive.*"/CONFIG_CMDLINE=""/' "$defconfig_path"
            sed -i 's/androidboot.selinux=permissive//' "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_DEVELOP" "$defconfig_path"; then
            sed -i 's/CONFIG_SECURITY_SELINUX_DEVELOP=y/# CONFIG_SECURITY_SELINUX_DEVELOP is not set/' "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE" "$defconfig_path"; then
            sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE=y/# CONFIG_SECURITY_SELINUX_ALWAYS_PERMISSIVE is not set/' "$defconfig_path"
        fi
        
        if grep -q "CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE" "$defconfig_path"; then
            sed -i 's/# CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE is not set/CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=y/' "$defconfig_path"
            sed -i 's/CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=n/CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=y/' "$defconfig_path"
        else
            echo "CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE=y" >> "$defconfig_path"
        fi
        
        if grep -q "# CONFIG_INTEGRITY is not set" "$defconfig_path"; then
            sed -i 's/# CONFIG_INTEGRITY is not set/CONFIG_INTEGRITY=y/' "$defconfig_path"
        fi
        if grep -q "# CONFIG_SECURITY_DEFEX is not set" "$defconfig_path"; then
            sed -i 's/# CONFIG_SECURITY_DEFEX is not set/CONFIG_SECURITY_DEFEX=y/' "$defconfig_path"
        fi
        if grep -q "# CONFIG_PROCA is not set" "$defconfig_path"; then
            sed -i 's/# CONFIG_PROCA is not set/CONFIG_PROCA=y/' "$defconfig_path"
        fi
        if grep -q "# CONFIG_FIVE is not set" "$defconfig_path"; then
            sed -i 's/# CONFIG_FIVE is not set/CONFIG_FIVE=y/' "$defconfig_path"
        fi
    fi
    
    msg "SELinux injection completed for mode: $mode"
    if [ "$mode" = "permissive" ]; then
        grep -q "CONFIG_CMDLINE=\"androidboot.selinux=permissive\"" "$defconfig_path" || \
            msg "Warning: CMDLINE permissive might not be set correctly"
    fi
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
msg "SELinux Mode: ${SELINUX_MODE:-enforcing}"

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

DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

if [ -f "$DEFCONFIG_PATH" ]; then
    inject_selinux "$DEFCONFIG_PATH"
else
    msg "Warning: Defconfig not found at $DEFCONFIG_PATH, skipping SELinux injection"
fi

make $BUILD_FLAGS $DEFCONFIG
configure_lto
make $BUILD_FLAGS

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANYKERNEL_DIR="$ROOT_DIR/external/anykernel3"

if [ ! -d "$ANYKERNEL_DIR" ]; then
    error "AnyKernel3 directory not found at: $ANYKERNEL_DIR"
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
    
    if [ -f "$ANYKERNEL_DIR/anykernel.sh" ]; then
        echo "# SELinux mode: ${SELINUX_MODE:-enforcing}" >> "$ANYKERNEL_DIR/anykernel.sh"
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
    msg "SELinux Mode: ${SELINUX_MODE:-enforcing}"
else
    error "Compilation failed! Image file not found."
fi            ./scripts/config --file out/.config --enable THINLTO
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
