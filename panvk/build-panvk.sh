#!/bin/bash
# Cross-compile Mesa PanVK for Android (Winlator rootfs layout).
# Produces app/app/src/main/assets/graphics_driver/panvk-VERSION.tzst
#
# Usage:
#   export ANDROID_NDK=$HOME/android-sdk/ndk/26.3.11579264
#   ./build-panvk.sh              # all stages
#   STAGE=libclc ./build-panvk.sh # one stage at a time
#   STAGE=clean  ./build-panvk.sh # wipe build dirs
#
# Stages: clean | libclc | host | android | pack | all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINLATOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MESA_VERSION="${MESA_VERSION:-25.3.0}"
MESA_TAG="mesa-${MESA_VERSION}"
BUILD_DIR="${BUILD_DIR:-/tmp/panvk-build}"
MESA_SRC="${MESA_SRC:-$BUILD_DIR/mesa}"
NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-}}"
API_LEVEL="${API_LEVEL:-34}"
ASSET_DIR="${ASSET_DIR:-$WINLATOR_DIR/app/app/src/main/assets/graphics_driver}"
PACKAGE_DIR="$BUILD_DIR/panvk-package"
CROSS_FILE="$BUILD_DIR/android-aarch64.meson"
STAGE="${STAGE:-all}"

SERIAL="${SERIAL:-1}"
JOBS="${JOBS:-1}"
[[ "$SERIAL" == "1" ]] && JOBS=1

export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-1}"
export MAKEFLAGS="-j${JOBS}"
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
export LLVM_PARALLEL_LINK_JOBS=1
export CC="${CC:-/usr/bin/cc}"
export CXX="${CXX:-/usr/bin/c++}"

# GCC-only flags for native host builds — must NOT leak into NDK clang cross-compile
apply_host_compiler_flags() {
    export CFLAGS="${HOST_CFLAGS:--O1 -g0 -fno-var-tracking-assignments}"
    export CXXFLAGS="${HOST_CXXFLAGS:--O1 -g0 -fno-var-tracking-assignments}"
    export LDFLAGS="${HOST_LDFLAGS:--Wl,--no-keep-memory}"
}

clear_compiler_flags() {
    unset CFLAGS CXXFLAGS LDFLAGS
}

HOST_COMPILER_PREFIX="$BUILD_DIR/mesa-host"
ANDROID_BUILD="$BUILD_DIR/mesa-android"
LIBCLC_PREFIX="$BUILD_DIR/libclc-prefix"
LIBCLC_BUILD="$BUILD_DIR/libclc-build"
LIBDRM_VERSION="libdrm-2.4.122"
LIBDRM_SRC="$BUILD_DIR/$LIBDRM_VERSION"
LIBDRM_BUILD="$BUILD_DIR/libdrm-android-build"
LIBDRM_PREFIX="$BUILD_DIR/libdrm-android-prefix"

# Compiler flags via CFLAGS/CXXFLAGS/LDFLAGS (meson 1.4+ rejects broken array syntax in -Dc_args)
MESON_LOW_MEM=(
    -Dbuildtype=plain
    -Db_lto=false
    -Db_ndebug=true
    -Dshader-cache=disabled
)

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
PanVK build script for Winlator

  export ANDROID_NDK=/path/to/ndk
  ./build-panvk.sh

Stages (run separately to save RAM):
  STAGE=clean   - remove build artifacts
  STAGE=libclc  - build/install libclc
  STAGE=host    - build mesa_clc + precomp (host tools)
  STAGE=android - cross-compile libvulkan_panfrost.so
  STAGE=pack    - create panvk-VERSION.tzst asset
  STAGE=all     - everything (default)

Options:
  JOBS=1 SERIAL=1  (default, lowest RAM)
  MESA_VERSION=25.3.0
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage && exit 0

if [[ -z "$NDK" || ! -d "$NDK" ]]; then
    die "Set ANDROID_NDK to a valid NDK directory (e.g. export ANDROID_NDK=\$HOME/android-sdk/ndk/26.3.11579264)"
fi

mkdir -p "$BUILD_DIR" "$PACKAGE_DIR/usr/lib" "$PACKAGE_DIR/usr/share/vulkan/icd.d"

ninja_or_make() {
    local dir="$1"
    if [[ -f "$dir/build.ninja" ]]; then
        echo "ninja -C $dir -j${JOBS}"
        ninja -C "$dir" -j"${JOBS}" -l"${JOBS}"
    elif [[ -f "$dir/Makefile" ]]; then
        echo "make -C $dir -j${JOBS}"
        make -C "$dir" -j"${JOBS}"
    else
        die "No build.ninja or Makefile in $dir"
    fi
}

