# SPDX-FileCopyrightText: 2026 luolingy <152292963+luolingy@users.noreply.github.com>
# SPDX-License-Identifier: BSD-3-Clause
#
# Sets up the iOS application bundle of the main Krita executable:
# Info.plist, launch screen, application icon, bundle identifier and
# signing attributes for the Xcode generator.
#
# The target must have been created with qt_add_executable(... MANUAL_FINALIZATION),
# this function finalizes it.

set(KRITA_IOS_PACKAGING_DIR ${CMAKE_CURRENT_LIST_DIR})

function(krita_ios_setup_bundle target)
    set(_version_number "${KRITA_STABLE_VERSION_MAJOR}.${KRITA_STABLE_VERSION_MINOR}.${KRITA_VERSION_RELEASE}")

    # The asset catalog with the application icon. The icon itself comes
    # from the branding directory, so we assemble the catalog in the build
    # directory.
    set(_assets_dir ${CMAKE_CURRENT_BINARY_DIR}/ios/Assets.xcassets)
    file(MAKE_DIRECTORY ${_assets_dir}/AppIcon.appiconset)
    configure_file(${KRITA_IOS_PACKAGING_DIR}/Assets.xcassets/Contents.json
                   ${_assets_dir}/Contents.json COPYONLY)
    configure_file(${KRITA_IOS_PACKAGING_DIR}/Assets.xcassets/AppIcon.appiconset/Contents.json
                   ${_assets_dir}/AppIcon.appiconset/Contents.json COPYONLY)
    configure_file(${CMAKE_SOURCE_DIR}/krita/pics/branding/${BRANDING}/1024-apps-krita.png
                   ${_assets_dir}/AppIcon.appiconset/krita-1024.png COPYONLY)

    if (CMAKE_GENERATOR MATCHES "Xcode")
        # Only Xcode knows how to compile asset catalogs
        target_sources(${target} PRIVATE ${_assets_dir})
        set_source_files_properties(${_assets_dir} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    endif()

    set_target_properties(${target} PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST ${KRITA_IOS_PACKAGING_DIR}/Info.plist.in
        MACOSX_BUNDLE_GUI_IDENTIFIER "${KRITA_IOS_BUNDLE_IDENTIFIER}"
        MACOSX_BUNDLE_BUNDLE_NAME "Krita"
        MACOSX_BUNDLE_LONG_VERSION_STRING "${KRITA_VERSION_STRING}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${_version_number}"
        MACOSX_BUNDLE_BUNDLE_VERSION "${_version_number}"
        MACOSX_BUNDLE_COPYRIGHT "GNU Public License, V2 or, at your option, any later version."

        # picked up by qt_finalize_target()
        QT_IOS_LAUNCH_SCREEN ${KRITA_IOS_PACKAGING_DIR}/LaunchScreen.storyboard

        # all the libraries and plugins are deployed into Krita.app/Frameworks
        INSTALL_RPATH "@executable_path/Frameworks"
        BUILD_WITH_INSTALL_RPATH TRUE

        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${KRITA_IOS_BUNDLE_IDENTIFIER}"
        XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks"
        # iPhone and iPad
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
    )

    if (KRITA_IOS_DEVELOPMENT_TEAM)
        set_target_properties(${target} PROPERTIES
            XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${KRITA_IOS_DEVELOPMENT_TEAM}"
            XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
        )
    else()
        # Let the build succeed without a signing identity, the bundle can
        # be signed later by build-krita-ios.sh or by Xcode
        set_target_properties(${target} PROPERTIES
            XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
        )
        # read by qt_finalize_target() below
        set(QT_NO_SET_XCODE_DEVELOPMENT_TEAM_ID ON)
    endif()

    qt_finalize_target(${target})
endfunction()
