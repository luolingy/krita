#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 luolingy <152292963+luolingy@users.noreply.github.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Configures, builds and packages Krita for iOS. The dependencies are
# expected to be built with build-deps-ios.sh first.
#
# Run with --help for the list of options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [steps]

Steps (default: configure build install deploy):
  configure   run CMake (via Qt's qt-cmake) for the iOS toolchain
  build       build Krita
  install     install Krita into <build-root>/krita-install
  deploy      assemble Krita.app: copy the libraries, plugins and data
              into the bundle, fix install names and optionally sign it

Required:
  --qt-ios=PATH            Qt for iOS installation (the directory containing bin/qt-cmake)
  --qt-host=PATH           host (macOS) Qt installation of the same version

Optional:
  --src=PATH               Krita source directory (default: $SRC_DIR_DEFAULT)
  --build-root=PATH        working directory (default: \$PWD/krita-ios-build)
  --deps-prefix=PATH       iOS dependencies (default: <build-root>/deps-install)
  --host-prefix=PATH       host tools (default: <build-root>/host-install)
  --build-type=TYPE        CMake build type (default: RelWithDebInfo)
  --generator=NAME         Xcode (default, needed for signing and asset
                           catalogs) or Ninja (faster, good for compile-testing)
  --sdk=NAME               iphoneos (default) or iphonesimulator
  --deployment-target=V    minimum iOS version (default: 17.0)
  --bundle-id=ID           bundle identifier (default: org.krita)
  --team-id=ID             Apple Development Team ID for automatic signing in Xcode
  --codesign-identity=ID   identity used to sign the deployed bundle
                           (e.g. "Apple Development: Name (XXXXXXXXXX)")
  --provisioning-profile=PATH  .mobileprovision file to embed into the bundle
  --jobs=N                 parallel jobs (default: number of CPUs)
  --cmake-args="..."       extra arguments passed to CMake
  -h, --help               show this help
EOF
}

QT_IOS=""
QT_HOST=""
SRC_DIR="$SRC_DIR_DEFAULT"
BUILD_ROOT="$PWD/krita-ios-build"
DEPS_PREFIX=""
HOST_PREFIX=""
BUILD_TYPE="RelWithDebInfo"
GENERATOR="Xcode"
SDK="iphoneos"
DEPLOYMENT_TARGET="17.0"
BUNDLE_ID="org.krita"
TEAM_ID=""
CODESIGN_IDENTITY=""
PROVISIONING_PROFILE=""
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
EXTRA_CMAKE_ARGS=""
STEPS=()

for arg in "$@"; do
    case "$arg" in
        --qt-ios=*) QT_IOS="${arg#*=}" ;;
        --qt-host=*) QT_HOST="${arg#*=}" ;;
        --src=*) SRC_DIR="${arg#*=}" ;;
        --build-root=*) BUILD_ROOT="${arg#*=}" ;;
        --deps-prefix=*) DEPS_PREFIX="${arg#*=}" ;;
        --host-prefix=*) HOST_PREFIX="${arg#*=}" ;;
        --build-type=*) BUILD_TYPE="${arg#*=}" ;;
        --generator=*) GENERATOR="${arg#*=}" ;;
        --sdk=*) SDK="${arg#*=}" ;;
        --deployment-target=*) DEPLOYMENT_TARGET="${arg#*=}" ;;
        --bundle-id=*) BUNDLE_ID="${arg#*=}" ;;
        --team-id=*) TEAM_ID="${arg#*=}" ;;
        --codesign-identity=*) CODESIGN_IDENTITY="${arg#*=}" ;;
        --provisioning-profile=*) PROVISIONING_PROFILE="${arg#*=}" ;;
        --jobs=*) JOBS="${arg#*=}" ;;
        --cmake-args=*) EXTRA_CMAKE_ARGS="${arg#*=}" ;;
        -h|--help) usage; exit 0 ;;
        configure|build|install|deploy) STEPS+=("$arg") ;;
        *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