stage_allowed() {
    case "$STAGE" in
        all|"$1") return 0 ;;
        *) return 1 ;;
    esac
}

clean_all() {
    echo "Cleaning $BUILD_DIR ..."
    rm -rf \
        "$LIBCLC_BUILD" \
        "$LIBCLC_PREFIX" \
        "$BUILD_DIR/mesa-host-build" \
        "$HOST_COMPILER_PREFIX" \
        "$ANDROID_BUILD" \
        "$LIBDRM_BUILD" \
        "$LIBDRM_PREFIX" \
        "$PACKAGE_DIR/usr/lib/libvulkan_panfrost.so" \
        "$PACKAGE_DIR/usr/share"
    mkdir -p "$PACKAGE_DIR/usr/lib" "$PACKAGE_DIR/usr/share/vulkan/icd.d"
    echo "Clean done."
}

write_android_cross_file() {
    NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local libdrm_pc_dir=""
    if [[ -d "$LIBDRM_PREFIX/lib/pkgconfig" ]]; then
        libdrm_pc_dir="$LIBDRM_PREFIX/lib/pkgconfig"
    fi
    cat > "$CROSS_FILE" <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang']
cpp = ['$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments', '-O1', '-g0']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK_BIN/llvm-strip'
pkgconfig = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
${libdrm_pc_dir:+pkg_config_libdir = '$libdrm_pc_dir'}
EOF
}

build_android_libdrm() {
    if [[ -f "$LIBDRM_PREFIX/lib/libdrm.so" || -f "$LIBDRM_PREFIX/lib/libdrm.so.2" ]]; then
        echo "libdrm for Android already built: $LIBDRM_PREFIX"
        return 0
    fi

    echo "=== STAGE libdrm: cross-compile for Android ==="
    write_android_cross_file

    if [[ ! -f "$LIBDRM_SRC/meson.build" ]]; then
        curl -L --retry 3 -f -o "$BUILD_DIR/libdrm.tar.xz" \
            "https://dri.freedesktop.org/libdrm/${LIBDRM_VERSION}.tar.xz"
        tar -xf "$BUILD_DIR/libdrm.tar.xz" -C "$BUILD_DIR"
    fi

    rm -rf "$LIBDRM_BUILD"
    clear_compiler_flags
    export PKG_CONFIG_LIBDIR="${ANDROID_PKG_CONFIG_LIBDIR:-/disable/non/android/system/pc/files}"
    meson setup "$LIBDRM_BUILD" "$LIBDRM_SRC" \
        --cross-file "$CROSS_FILE" \
        -Dprefix="$LIBDRM_PREFIX" \
        -Dlibdir=lib \
        -Dvc4=disabled -Dfreedreno=disabled -Detnaviv=disabled \
        -Dnouveau=disabled -Dintel=disabled -Damdgpu=disabled \
        -Dradeon=disabled -Dexynos=disabled -Domap=disabled \
        -Ddefault_library=shared

    ninja_or_make "$LIBDRM_BUILD"
    meson install -C "$LIBDRM_BUILD" -q

    [[ -f "$LIBDRM_PREFIX/lib/libdrm.so" || -f "$LIBDRM_PREFIX/lib/libdrm.so.2" ]] \
        || die "libdrm install incomplete"
}

libclc_ready() {
    if pkg-config --exists libclc 2>/dev/null; then
        return 0
    fi
    local pc="$LIBCLC_PREFIX/share/pkgconfig/libclc.pc"
    [[ -f "$pc" ]] || pc="$LIBCLC_PREFIX/lib/pkgconfig/libclc.pc"
    [[ -f "$pc" && -f "$LIBCLC_PREFIX/share/clc/spirv64-mesa3d-.spv" ]]
}

setup_pkg_config_path() {
    if pkg-config --exists libclc 2>/dev/null; then
        echo "Using system libclc: $(pkg-config --modversion libclc)"
        return 0
    fi
    for pc in "$LIBCLC_PREFIX/share/pkgconfig" "$LIBCLC_PREFIX/lib/pkgconfig"; do
        if [[ -f "$pc/libclc.pc" ]]; then
            export PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            echo "Using libclc from $LIBCLC_PREFIX ($(pkg-config --modversion libclc))"
            return 0
        fi
    done
    return 1
}

