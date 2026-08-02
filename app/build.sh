#!/usr/bin/env bash
# XcodeでMLXのMetalライブラリを含むLocalLLM.appを組み立てる。
#
#   ./build.sh            # app/build/LocalLLM.appを作成
#   ./build.sh --install  # /Applicationsへインストールして起動
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LocalLLM"
BUNDLE_ID="com.local-llm.app"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_ROOT="build"
DERIVED_DATA="${BUILD_ROOT}/DerivedData"
PRODUCTS="${DERIVED_DATA}/Build/Products/Release"
APP_DIR="${BUILD_ROOT}/${APP_NAME}.app"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "error: LocalLLMはApple Silicon Mac専用です。" >&2
    exit 1
fi

echo "==> Xcode Release build (arm64)"
xcodebuild \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    build

BIN_PATH="${PRODUCTS}/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: 実行ファイルが見つかりません: ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assemble ${APP_DIR}"
/bin/rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
ditto "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# SwiftPM依存のリソースにはMLXのdefault.metallibやPrivacy Manifestが含まれる。
for bundle in "${PRODUCTS}"/*.bundle; do
    [[ -d "${bundle}" ]] || continue
    ditto "${bundle}" "${APP_DIR}/Contents/Resources/$(basename "${bundle}")"
done

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>音声で質問を入力するためにマイクを使用します。音声認識はMac上で処理されます。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>音声による質問入力をMac上で文字起こしするために使用します。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Developer IDではHardened Runtimeとsecure timestampを必須にする。
# ローカル開発は安定した自己署名証明書、なければad-hoc署名にフォールバックする。
SIGN_IDENTITY="${SIGN_IDENTITY:-LocalLLM Dev}"
STRICT_SIGNING_CHECK=1
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "==> Code sign (ad-hoc)"
    codesign --force --deep --options runtime --timestamp=none --sign - "${APP_DIR}"
elif security find-identity -p codesigning 2>/dev/null | grep -Fq "${SIGN_IDENTITY}"; then
    if [[ "${SIGN_IDENTITY}" == Developer\ ID\ Application:* ]]; then
        echo "==> Code sign (Developer ID)"
        codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
    else
        echo "==> Code sign (local identity: ${SIGN_IDENTITY})"
        codesign --force --deep --options runtime --timestamp=none --sign "${SIGN_IDENTITY}" "${APP_DIR}"
        # 開発用の自己署名証明書は意図的にAppleの信頼チェーン外。
        STRICT_SIGNING_CHECK=0
    fi
else
    echo "==> Code sign (ad-hoc; '${SIGN_IDENTITY}' was not found)"
    codesign --force --deep --options runtime --timestamp=none --sign - "${APP_DIR}"
fi

if [[ "${STRICT_SIGNING_CHECK}" == "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
else
    codesign --display --requirements - "${APP_DIR}" >/dev/null
fi
echo "==> Built ${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${APP_NAME}.app"
    echo "==> Install ${DEST}"
    pkill -f "${DEST}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    /bin/rm -rf "${DEST}"
    ditto "${APP_DIR}" "${DEST}"
    open "${DEST}"
    echo "Installed and launched."
fi
