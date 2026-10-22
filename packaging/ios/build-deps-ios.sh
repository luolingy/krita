#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 luolingy <152292963+luolingy@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the minimal set of dependencies needed to build Krita for iOS.
#
# The versions follow the "transition.now/qt6" branch of
# https://invent.kde.org/packaging/krita-deps-management, which is also
# used to fetch the patches some of the dependencies need. Qt itself is
# not built by this script, see README.md.
#
# Run with --help for the list of options.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Required:
  --qt-ios=PATH           Qt for iOS installation (the directory containing bin/qt-cmake)
  --qt-host=PATH          host (macOS) Qt installation of the same version

Optional:
  --build-root=PATH       working directory (default: \$PWD/krita-ios-build)
  --prefix=PATH           install prefix for the iOS dependencies
                          (default: <build-root>/deps-install)
  --host-prefix=PATH      install prefix for host tools (default: <build-root>/host-install)
  --download-dir=PATH     where to keep the downloaded sources (default: <build-root>/downloads)
  --sdk=NAME              iphoneos (default) or iphonesimulator
  --deployment-target=V   minimum iOS version (default: 17.0)
  --deps-repo=PATH        existing checkout of krita-deps-management
  --deps-branch=NAME      branch of krita-deps-management to clone (default: transition.now/qt6)
  --jobs=N                parallel jobs (default: number of CPUs)
  --only=a,b,c            build only the listed components (see the list below)
  -h, --help              show this help

Components, in build order:
  ${ALL_COMPONENTS[*]}
EOF
}

ALL_COMPONENTS=(
    ecm host-kconfig
    zlib png jpeg giflib webp tiff expat freetype harfbuzz fribidi fontconfig unibreak lcms2 exiv2 gsl
    eigen boost xsimd immer zug lager libintl
    kconfig kcoreaddons kwidgetsaddons kcodecs kcompletion kguiaddons ki18n kitemviews kcolorscheme
    quazip
)

QT_IOS=""
QT_HOST=""
BUILD_ROOT="$PWD/krita-ios-build"
PREFIX=""
HOST_PREFIX=""
DOWNLOAD_DIR=""
SDK="iphoneos"
DEPLOYMENT_TARGET="17.0"
DEPS_REPO=""
DEPS_BRANCH="transition.now/qt6"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
ONLY=""

for arg in "$@"; do
    case "$arg" in
        --qt-ios=*) QT_IOS="${arg#*=}" ;;
        --qt-host=*) QT_HOST="${arg#*=}" ;;
        --build-root=*) BUILD_ROOT="${arg#*=}" ;;
        --prefix=*) PREFIX="${arg#*=}" ;;
        --host-prefix=*) HOST_PREFIX="${arg#*=}" ;;
        --download-dir=*) DOWNLOAD_DIR="${arg#*=}" ;;
        --sdk=*) SDK="${arg#*=}" ;;
        --deployment-target=*) DEPLOYMENT_TARGET="${arg#*=}" ;;
        --deps-repo=*) DEPS_REPO="${arg#*=}" ;;
        --deps-branch=*) DEPS_BRANCH="${arg#*=}" ;;
        --jobs=*) JOBS="${arg#*=}" ;;
        --only=*) ONLY="${arg#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$QT_IOS" || -z "$QT_HOST" ]]; then
    echo "ERROR: --qt-ios and --qt-host are required" >&2
    usage
    exit 1
fi

mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
PREFIX="${PREFIX:-$BUILD_ROOT/deps-install}"
HOST_PREFIX="${HOST_PREFIX:-$BUILD_ROOT/host-install}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BUILD_ROOT/downloads}"
SRC_DIR="$BUILD_ROOT/deps-src"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PATCH_DIR="$SCRIPT_DIR/patches"
STAMP_DIR="$BUILD_ROOT/deps-stamps"
mkdir -p "$PREFIX" "$HOST_PREFIX" "$DOWNLOAD_DIR" "$SRC_DIR" "$STAMP_DIR"

case "$SDK" in
    iphoneos) VERSION_MIN_FLAG="-miphoneos-version-min=$DEPLOYMENT_TARGET" ;;
    iphonesimulator) VERSION_MIN_FLAG="-mios-simulator-version-min=$DEPLOYMENT_TARGET" ;;
    *) echo "ERROR: unsupported SDK: $SDK" >&2; exit 1 ;;
