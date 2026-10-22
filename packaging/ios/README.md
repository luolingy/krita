# Building Krita for iOS

**Status: experimental.** The iOS port is at an early stage. Most of the
platform integration mirrors what we do on Android; nothing here has been
tested on a real device yet. Expect build failures and runtime issues.

All the commands below have to be run on macOS with Xcode installed.

## Requirements

* macOS with a recent **Xcode** (16 or later) and its command line tools.
  Check the active installation with `xcode-select -p`.
* **CMake** 3.25 or later, **Ninja**, **Meson**, **pkg-config**, **gperf**,
  **gettext** (for `msgfmt`), **autoconf**, **automake** and **libtool**:

  ```shell
  brew install cmake ninja meson pkgconf gperf gettext autoconf automake libtool
  ```

* **Qt 6 for iOS** and a **host Qt 6** for macOS of exactly the same
  version, both with the `qt5compat`, `qtshadertools`, `qtimageformats` and
  `qttasktree` modules. Krita's Qt 6 dependencies currently use Qt 6.11.

### Shared or static Qt?

Krita consists of several shared libraries and many dynamically loaded
plugins (see `KoJsonTrader`). The official Qt binaries for iOS are
**static**. If you link Krita against them, every library and plugin gets
its own copy of Qt, and the resulting application does not work. CMake
prints a warning in this case. Such a build is still useful to check that
Krita compiles for iOS, and that is what the CI does.

To get a working application, use **Qt built as shared libraries for iOS**.
This is supported since **Qt 6.12** (see `qt_finalize_target()` in the Qt
documentation). Build it from source like this:

```shell
# host Qt first (or install it with the Qt online installer)
./configure -prefix $HOME/Qt/6.12/macos -release -nomake tests -nomake examples
cmake --build . --parallel && cmake --install .

# then Qt for iOS
./configure -platform macx-ios-clang -shared -release \
    -qt-host-path $HOME/Qt/6.12/macos -prefix $HOME/Qt/6.12/ios \
    -nomake tests -nomake examples
cmake --build . --parallel && cmake --install .
```

With static Qt you can install it with
[aqtinstall](https://github.com/miurahr/aqtinstall), for example:

```shell
pip install aqtinstall
aqt install-qt mac desktop 6.11.0 clang_64 -m qt5compat qtshadertools qtimageformats qttasktree -O $HOME/Qt
aqt install-qt mac ios 6.11.0 ios -m qt5compat qtshadertools qtimageformats qttasktree -O $HOME/Qt
```

## Building the dependencies

`build-deps-ios.sh` builds the minimal set of libraries Krita needs
(KDE Frameworks, lcms2, exiv2, FreeType, HarfBuzz, Fontconfig, etc.).
The versions match the `transition.now/qt6` branch of
[krita-deps-management](https://invent.kde.org/packaging/krita-deps-management),
which is also cloned to get the patches some of them need.

```shell
packaging/ios/build-deps-ios.sh \
    --qt-ios=$HOME/Qt/6.11.0/ios \
    --qt-host=$HOME/Qt/6.11.0/macos \
    --build-root=$HOME/krita-ios
```

The dependencies are installed into `$HOME/krita-ios/deps-install`, and
the host tools (ECM, `kconfig_compiler`) into `$HOME/krita-ios/host-install`.
Every component is built only once; delete
`$HOME/krita-ios/deps-stamps/<name>.done` or use `--only=<name>` to rebuild
one of them.

Optional features (G'MIC, OpenEXR, HEIF, JPEG XL, OpenColorIO, MLT, ...)
are not built yet, Krita just builds without them.

## Building Krita

```shell
packaging/ios/build-krita-ios.sh \
    --qt-ios=$HOME/Qt/6.11.0/ios \
    --qt-host=$HOME/Qt/6.11.0/macos \
    --build-root=$HOME/krita-ios
```

This runs four steps, which can also be run one by one by passing their
names (`configure`, `build`, `install`, `deploy`):

1. **configure** runs CMake through Qt's `qt-cmake` wrapper, which sets up
   the iOS toolchain. The Xcode generator is used by default; pass
   `--generator=Ninja` for a faster build that is good for compile-testing
   (but cannot compile the asset catalog or sign the bundle).
2. **build** and **install** build Krita and install it into
   `$HOME/krita-ios/krita-install-iphoneos`.
3. **deploy** assembles `bin/krita.app`:
   * all the shared libraries and Krita's plugins are copied into
     `krita.app/Frameworks` (the only place iOS loads code from; Krita looks
     for its plugins there, see `KoJsonTrader`),
   * the data (`share/`) is copied into `krita.app/share` (see
     `KoResourcePaths`),
   * install names are rewritten to `@rpath/...`,
   * if `--codesign-identity` is given, everything is signed, optionally
     with the entitlements of `--provisioning-profile`.

Use `--sdk=iphonesimulator` to build for the simulator. Note that the
simulator slices of the official Qt binaries are `x86_64` only.

## Signing and running on a device

Running on a device requires an Apple Developer account.

* The easiest way is to configure with `--team-id=<your team id>` and the
  default Xcode generator, open `krita-build-iphoneos/krita.xcodeproj` in
  Xcode, select the `krita` scheme and your device and press Run. Xcode
  signs the application automatically. Note that the libraries and the
  data still have to be deployed into the bundle (the **deploy** step).
* Alternatively sign the deployed bundle with `--codesign-identity` and
  `--provisioning-profile`, then install it with
  `xcrun devicectl device install app --device <id> krita.app`.

The bundle identifier defaults to `org.krita` and can be changed with
`--bundle-id` (CMake option `KRITA_IOS_BUNDLE_IDENTIFIER`).

## What is different on iOS

* There is only one window: creating new windows, detaching the canvas and
  window layouts with several windows are disabled (same as on Android).
* Files outside of the application's sandbox are reached through the
  native file dialog (the system document picker). The application's
  `Documents` folder is visible in the Files app (`UIFileSharingEnabled`),
  and documents can be opened in place (`LSSupportsOpeningDocumentsInPlace`).
* External processes cannot be started, so rendering animations with
  FFmpeg and importing videos are not available.
* There is no Python scripting.
* Apple Pencil input arrives as Qt tablet events.

## Known issues and TODO

* Not tested on a device at all.
* App Store rules require loadable code to be packaged as frameworks;
  Krita's plugins are deployed as plain `.so`/`.dylib` files. This is fine
  for development builds, but the plugins have to be wrapped into
  frameworks (or linked statically) before submitting to the App Store.
* The application icon has an alpha channel, which the App Store rejects.
* Animation export needs a non-QProcess encoder (like the
  libav/MediaCodec based one used on Android).
* Translations are not deployed into the place KI18n looks for them yet.
