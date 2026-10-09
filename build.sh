```bash
#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(pwd)"
OUT_DIR="$ROOT_DIR/out"

DEVICE_TARGET="${DEVICE_TARGET:-A235F}"
DEFCONFIG="${DEFCONFIG:-a23_eur_open_defconfig}"
CLANG_VERSION="${CLANG_VERSION:-neutron-clang23}"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-}"
LTO="${LTO:-none}"
SELINUX="${SELINUX:-enforcing}"
KSU="${KSU:-false}"
KSU_BRANCH="${KSU_BRANCH:-xxksu}"
KCFLAGS_W="${KCFLAGS_W:-false}"

BOOT_RAMDISK="${BOOT_RAMDISK:-boot/ramdisk}"
MKBOOTIMG="${MKBOOTIMG:-mkbootimg/mkbootimg.py}"
BOARD="${BOARD:-SRPUB26A012}"

TC_DIR="$HOME/neutron-clang"

msg() {
    printf '\n[BUILD] %s\n' "$*"
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

setup_deps() {
    sudo apt-get update
    sudo apt-get install -y \
        bc bison build-essential ccache cpio curl \
        flex git libelf-dev libssl-dev lz4 perl \
        python3 python3-pip rsync tar unzip wget zip zstd \
        device-tree-compiler
}

fetch_toolchains() {
    [[ -n "$TOOLCHAIN_URL" ]] || \
        die "TOOLCHAIN_URL is empty. Supply a direct URL to the Clang archive."

    rm -rf "$TC_DIR"
    mkdir -p "$TC_DIR"

    msg "Downloading toolchain: $CLANG_VERSION"
    curl -fL --retry 3 "$TOOLCHAIN_URL" -o /tmp/a23-clang-archive

    case "$TOOLCHAIN_URL" in
        *.tar.gz|*.tgz)
            tar -xzf /tmp/a23-clang-archive -C "$TC_DIR"
            ;;
        *.tar.xz)
            tar -xJf /tmp/a23-clang-archive -C "$TC_DIR"
            ;;
        *.tar.zst|*.tzst)
            tar --zstd -xf /tmp/a23-clang-archive -C "$TC_DIR"
            ;;
        *.tar.bz2)
            tar -xjf /tmp/a23-clang-archive -C "$TC_DIR"
            ;;
        *.zip)
            unzip -q /tmp/a23-clang-archive -d "$TC_DIR"
            ;;
        *)
            die "Unsupported archive extension in TOOLCHAIN_URL"
            ;;
    esac

    if [[ ! -x "$TC_DIR/bin/clang" ]]; then
        local clang_path
        clang_path="$(find "$TC_DIR" -type f -path '*/bin/clang' -print -quit)"

        [[ -n "$clang_path" ]] || \
            die "clang binary not found in downloaded archive"

        local clang_bin_dir
        clang_bin_dir="$(dirname "$clang_path")"

        # Move the extracted toolchain contents into the expected directory.
        local extracted_root
        extracted_root="$(dirname "$clang_bin_dir")"

        if [[ "$extracted_root" != "$TC_DIR" ]]; then
            local temp_dir="$TC_DIR/.toolchain-temp"
            mkdir -p "$temp_dir"
            cp -a "$extracted_root"/. "$temp_dir"/
            cp -an "$temp_dir"/. "$TC_DIR"/
            rm -rf "$temp_dir"
        fi
    fi

    [[ -x "$TC_DIR/bin/clang" ]] || \
        die "Expected Clang binary at $TC_DIR/bin/clang"

    "$TC_DIR/bin/clang" --version
}

setup_build_env() {
    export ARCH=arm64
    export SUBARCH=arm64
    export PATH="$TC_DIR/bin:$PATH"
    export LLVM=1

    if [[ "$KCFLAGS_W" == "true" ]]; then
        export KCFLAGS="${KCFLAGS:-} -w"
    fi
}

configure_kernel() {
    local config="$OUT_DIR/.config"
    local config_script="$ROOT_DIR/scripts/config"

    mkdir -p "$OUT_DIR"

    msg "Applying defconfig: $DEFCONFIG"

    make -C "$ROOT_DIR" \
        O="$OUT_DIR" \
        ARCH=arm64 \
        LLVM=1 \
        "$DEFCONFIG"

    [[ -f "$config" ]] || die "Defconfig did not create $config"

    case "$LTO" in
        thin)
            "$config_script" --file "$config" --disable LTO_NONE
            "$config_script" --file "$config" --enable LTO
            "$config_script" --file "$config" --enable LTO_CLANG
            "$config_script" --enable THINLTO --file "$config"
            ;;
        none)
            "$config_script" --file "$config" --disable THINLTO
            "$config_script" --file "$config" --disable LTO_CLANG
            "$config_script" --file "$config" --disable LTO
            ;;
        *)
            die "Unsupported LTO value: $LTO"
            ;;
    esac

    case "$SELINUX" in
        permissive)
            "$config_script" --file "$config" \
                --enable SECURITY_SELINUX_DEVELOP
            "$config_script" --file "$config" \
                --enable SECURITY_SELINUX_ALWAYS_PERMISSIVE
            "$config_script" --file "$config" \
                --disable SECURITY_SELINUX_ALWAYS_ENFORCE
            ;;
        enforcing)
            "$config_script" --file "$config" \
                --disable SECURITY_SELINUX_ALWAYS_PERMISSIVE
            "$config_script" --file "$config" \
                --enable SECURITY_SELINUX_ALWAYS_ENFORCE
            ;;
        *)
            die "Unsupported SELINUX value: $SELINUX"
            ;;
    esac

    if [[ "$KSU" == "true" ]]; then
        if [[ ! -d "$ROOT_DIR/KernelSU" && \
              ! -d "$ROOT_DIR/drivers/kernelsu" ]]; then
            msg "Setting up KernelSU branch: $KSU_BRANCH"

            curl -fLSs \
                "https://raw.githubusercontent.com/RapliVx/KernelSU/xxksu/kernel/setup.sh" \
                | bash -s "$KSU_BRANCH"
        fi

        if [[ -d "$ROOT_DIR/KernelSU" || \
              -d "$ROOT_DIR/drivers/kernelsu" ]]; then
            "$config_script" --file "$config" --enable KSU
        else
            die "KernelSU source directory not found after setup"
        fi
    fi

    make -C "$ROOT_DIR" \
        O="$OUT_DIR" \
        ARCH=arm64 \
        LLVM=1 \
        olddefconfig
}

build_kernel() {
    local jobs
    jobs="$(nproc)"

    msg "Building kernel for $DEVICE_TARGET"

    make -C "$ROOT_DIR" \
        O="$OUT_DIR" \
        ARCH=arm64 \
        LLVM=1 \
        -j"$jobs"

    [[ -s "$OUT_DIR/arch/arm64/boot/Image" ]] || \
        die "Kernel Image was not generated"

    [[ -s "$OUT_DIR/arch/arm64/boot/dtbo.img" ]] || \
        die "dtbo.img was not generated"
}

build_dtb_and_dtbo() {
    local dtb_dir="$OUT_DIR/arch/arm64/boot/dts/vendor/qcom"
    local dtb_output="$dtb_dir/dtb"
    local dtbo_source="$OUT_DIR/arch/arm64/boot/dtbo.img"

    shopt -s nullglob
    local dtb_files=("$dtb_dir"/*.dtb)
    shopt -u nullglob

    [[ ${#dtb_files[@]} -gt 0 ]] || \
        die "No DTB files found in $dtb_dir"

    msg "Combining DTB files"
    cat "${dtb_files[@]}" > "$dtb_output"

    [[ -s "$dtb_output" ]] || die "Combined DTB is empty"

    cp "$dtbo_source" "$ROOT_DIR/dtbo.img"
    [[ -s "$ROOT_DIR/dtbo.img" ]] || die "Failed to copy dtbo.img"
}

build_boot() {
    local kernel_image="$OUT_DIR/arch/arm64/boot/Image"
    local dtb_output="$OUT_DIR/arch/arm64/boot/dts/vendor/qcom/dtb"

    [[ -f "$MKBOOTIMG" ]] || die "mkbootimg.py not found: $MKBOOTIMG"
    [[ -e "$BOOT_RAMDISK" ]] || die "Boot ramdisk not found: $BOOT_RAMDISK"

    local cmdline
    cmdline="console=null androidboot.hardware=qcom androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7"

    msg "Building boot.img"

    python3 "$MKBOOTIMG" \
        --header_version 2 \
        --kernel "$kernel_image" \
        --ramdisk "$BOOT_RAMDISK" \
        --dtb "$dtb_output" \
        --cmdline "$cmdline" \
        --base 0x00000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x02000000 \
        --second_offset 0x00000000 \
        --dtb_offset 0x01f00000 \
        --tags_offset 0x01e00000 \
        --board "$BOARD" \
        --pagesize 4096 \
        --os_version 16.0.0 \
        --os_patch_level "$(date +'%Y-%m')" \
        --output "$ROOT_DIR/boot.img"

    [[ -s "$ROOT_DIR/boot.img" ]] || die "boot.img was not generated"
}

show_outputs() {
    msg "Build completed"

    ls -lh "$ROOT_DIR/boot.img" "$ROOT_DIR/dtbo.img"
    sha256sum "$ROOT_DIR/boot.img" "$ROOT_DIR/dtbo.img"
}

case "${1:-build}" in
    --setup-deps)
        setup_deps
        exit 0
        ;;
    --fetch-toolchains)
        fetch_toolchains
        exit 0
        ;;
    --clean)
        rm -rf "$OUT_DIR" "$ROOT_DIR/boot.img" "$ROOT_DIR/dtbo.img"
        exit 0
        ;;
esac

setup_build_env
configure_kernel
build_kernel
build_dtb_and_dtbo
build_boot
show_outputs
```