esac

SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC_PATH="$(xcrun --sdk "$SDK" -f clang)"
CXX_PATH="$(xcrun --sdk "$SDK" -f clang++)"
ARCH="arm64"
ARCH_FLAGS="-arch $ARCH -isysroot $SDK_PATH $VERSION_MIN_FLAG"

echo "## Qt for iOS:        $QT_IOS"
echo "## Host Qt:           $QT_HOST"
echo "## SDK:               $SDK ($SDK_PATH)"
echo "## Deployment target: $DEPLOYMENT_TARGET"
echo "## Install prefix:    $PREFIX"

# Never pick up host libraries (e.g. from Homebrew) while cross-compiling
IGNORE_PREFIXES="/opt/homebrew;/usr/local;/opt/local"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH

COMMON_CMAKE_ARGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_PREFIX_PATH="$PREFIX"
    -DCMAKE_FIND_ROOT_PATH="$PREFIX"
    -DCMAKE_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES"
    -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES"
    -DCMAKE_INSTALL_NAME_DIR=@rpath
    -DCMAKE_MACOSX_RPATH=ON
    -DBUILD_SHARED_LIBS=ON
    -DBUILD_TESTING=OFF
)

# for plain C/C++ libraries that don't use Qt
IOS_CMAKE_ARGS=(
    "${COMMON_CMAKE_ARGS[@]}"
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH"
    -DCMAKE_OSX_SYSROOT="$SDK"
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
)

# for KDE Frameworks, which use Qt's toolchain file via qt-cmake
KF_CMAKE_ARGS=(
    "${COMMON_CMAKE_ARGS[@]}"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DQT_HOST_PATH="$QT_HOST"
    -DQT_HOST_PATH_CMAKE_DIR="$QT_HOST/lib/cmake"
    -DKF6_HOST_TOOLING="$HOST_PREFIX/lib/cmake"
    -DBUILD_QCH=OFF
    -DBUILD_PYTHON_BINDINGS=OFF
    -DBUILD_DESIGNERPLUGIN=OFF
    -DUSE_DBUS=OFF
    # iOS is not in the list of the platforms KDE Frameworks are tested on
    -DKF_IGNORE_PLATFORM_CHECK=ON
    # With a static Qt the iOS platform plugin is linked into every shared
    # library and references main(), which only the application provides
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-U,_main
    -DCMAKE_MODULE_LINKER_FLAGS=-Wl,-U,_main
)
if [[ "$SDK" == "iphonesimulator" ]]; then
    KF_CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT=iphonesimulator)
fi

######################################################################
# helpers

should_build() {
    local name="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$name,"* ]]
        return
    fi
    [[ "$(cat "$STAMP_DIR/$name.done" 2>/dev/null)" != "$(recipe_hash "$name")" ]]
}

# A hash of everything that defines how a component is built: its section
# of this script, its patches and the common flags. A component is rebuilt
# when the hash differs from the one recorded when it was last built, which
# makes it safe to reuse a partially populated build root.
recipe_hash() {
    local name="$1"
    {
        sed -n "/^if should_build $name; then\$/,/^    mark_done $name\$/p" "$SCRIPT_PATH"
        cat "$PATCH_DIR/$name"-*.patch 2>/dev/null || true
        printf '%s\n' "${IOS_CMAKE_ARGS[@]}" "${KF_CMAKE_ARGS[@]}" "$ARCH_FLAGS"
    } | shasum -a 256 | cut -d' ' -f1
}

mark_done() {
    recipe_hash "$1" > "$STAMP_DIR/$1.done"
}

# download URL SHA256 [FILENAME]
download() {
    local url="$1" sha="$2" file="${3:-$(basename "$1")}"
    local dest="$DOWNLOAD_DIR/$file"
    if [[ ! -f "$dest" ]]; then
        echo "## Downloading $url" >&2
        curl -fL --retry 5 --retry-delay 5 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    if [[ -n "$sha" ]]; then
        echo "$sha  $dest" | shasum -a 256 -c - >&2
    fi
    echo "$dest"
}

# extract ARCHIVE NAME -> prints the source directory
extract() {
    local archive="$1" name="$2"
    local dir="$SRC_DIR/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$archive" -C "$dir" --strip-components=1
    echo "$dir"
}