if [[ ${#STEPS[@]} -eq 0 ]]; then
    STEPS=(configure build install deploy)
fi

if [[ -z "$QT_IOS" || -z "$QT_HOST" ]]; then
    echo "ERROR: --qt-ios and --qt-host are required" >&2
    usage
    exit 1
fi

mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
DEPS_PREFIX="${DEPS_PREFIX:-$BUILD_ROOT/deps-install}"
HOST_PREFIX="${HOST_PREFIX:-$BUILD_ROOT/host-install}"
BUILD_DIR="$BUILD_ROOT/krita-build-$SDK"
INSTALL_DIR="$BUILD_ROOT/krita-install-$SDK"

IGNORE_PREFIXES="/opt/homebrew;/usr/local;/opt/local"

has_step() {
    local s
    for s in "${STEPS[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

######################################################################
if has_step configure; then
    echo "## Configuring Krita for $SDK in $BUILD_DIR"

    cmake_args=(
        -S "$SRC_DIR" -B "$BUILD_DIR"
        -G "$GENERATOR"
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
        -DCMAKE_PREFIX_PATH="$DEPS_PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$DEPS_PREFIX"
        -DCMAKE_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES"
        -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
        -DQT_HOST_PATH="$QT_HOST"
        -DQT_HOST_PATH_CMAKE_DIR="$QT_HOST/lib/cmake"
        -DKF6_HOST_TOOLING="$HOST_PREFIX/lib/cmake"
        -DBOOST_ROOT="$DEPS_PREFIX"
        -DBUILD_WITH_QT6=ON
        -DALLOW_UNSTABLE=QT6
        -DBUILD_TESTING=OFF
        -DHIDE_SAFE_ASSERTS=ON
        -DKRITA_ENABLE_PCH=OFF
        -DFOUNDATION_BUILD=ON
        -DKRITA_IOS_BUNDLE_IDENTIFIER="$BUNDLE_ID"
        -DKRITA_IOS_DEVELOPMENT_TEAM="$TEAM_ID"
        # The test programs of CheckLibTIFFPSDSupport can't run when
        # cross-compiling. All the libtiff versions we support (4.x) can
        # read and write the Photoshop tags.
        -DTIFF_HAS_PSD_TAGS=ON
        -DTIFF_CAN_WRITE_PSD_TAGS=ON
        # libmypaint is not built by build-deps-ios.sh yet, and
        # FindLibMyPaint fails hard when it can't find the headers
        -DCMAKE_DISABLE_FIND_PACKAGE_LibMyPaint=ON
    )
    if [[ "$SDK" == "iphonesimulator" ]]; then
        cmake_args+=(-DCMAKE_OSX_SYSROOT=iphonesimulator)
    fi

    # Only look at the .pc files of the iOS dependencies, never at the
    # ones of the host (e.g. Homebrew)
    export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig"
    unset PKG_CONFIG_PATH

    # shellcheck disable=SC2086
    "$QT_IOS/bin/qt-cmake" "${cmake_args[@]}" $EXTRA_CMAKE_ARGS
fi

######################################################################
if has_step build; then
    echo "## Building Krita"
    if [[ "$GENERATOR" == "Xcode" ]]; then
        cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" --parallel "$JOBS" -- -sdk "$SDK"
    else
        cmake --build "$BUILD_DIR" --config "$BUILD_TYPE" --parallel "$JOBS"
    fi
fi

######################################################################
if has_step install; then
    echo "## Installing Krita into $INSTALL_DIR"
    cmake --install "$BUILD_DIR" --config "$BUILD_TYPE"
fi

######################################################################
# Changes the install name of a library to @rpath/<name> and rewrites all
# its references to libraries that are deployed into the Frameworks folder
fix_install_names() {
    local file="$1" frameworks="$2"
    local name
    name="$(basename "$file")"

    if otool -D "$file" | tail -n +2 | grep -q .; then
        install_name_tool -id "@rpath/$name" "$file" 2>/dev/null || true
    fi

    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) continue ;;
        esac
        local depname
        depname="$(basename "$dep")"
        if [[ -e "$frameworks/$depname" ]]; then
            install_name_tool -change "$dep" "@rpath/$depname" "$file"
        else
            echo "WARNING: $name depends on $dep, which is not deployed" >&2
        fi
    done

    if ! otool -l "$file" | grep -A2 LC_RPATH | grep -q "@loader_path"; then
        install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
    fi
}

if has_step deploy; then
    APP="$INSTALL_DIR/bin/krita.app"
    if [[ ! -d "$APP" ]]; then
        echo "ERROR: $APP does not exist, run the install step first" >&2
        exit 1
    fi
    echo "## Deploying into $APP"

    FRAMEWORKS="$APP/Frameworks"
    mkdir -p "$FRAMEWORKS"

    # Krita's own libraries and plugins. Everything goes into one flat
    # directory, see KoJsonTrader.
    find "$INSTALL_DIR/lib" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -exec cp -a {} "$FRAMEWORKS/" \;
    if [[ -d "$INSTALL_DIR/lib/kritaplugins" ]]; then
        find "$INSTALL_DIR/lib/kritaplugins" \( -name '*.dylib' -o -name '*.so' \) -exec cp -a {} "$FRAMEWORKS/" \;
    fi

    # dependencies
    find "$DEPS_PREFIX/lib" -maxdepth 1 -name '*.dylib' -exec cp -a {} "$FRAMEWORKS/" \;

    # Qt, if it was built as shared libraries. Since Qt 6.12 the Xcode build
    # embeds the frameworks the executable links to by itself, so only copy
    # what is missing.
    if compgen -G "$QT_IOS/lib/*.framework" >/dev/null; then
        for fw in "$QT_IOS"/lib/*.framework; do
            [[ -e "$FRAMEWORKS/$(basename "$fw")" ]] || cp -a "$fw" "$FRAMEWORKS/"
        done
        if [[ -d "$QT_IOS/plugins" ]]; then
            mkdir -p "$APP/PlugIns"
            cp -a "$QT_IOS/plugins/"* "$APP/PlugIns/"
        fi
    fi

    # data: resources, color schemes, translations, ...
    rm -rf "$APP/share"
    mkdir -p "$APP/share"
    for d in "$INSTALL_DIR/share" "$DEPS_PREFIX/share"; do
        [[ -d "$d" ]] || continue
        rsync -a --exclude 'doc' --exclude 'man' --exclude 'cmake' --exclude 'pkgconfig' \
            --exclude 'ECM' --exclude 'qlogging-categories6' "$d/" "$APP/share/"
    done

    # install names and rpaths
    while IFS= read -r -d '' lib; do
        [[ -L "$lib" ]] && continue
        fix_install_names "$lib" "$FRAMEWORKS"
    done < <(find "$FRAMEWORKS" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -print0)
    fix_install_names "$APP/krita" "$FRAMEWORKS"
    if ! otool -l "$APP/krita" | grep -A2 LC_RPATH | grep -q "@executable_path/Frameworks"; then
        install_name_tool -add_rpath "@executable_path/Frameworks" "$APP/krita"
    fi

    if [[ -n "$PROVISIONING_PROFILE" ]]; then
        cp "$PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"
    fi

    if [[ -n "$CODESIGN_IDENTITY" ]]; then
        echo "## Signing $APP"
        while IFS= read -r -d '' lib; do
            [[ -L "$lib" ]] && continue
            codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$lib"
        done < <(find "$FRAMEWORKS" "$APP/PlugIns" \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null)
        for fw in "$FRAMEWORKS"/*.framework; do
            [[ -e "$fw" ]] || continue
            codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$fw"
        done
        entitlements_args=()
        if [[ -n "$PROVISIONING_PROFILE" ]]; then
            security cms -D -i "$PROVISIONING_PROFILE" > "$BUILD_ROOT/profile.plist"
            /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD_ROOT/profile.plist" > "$BUILD_ROOT/entitlements.plist"
            entitlements_args=(--entitlements "$BUILD_ROOT/entitlements.plist")
        fi
        # (the odd expansion keeps bash 3.2 from macOS happy with an empty array)
        codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" ${entitlements_args[@]+"${entitlements_args[@]}"} "$APP"
    else
        echo "## No --codesign-identity given, the bundle is not signed"
    fi

    echo "## Krita.app is ready: $APP"
fi
