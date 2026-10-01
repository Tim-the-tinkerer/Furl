#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="Furl.app"
BIN_NAME="Furl"
BUNDLE_ID="com.tim.furl"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppInfo.plist 2>/dev/null || echo "unknown")"

if [[ ! -f Assets/AppIcon.icns ]]; then
    if [[ -f Scripts/GenerateAppIcon.swift ]]; then
        echo "Generating app icon..."
        swift Scripts/GenerateAppIcon.swift
    fi
fi

echo "Building Furl ${VERSION} (release)..."
swift build -c release

BIN=".build/release/${BIN_NAME}"
if [[ ! -x "${BIN}" ]]; then
    echo "error: expected binary at ${BIN}" >&2
    exit 1
fi

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${BIN_NAME}"
chmod +x "${APP}/Contents/MacOS/${BIN_NAME}"
cp AppInfo.plist "${APP}/Contents/Info.plist"

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP}..."
xattr -cr "${APP}" 2>/dev/null || true
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}/Contents/MacOS/${BIN_NAME}"
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"

plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --verify --verbose=2 "${APP}" 2>/dev/null || codesign --verify "${APP}"

echo "Done: ${APP} (v${VERSION})"
if [[ "${LAUNCH}" == "true" ]]; then
    pkill -x Furl 2>/dev/null || true
    sleep 0.2
    echo "Launching..."
    open "${APP}"
fi
