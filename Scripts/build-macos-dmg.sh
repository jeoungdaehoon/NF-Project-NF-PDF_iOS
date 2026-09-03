#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PROJECT_PATH="${PROJECT_DIR}/NF.xcodeproj"
SCHEME="NF-macOS"
CONFIGURATION="Release"
DERIVED_DATA="${NF_MAC_DERIVED_DATA:-${PROJECT_DIR}/build/macos/DerivedData}"
DIST_DIR="${NF_MAC_DIST_DIR:-${PROJECT_DIR}/dist}"
STAGING_DIR="$(mktemp -d /private/tmp/nf-macos-dmg.XXXXXX)"

cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

mkdir -p "${DIST_DIR}"

xcodebuild \
    -quiet \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_SOURCE="${DERIVED_DATA}/Build/Products/Release/NF macOS.app"
if [[ ! -d "${APP_SOURCE}" ]]; then
    print -u2 "네이티브 macOS 앱을 찾지 못했습니다: ${APP_SOURCE}"
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_SOURCE}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_SOURCE}/Contents/Info.plist")"
APP_DESTINATION="${STAGING_DIR}/NF macOS.app"
DMG_PATH="${DIST_DIR}/NF-${VERSION}-${BUILD_NUMBER}-native-macOS.dmg"
SIGN_IDENTITY="${NF_MAC_SIGN_IDENTITY:--}"

ditto "${APP_SOURCE}" "${APP_DESTINATION}"
xattr -cr "${APP_DESTINATION}"

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign \
        --force \
        --deep \
        --entitlements "${PROJECT_DIR}/NFMac/NFMac.local.entitlements" \
        --sign - \
        "${APP_DESTINATION}"
else
    codesign \
        --force \
        --deep \
        --entitlements "${PROJECT_DIR}/NFMac/NFMac.entitlements" \
        --options runtime \
        --timestamp \
        --sign "${SIGN_IDENTITY}" \
        "${APP_DESTINATION}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DESTINATION}"
ln -s /Applications "${STAGING_DIR}/Applications"
rm -f "${DMG_PATH}"

hdiutil create \
    -volname "NF macOS" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

hdiutil verify "${DMG_PATH}"

if [[ -n "${NF_MAC_NOTARY_PROFILE:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    xcrun notarytool submit \
        "${DMG_PATH}" \
        --keychain-profile "${NF_MAC_NOTARY_PROFILE}" \
        --wait
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
fi

print "DMG 생성 완료: ${DMG_PATH}"