ensure_libclc() {
    if libclc_ready; then
        setup_pkg_config_path || true
        return 0
    fi

    echo "=== STAGE libclc: building spirv64-mesa3d- only (jobs=${JOBS}) ==="
    LLVM_PROJECT_SRC="$BUILD_DIR/llvm-project"
    if [[ ! -f "$LLVM_PROJECT_SRC/libclc/CMakeLists.txt" ]]; then
        rm -rf "$LLVM_PROJECT_SRC"
        git clone --depth 1 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git "$LLVM_PROJECT_SRC"
        git -C "$LLVM_PROJECT_SRC" checkout "llvmorg-$(llvm-config --version)" 2>/dev/null || true
        git -C "$LLVM_PROJECT_SRC" sparse-checkout set libclc
    fi

    # Always use a fresh libclc build dir (old runs mixed generators / both SPIR-V targets).
    rm -rf "$LIBCLC_BUILD" "$LIBCLC_PREFIX"
    mkdir -p "$LIBCLC_PREFIX"

    LLVM_SPIRV="$(command -v llvm-spirv llvm-spirv-22 2>/dev/null | head -1 || true)"
    cmake -S "$LLVM_PROJECT_SRC/libclc" -B "$LIBCLC_BUILD" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$LIBCLC_PREFIX" \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_CONFIG=llvm-config \
        -DLIBCLC_USE_SPIRV_BACKEND=ON \
        -DLIBCLC_TARGETS_TO_BUILD=spirv64-mesa3d- \
        ${LLVM_SPIRV:+-DLLVM_SPIRV="$LLVM_SPIRV"}

    ninja_or_make "$LIBCLC_BUILD"
    cmake --install "$LIBCLC_BUILD"

    [[ -f "$LIBCLC_PREFIX/share/clc/spirv64-mesa3d-.spv" ]] \
        || die "libclc install incomplete (spirv64-mesa3d-.spv missing)"

    setup_pkg_config_path || die "libclc.pc not found after install"
}

build_host_tools() {
    echo "=== STAGE host: mesa_clc + precomp ==="
    ensure_libclc
    setup_pkg_config_path || die "libclc required for host tools"

    if [[ -f "$HOST_COMPILER_PREFIX/bin/mesa_clc" ]]; then
        echo "Host tools already present: $HOST_COMPILER_PREFIX/bin/mesa_clc"
        return 0
    fi

    if [[ ! -d "$MESA_SRC/.git" ]]; then
        git clone --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_SRC"
    fi

    rm -rf "$BUILD_DIR/mesa-host-build"
    apply_host_compiler_flags
    meson setup "$BUILD_DIR/mesa-host-build" "$MESA_SRC" \
        "${MESON_LOW_MEM[@]}" \
        -Dprefix="$HOST_COMPILER_PREFIX" \
        -Dstrip=true \
        -Dplatforms= \
        -Dgallium-drivers= \
        -Dvulkan-drivers= \
        -Dtools=panfrost \
        -Dmesa-clc=enabled \
        -Dinstall-mesa-clc=true \
        -Dprecomp-compiler=enabled \
        -Dinstall-precomp-compiler=true

    ninja_or_make "$BUILD_DIR/mesa-host-build"
    meson install -C "$BUILD_DIR/mesa-host-build" -q

    [[ -f "$HOST_COMPILER_PREFIX/bin/mesa_clc" ]] \
        || die "mesa_clc not installed to $HOST_COMPILER_PREFIX/bin/"
}

build_android_panvk() {
    echo "=== STAGE android: libvulkan_panfrost.so ==="
    ensure_libclc
    build_host_tools
    build_android_libdrm

    export PATH="$HOST_COMPILER_PREFIX/bin:$PATH"

    if [[ ! -d "$MESA_SRC/.git" ]]; then
        git clone --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_SRC"
    fi

    write_android_cross_file

    if [[ ! -f "$ANDROID_BUILD/build.ninja" ]]; then
        rm -rf "$ANDROID_BUILD"
        clear_compiler_flags
        # Host pkg-config must not enable deps (zstd, etc.) the NDK sysroot lacks
        export PKG_CONFIG_LIBDIR="${ANDROID_PKG_CONFIG_LIBDIR:-/disable/non/android/system/pc/files}"
        meson setup "$ANDROID_BUILD" "$MESA_SRC" \
            --cross-file "$CROSS_FILE" \
            "${MESON_LOW_MEM[@]}" \
            -Dplatforms=android \
            -Dplatform-sdk-version="$API_LEVEL" \
            -Dandroid-stub=true \
            -Dandroid-libbacktrace=disabled \
            -Degl=disabled \
            -Dgallium-drivers= \
            -Dvulkan-drivers=panfrost \
            -Dallow-fallback-for=libdrm \
            -Dzstd=disabled \
            -Dmesa-clc=system \
            -Dprecomp-compiler=system
    fi

    export PKG_CONFIG_LIBDIR="${ANDROID_PKG_CONFIG_LIBDIR:-/disable/non/android/system/pc/files}"

    ninja_or_make "$ANDROID_BUILD"
}

