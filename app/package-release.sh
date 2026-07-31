#!/usr/bin/env bash
# 署名済み.appを公証し、配布用ZIP/DMGを作成する。
#
#   ./package-release.sh 0.1.0
#
# 公証資格情報はDISTRIBUTION.mdを参照。指定がなければ未公証の開発用成果物を作る。
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-${APP_VERSION:-0.1.0}}"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: version must be a semantic version (for example 0.1.0)" >&2
    exit 1
fi

APP_NAME="LocalLLM"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="build/dist"
APP_PATH="build/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-arm64.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-arm64.dmg"
CHECKSUM_PATH="${DIST_DIR}/checksums.txt"
STAGING_DIR="build/dmg-staging"

APP_VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" ./build.sh

submit_for_notarization() {
    local target="$1"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "${target}" --keychain-profile "${NOTARY_PROFILE}" --wait
    else
        xcrun notarytool submit "${target}" \
            --key "${NOTARY_KEY_PATH}" \
            --key-id "${NOTARY_KEY_ID}" \
            --issuer "${NOTARY_ISSUER_ID}" \
            --wait
    fi
}

NOTARIZED=0
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submit app for notarization (keychain profile)"
    mkdir -p "${DIST_DIR}"
    NOTARY_UPLOAD="${DIST_DIR}/notary-upload.zip"
    ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${NOTARY_UPLOAD}"
    submit_for_notarization "${NOTARY_UPLOAD}"
    /bin/rm -f "${NOTARY_UPLOAD}"
    NOTARIZED=1
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "==> Submit app for notarization (App Store Connect API key)"
    mkdir -p "${DIST_DIR}"
    NOTARY_UPLOAD="${DIST_DIR}/notary-upload.zip"
    ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${NOTARY_UPLOAD}"
    submit_for_notarization "${NOTARY_UPLOAD}"
    /bin/rm -f "${NOTARY_UPLOAD}"
    NOTARIZED=1
elif [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
    echo "error: notarization credentials are required" >&2
    exit 1
else
    echo "warning: notarization credentials are not set; creating development artifacts" >&2
fi

if [[ "${NOTARIZED}" == "1" ]]; then
    xcrun stapler staple "${APP_PATH}"
    xcrun stapler validate "${APP_PATH}"
fi

echo "==> Create ZIP and DMG"
mkdir -p "${DIST_DIR}"
/bin/rm -f "${ZIP_PATH}" "${DMG_PATH}" "${CHECKSUM_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

/bin/rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -quiet -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
/bin/rm -rf "${STAGING_DIR}"

if [[ "${NOTARIZED}" == "1" ]]; then
    echo "==> Submit DMG for notarization"
    submit_for_notarization "${DMG_PATH}"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    spctl --assess --type execute --verbose=2 "${APP_PATH}"
fi

(
    cd "${DIST_DIR}"
    shasum -a 256 "$(basename "${ZIP_PATH}")" "$(basename "${DMG_PATH}")" > "$(basename "${CHECKSUM_PATH}")"
)
cat "${CHECKSUM_PATH}"
echo "==> Distribution artifacts: ${DIST_DIR}"