# apply_patches NAME SRC_DIR -> applies patches/NAME-*.patch
apply_patches() {
    local name="$1" src="$2" p
    for p in "$PATCH_DIR/$name"-*.patch; do
        [[ -e "$p" ]] || continue
        echo "## Applying $(basename "$p")"
        patch -d "$src" -p1 -i "$p"
    done
}

# cmake_ios NAME SRC_DIR [args...]
cmake_ios() {
    local name="$1" src="$2"; shift 2
    local build="$BUILD_ROOT/deps-build/$name"
    rm -rf "$build"
    cmake -S "$src" -B "$build" "${IOS_CMAKE_ARGS[@]}" "$@"
    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"
}

# cmake_kf NAME SRC_DIR [args...]
cmake_kf() {
    local name="$1" src="$2"; shift 2
    local build="$BUILD_ROOT/deps-build/$name"
    rm -rf "$build"
    "$QT_IOS/bin/qt-cmake" -S "$src" -B "$build" "${KF_CMAKE_ARGS[@]}" "$@"
    cmake --build "$build" --parallel "$JOBS"
    cmake --install "$build"
}

MESON_CROSS_FILE="$BUILD_ROOT/meson-ios-$SDK.ini"
write_meson_cross_file() {
    local flags=""
    for f in $ARCH_FLAGS; do flags+="'$f', "; done
    flags="[${flags%, }]"
    cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$CC_PATH'
cpp = '$CXX_PATH'
objc = '$CC_PATH'
ar = '$(xcrun --sdk "$SDK" -f ar)'
strip = '$(xcrun --sdk "$SDK" -f strip)'
pkg-config = 'pkg-config'

[built-in options]
c_args = $flags
c_link_args = $flags
cpp_args = $flags
cpp_link_args = $flags
objc_args = $flags
objc_link_args = $flags
default_library = 'shared'

[properties]
pkg_config_libdir = ['$PREFIX/lib/pkgconfig', '$PREFIX/share/pkgconfig']
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = '$( [[ "$SDK" == iphoneos ]] && echo ios || echo ios-simulator )'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

# meson_ios NAME SRC_DIR [args...]
meson_ios() {
    local name="$1" src="$2"; shift 2
    local build="$BUILD_ROOT/deps-build/$name"
    rm -rf "$build"
    meson setup "$build" "$src" --cross-file "$MESON_CROSS_FILE" \
        --prefix "$PREFIX" --libdir lib --buildtype release "$@"
    meson compile -C "$build" -j "$JOBS"
    meson install -C "$build"
}

# autotools_ios NAME SRC_DIR [configure args...]
autotools_ios() {
    local name="$1" src="$2"; shift 2
    (
        cd "$src"
        if [[ ! -x ./configure ]]; then
            autoreconf -fi
        fi
        export CC="$CC_PATH" CXX="$CXX_PATH"
        export CFLAGS="$ARCH_FLAGS -O2" CXXFLAGS="$ARCH_FLAGS -O2"
        export LDFLAGS="$ARCH_FLAGS -L$PREFIX/lib" CPPFLAGS="-I$PREFIX/include"
        export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
        ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
            --enable-shared --disable-static "$@"
        make -j"$JOBS"
        make install
    )
}

ensure_deps_repo() {
    if [[ -z "$DEPS_REPO" ]]; then
        DEPS_REPO="$BUILD_ROOT/krita-deps-management"
        if [[ ! -d "$DEPS_REPO" ]]; then
            git clone --depth 1 -b "$DEPS_BRANCH" \
                https://invent.kde.org/packaging/krita-deps-management.git "$DEPS_REPO"
        fi
    fi
}

KF_VERSION_DIR="6.25"
KF_VERSION="6.25.0"
kf_url() {
    echo "https://download.kde.org/stable/frameworks/$KF_VERSION_DIR/$1-$KF_VERSION.tar.xz"
}

write_meson_cross_file

######################################################################
# host tools

if should_build ecm; then
    a=$(download "$(kf_url extra-cmake-modules)" ffeb4951bf09b2b8ee17ef24a28b6de650c0db0f59ddffb9009b37cac63af348)
    s=$(extract "$a" ecm)
    # ECM is architecture independent, install it into both prefixes
    for p in "$PREFIX" "$HOST_PREFIX"; do
        rm -rf "$BUILD_ROOT/deps-build/ecm"
        cmake -S "$s" -B "$BUILD_ROOT/deps-build/ecm" -G Ninja -DCMAKE_INSTALL_PREFIX="$p" -DBUILD_TESTING=OFF -DBUILD_DOC=OFF -DBUILD_QTHELP_DOCS=OFF
        cmake --build "$BUILD_ROOT/deps-build/ecm"
        cmake --install "$BUILD_ROOT/deps-build/ecm"
    done
    mark_done ecm
fi

# kconfig_compiler and friends must run on the build machine
if should_build host-kconfig; then
    a=$(download "$(kf_url kconfig)" 8c675c9d35a866fbf1b564354a589019b429cca949f7ba3ba0adb9f2fa15959c)
    s=$(extract "$a" host-kconfig)
    rm -rf "$BUILD_ROOT/deps-build/host-kconfig"
    cmake -S "$s" -B "$BUILD_ROOT/deps-build/host-kconfig" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$HOST_PREFIX" \
        -DCMAKE_PREFIX_PATH="$QT_HOST;$HOST_PREFIX" \
        -DBUILD_TESTING=OFF -DBUILD_QCH=OFF -DBUILD_PYTHON_BINDINGS=OFF \
        -DKCONFIG_USE_GUI=OFF -DKCONFIG_USE_QML=OFF -DKCONFIG_USE_DBUS=OFF -DUSE_DBUS=OFF
    cmake --build "$BUILD_ROOT/deps-build/host-kconfig" --parallel "$JOBS"
    cmake --install "$BUILD_ROOT/deps-build/host-kconfig"
    mark_done host-kconfig
fi

######################################################################
# plain libraries

if should_build zlib; then
    a=$(download https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16)
    s=$(extract "$a" zlib)
    cmake_ios zlib "$s" -DZLIB_BUILD_EXAMPLES=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_STATIC=OFF
    mark_done zlib
fi

if should_build png; then
    a=$(download https://sourceforge.net/projects/libpng/files/libpng16/1.6.58/libpng-1.6.58.tar.gz 8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225)
    s=$(extract "$a" png)
    cmake_ios png "$s" -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF
    mark_done png
fi

if should_build jpeg; then
    a=$(download https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.4.1.tar.gz a7da42b640377c2a9a9665e2c4b0ea60cd5599afb48c2521e6df0c9dc9d15a25 libjpeg-turbo-3.1.4.1.tar.gz)
    s=$(extract "$a" jpeg)
    cmake_ios jpeg "$s" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF \
        -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
    mark_done jpeg
fi

if should_build giflib; then
    ensure_deps_repo
    a=$(download https://sourceforge.net/projects/giflib/files/giflib-5.x/giflib-5.2.1.tar.gz/download 31da5562f44c5f15d63340a09a4fd62b48c45620cd302f77a6d9acf0077879bd giflib-5.2.1.tar.gz)
    s=$(extract "$a" giflib)
    # giflib has no build system that supports cross-compiling, use the
    # CMake one that Krita's dependency builds add
    patch -d "$s" -p1 -i "$DEPS_REPO/ext_giflib/0001-Add-vcpkg-CMake-toolchain.patch"
    # it passes a macOS deployment target to the compiler on all Apple platforms
    perl -pi -e 's/-mmacosx-version-min=\$ENV\{MACOSX_DEPLOYMENT_TARGET\} //' "$s/CMakeLists.txt"
    cmake_ios giflib "$s" -DBUILD_utils=OFF
    mark_done giflib
fi

if should_build webp; then
    a=$(download https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564)
    s=$(extract "$a" webp)
    cmake_ios webp "$s" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_FUZZTEST=OFF
    mark_done webp
fi

if should_build tiff; then
    a=$(download https://download.osgeo.org/libtiff/tiff-4.7.1.tar.gz f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69)
    s=$(extract "$a" tiff)
    cmake_ios tiff "$s" -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
        -Dzlib=ON -Djpeg=ON -Dold-jpeg=OFF -Djpeg12=OFF -Dwebp=OFF -Dlzma=OFF -Dzstd=OFF \
        -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dpixarlog=ON
    mark_done tiff
fi

if should_build expat; then
    a=$(download https://github.com/libexpat/libexpat/releases/download/R_2_7_5/expat-2.7.5.tar.xz 1032dfef4ff17f70464827daa28369b20f6584d108bc36f17ab1676e1edd2f91)
    s=$(extract "$a" expat)
    cmake_ios expat "$s" -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF
    mark_done expat
fi

if should_build freetype; then
    a=$(download https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz 36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f)
    s=$(extract "$a" freetype)
    # HarfBuzz is built afterwards against this FreeType
    cmake_ios freetype "$s" -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON \
        -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON
    mark_done freetype
fi

if should_build harfbuzz; then
    a=$(download https://github.com/harfbuzz/harfbuzz/releases/download/12.3.2/harfbuzz-12.3.2.tar.xz 6f6db164359a2da5a84ef826615b448b33e6306067ad829d85d5b0bf936f1bb8)
    s=$(extract "$a" harfbuzz)
    meson_ios harfbuzz "$s" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled
    mark_done harfbuzz
fi

if should_build fribidi; then
    a=$(download https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz 1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c)
    s=$(extract "$a" fribidi)
    meson_ios fribidi "$s" -Ddocs=false -Dtests=false -Dbin=false
    mark_done fribidi
fi

if should_build fontconfig; then
    a=$(download https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz 6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220)
    s=$(extract "$a" fontconfig)
    meson_ios fontconfig "$s" -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dnls=disabled -Dcache-build=disabled \
        -Dxml-backend=expat
    mark_done fontconfig
fi

if should_build unibreak; then
    a=$(download https://github.com/adah1972/libunibreak/releases/download/libunibreak_7_0/libunibreak-7.0.tar.gz 8c9a6e121736cd0d5c890ae3ae96f3f4010a19aa040f1dbded833a62a87717d3)
    s=$(extract "$a" unibreak)
    autotools_ios unibreak "$s"
    mark_done unibreak
fi

if should_build lcms2; then
    a=$(download https://github.com/mm2/Little-CMS/archive/refs/tags/lcms2.19.tar.gz 6acc3eb5fac194acc85331194133ad1d4a60419dad16b3bc225a7d27380a5b3a lcms2-2.19.tar.gz)
    s=$(extract "$a" lcms2)
    autotools_ios lcms2 "$s" --without-jpeg --without-tiff
    mark_done lcms2
fi

if should_build exiv2; then
    a=$(download https://github.com/Exiv2/exiv2/archive/refs/tags/v0.28.8.tar.gz ea51b0609f58a9afa063b60daa1539948b62247721e154f4fff0ad3aec9f9756 exiv2-0.28.8.tar.gz)
    s=$(extract "$a" exiv2)
    cmake_ios exiv2 "$s" -DEXIV2_ENABLE_XMP=ON -DEXIV2_ENABLE_INIH=OFF -DEXIV2_ENABLE_BROTLI=OFF \
        -DEXIV2_ENABLE_NLS=OFF -DEXIV2_ENABLE_PNG=ON -DEXIV2_ENABLE_WEBREADY=OFF -DEXIV2_ENABLE_CURL=OFF \
        -DEXIV2_BUILD_EXIV2_COMMAND=OFF -DEXIV2_BUILD_SAMPLES=OFF -DEXIV2_BUILD_UNIT_TESTS=OFF \
        -DEXIV2_BUILD_FUZZ_TESTS=OFF -DEXIV2_BUILD_DOC=OFF
    mark_done exiv2
fi

if should_build gsl; then
    ensure_deps_repo
    # GSL with the CMake build system from AMPL, like in Krita's dependency builds
    a=$(download https://github.com/ampl/gsl/archive/fb0cfbc82b5e9e4d22444efce9241924f4aefb83.zip 516d8b529c6ba89d6937b32161d11d66a34b84dbf8cafdb628425731c1a5048e gsl-fb0cfbc8.zip)
    s=$(extract "$a" gsl)
    patch -d "$s" -p1 -i "$DEPS_REPO/ext_gsl/gsl-2.3_clang12.patch"
    # The check for IEEE comparisons runs a test program, which isn't
    # possible when cross-compiling. NaN comparisons work on arm64.
    cmake_ios gsl "$s" -DNO_AMPL_BINDINGS=ON -DGSL_DISABLE_TESTS=ON -DGSL_DISABLE_WARNINGS=ON \
        -DRUN_RESULT=0
    mark_done gsl
fi

######################################################################
# header-only libraries

if should_build eigen; then
    a=$(download https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec)
    s=$(extract "$a" eigen)
    cmake_ios eigen "$s" -DEIGEN_BUILD_TESTING=OFF -DEIGEN_BUILD_DOC=OFF -DEIGEN_BUILD_BLAS=OFF \
        -DEIGEN_BUILD_LAPACK=OFF -DEIGEN_BUILD_PKGCONFIG=ON
    mark_done eigen
fi

if should_build boost; then
    a=$(download https://archives.boost.io/release/1.90.0/source/boost_1_90_0.tar.bz2 49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305)
    # Krita and lager use header-only parts of Boost only
    rm -rf "$PREFIX/include/boost"
    tar -xf "$a" -C "$PREFIX/include" --strip-components=1 boost_1_90_0/boost
    mark_done boost
fi

if should_build xsimd; then
    a=$(download https://github.com/xtensor-stack/xsimd/archive/refs/tags/14.1.0.tar.gz 8da77b66214e73565f6111ba494322c853552b7b40cff69779b42e2100eed16f xsimd-14.1.0.tar.gz)
    s=$(extract "$a" xsimd)
    cmake_ios xsimd "$s" -DBUILD_TESTS=OFF -DBUILD_BENCHMARK=OFF -DBUILD_EXAMPLES=OFF
    mark_done xsimd
fi

if should_build immer; then
    a=$(download https://github.com/arximboldi/immer/archive/refs/tags/v0.9.1.tar.gz b18b92ba60ec3186dc36ef671d3c2ae542cbb63eb6dc0e258476c6111a67c971 immer-0.9.1.tar.gz)
    s=$(extract "$a" immer)
    cmake_ios immer "$s" -Dimmer_BUILD_TESTS=OFF -Dimmer_BUILD_EXAMPLES=OFF -Dimmer_BUILD_DOCS=OFF -Dimmer_BUILD_EXTRAS=OFF
    mark_done immer
fi

if should_build zug; then
    a=$(download https://github.com/arximboldi/zug/archive/refs/tags/v0.1.2.tar.gz "" zug-0.1.2.tar.gz)
    s=$(extract "$a" zug)
    cmake_ios zug "$s" -Dzug_BUILD_TESTS=OFF -Dzug_BUILD_EXAMPLES=OFF -Dzug_BUILD_DOCS=OFF
    mark_done zug
fi

if should_build lager; then
    ensure_deps_repo
    a=$(download https://github.com/dimula73/lager/archive/0b6ab3e0e880bc36be5da4984d768fde03b7cf19.tar.gz "" lager-0b6ab3e0.tar.gz)
    s=$(extract "$a" lager)
    for p in "$DEPS_REPO"/ext_lager/*.patch; do
        patch -d "$s" -p1 -i "$p"
    done
    cmake_ios lager "$s" -Dlager_BUILD_DEBUGGER_EXAMPLES=OFF -Dlager_BUILD_TESTS=OFF \
        -Dlager_BUILD_EXAMPLES=OFF -Dlager_BUILD_DOCS=OFF -DBOOST_ROOT="$PREFIX"
    mark_done lager
fi

if should_build libintl; then
    a=$(download https://github.com/j-jorge/libintl-lite/archive/edbb3064b2ee7ed42ffc5a4b9e0b8c3616d54cbf.tar.gz "" libintl-lite-edbb3064.tar.gz)
    s=$(extract "$a" libintl)
    cmake_ios libintl "$s"
    mark_done libintl
fi

######################################################################
# KDE Frameworks

if should_build kconfig; then
    a=$(download "$(kf_url kconfig)" 8c675c9d35a866fbf1b564354a589019b429cca949f7ba3ba0adb9f2fa15959c)
    s=$(extract "$a" kconfig)
    apply_patches kconfig "$s"
    cmake_kf kconfig "$s" -DKCONFIG_USE_QML=OFF -DKCONFIG_USE_DBUS=OFF
    mark_done kconfig
fi

if should_build kcoreaddons; then
    a=$(download "$(kf_url kcoreaddons)" e7f0825576dc44af0c7194538e48114aa240f8fd3402f27047771f009e161a7e)
    s=$(extract "$a" kcoreaddons)
    apply_patches kcoreaddons "$s"
    cmake_kf kcoreaddons "$s" -DKCOREADDONS_USE_QML=OFF -DENABLE_INOTIFY=OFF
    mark_done kcoreaddons
fi

if should_build kwidgetsaddons; then
    a=$(download "$(kf_url kwidgetsaddons)" 8a9f9cde4427ffec37a0501d337aadae3de39736674f571ff8a13d17d1e6c938)
    s=$(extract "$a" kwidgetsaddons)
    apply_patches kwidgetsaddons "$s"
    cmake_kf kwidgetsaddons "$s"
    mark_done kwidgetsaddons
fi

if should_build kcodecs; then
    a=$(download "$(kf_url kcodecs)" 5051fe783803d94444a231c79635b96f1266594942b836f59ae8460497c788c5)
    s=$(extract "$a" kcodecs)
    cmake_kf kcodecs "$s"
    mark_done kcodecs
fi

if should_build kcompletion; then
    a=$(download "$(kf_url kcompletion)" e4138d525eb9e27a9222d655e412c0de8b4bd7b34289d1c7ca5a808e20b53238)
    s=$(extract "$a" kcompletion)
    cmake_kf kcompletion "$s"
    mark_done kcompletion
fi

if should_build kguiaddons; then
    a=$(download "$(kf_url kguiaddons)" 38850963cb91978d08e781d81b147c7b66f78f4204ad820631e42ab1ef5ef76b)
    s=$(extract "$a" kguiaddons)
    apply_patches kguiaddons "$s"
    cmake_kf kguiaddons "$s" -DWITH_WAYLAND=OFF -DWITH_X11=OFF -DBUILD_GEO_SCHEME_HANDLER=OFF
    mark_done kguiaddons
fi

if should_build ki18n; then
    ensure_deps_repo
    a=$(download "$(kf_url ki18n)" 7fbac8bc88f5cb1af00f6a667381c4bcebba6f417dc6a3c7eef8bded6c9161de)
    s=$(extract "$a" ki18n)
    # libintl-lite installs a plain libintl.h and libintl library. Its
    # functions are declared but not part of libc, which the symbol check
    # can't tell when cross-compiling, so skip the check.
    # (ECMQmlModule looks for QtQml on its own, which enables the QML
    # plugins even with BUILD_WITH_QML=OFF)
    cmake_kf ki18n "$s" -DBUILD_WITH_QML=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Qt6Qml=ON \
        -DLibIntl_SYMBOL_FOUND=OFF \
        -DLibIntl_INCLUDE_DIRS="$PREFIX/include" \
        -DLibIntl_LIBRARIES="$(ls "$PREFIX"/lib/libintl*.dylib "$PREFIX"/lib/libintl*.a 2>/dev/null | head -n1)"
    mark_done ki18n
fi

if should_build kitemviews; then
    a=$(download "$(kf_url kitemviews)" b57f38d6fd184a4b260d0b35d76f6c0fb96bdd80475e3ca7d4151023730e5d3d)
    s=$(extract "$a" kitemviews)
    cmake_kf kitemviews "$s"
    mark_done kitemviews
fi

if should_build kcolorscheme; then
    a=$(download "$(kf_url kcolorscheme)" 95a8a37817765f910c59b269a9958557505b99ff698fd6d220bcb166d5e302f5)
    s=$(extract "$a" kcolorscheme)
    cmake_kf kcolorscheme "$s"
    mark_done kcolorscheme
fi

######################################################################
# other Qt based libraries

if should_build quazip; then
    a=$(download https://github.com/stachenov/quazip/archive/refs/tags/v1.5.tar.gz 405b72b6e76c8987ff41a762523b8f64876ba406d8a831d268ee0b63f1369582 quazip-1.5.tar.gz)
    s=$(extract "$a" quazip)
    cmake_kf quazip "$s" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_BZIP2=OFF -DQUAZIP_ENABLE_TESTS=OFF
    mark_done quazip
fi

echo "## All dependencies are installed into $PREFIX"