pack_asset() {
    echo "=== STAGE pack: panvk-${MESA_VERSION}.tzst ==="
    PANVK_SO="$(find "$ANDROID_BUILD" -name 'libvulkan_panfrost.so' -type f | head -1)"
    [[ -n "$PANVK_SO" ]] || die "libvulkan_panfrost.so not found. Run STAGE=android first."

    rm -rf "$PACKAGE_DIR/usr/lib" "$PACKAGE_DIR/usr/share"
    mkdir -p "$PACKAGE_DIR/usr/lib" "$PACKAGE_DIR/usr/share/vulkan/icd.d"

    cp "$PANVK_SO" "$PACKAGE_DIR/usr/lib/libvulkan_panfrost.so"

    # Mesa android-stub libs (linked by libvulkan_panfrost.so)
    for lib in cutils hardware log nativewindow sync; do
        stub="$(find "$ANDROID_BUILD" -name "lib${lib}.so" -path '*/android_stub/*' -type f | head -1)"
        [[ -n "$stub" ]] || stub="$(find "$ANDROID_BUILD" -name "lib${lib}.so" -type f | head -1)"
        [[ -n "$stub" ]] || die "lib${lib}.so not found in mesa android build"
        cp "$stub" "$PACKAGE_DIR/usr/lib/lib${lib}.so"
    done

    # libdrm for Android (PanVK links libdrm.so, not in Winlator rootfs by default)
    build_android_libdrm
    if [[ -f "$LIBDRM_PREFIX/lib/libdrm.so" ]]; then
        cp -a "$LIBDRM_PREFIX/lib/libdrm.so"* "$PACKAGE_DIR/usr/lib/"
    elif [[ -f "$LIBDRM_PREFIX/lib/libdrm.so.2" ]]; then
        cp "$LIBDRM_PREFIX/lib/libdrm.so.2" "$PACKAGE_DIR/usr/lib/libdrm.so"
    else
        die "libdrm.so missing from $LIBDRM_PREFIX/lib"
    fi

    # Verify all NEEDED libs are in the package
    while read -r dep; do
        [[ -f "$PACKAGE_DIR/usr/lib/$dep" ]] || die "packaging incomplete: missing $dep for libvulkan_panfrost.so"
    done < <(readelf -d "$PACKAGE_DIR/usr/lib/libvulkan_panfrost.so" | awk '/NEEDED/ {gsub(/[\[\]]/,"",$5); print $5}')

    cat > "$PACKAGE_DIR/usr/share/vulkan/icd.d/panfrost_icd.aarch64.json" <<EOF
{
    "ICD": {
        "api_version": "1.3.0",
        "library_arch": "64",
        "library_path": "/data/data/com.winlator/files/rootfs/usr/lib/libvulkan_panfrost.so"
    },
    "file_format_version": "1.0.1"
}
EOF

    ASSET_PATH="$ASSET_DIR/panvk-${MESA_VERSION}.tzst"
    mkdir -p "$ASSET_DIR"
    tar -I zstd -cf "$ASSET_PATH" -C "$PACKAGE_DIR" .
    echo "Created $ASSET_PATH ($(du -h "$ASSET_PATH" | cut -f1))"
    echo "Next: cd $WINLATOR_DIR/app && ./gradlew assembleDebug"
}

echo "PanVK build: STAGE=${STAGE} JOBS=${JOBS} NDK=${NDK}"

case "$STAGE" in
    clean)   clean_all ;;
    libclc)  ensure_libclc ;;
    host)    build_host_tools ;;
    android) build_android_panvk ;;
    pack)    pack_asset ;;
    all)
        ensure_libclc
        build_host_tools
        build_android_panvk
        pack_asset
        ;;
    *)
        die "Unknown STAGE=${STAGE}. Use: clean|libclc|host|android|pack|all"
        ;;
esac

echo "Done (STAGE=${STAGE})."
