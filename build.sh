#!/bin/bash
# Build & đóng gói MailBar.
#
#   ./build.sh            → build/MailBar.app (kiến trúc của máy đang dùng) — dùng khi phát triển
#   ./build.sh install    → như trên, rồi copy vào /Applications và mở
#   ./build.sh dist       → bản phát hành universal (Apple Silicon + Intel):
#                           dist/MailBar-<version>.dmg, dist/MailBar-<version>.zip, dist/SHA256SUMS.txt
#
# Phiên bản lấy từ file VERSION. Build number = thời điểm build (yyyymmddHHMM).
#
# Ký số (biến SIGN_IDENTITY):
#   (mặc định) local  → chứng chỉ tự cấp CỐ ĐỊNH trên máy này (tự tạo lần đầu) — Keychain không hỏi lại sau mỗi build
#   -                 → ad-hoc (chữ ký đổi mỗi lần build → Keychain hỏi quyền lại)
#   "Developer ID Application: Tên (TEAMID)"            → ký Apple Developer ID + hardened runtime
#   … + NOTARY_PROFILE=<profile của notarytool>        → ký + công chứng + staple DMG
# Với local/ad-hoc, máy khác cần "Open Anyway" ở lần mở đầu tiên.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MailBar"
BUNDLE_ID="com.phudigital.MailBar"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS="13.0"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-local}"
MODE="${1:-app}"

step() { echo "▸ $*"; }

# $1 = "native" | "universal"
compile() {
    if [ "$1" = "universal" ]; then
        step "Biên dịch arm64…"
        swift build -c release --triple "arm64-apple-macosx${MIN_MACOS}"
        step "Biên dịch x86_64…"
        swift build -c release --triple "x86_64-apple-macosx${MIN_MACOS}"
        mkdir -p build
        lipo -create -output "build/${APP_NAME}-universal" \
            "$(swift build -c release --triple "arm64-apple-macosx${MIN_MACOS}" --show-bin-path)/${APP_NAME}" \
            "$(swift build -c release --triple "x86_64-apple-macosx${MIN_MACOS}" --show-bin-path)/${APP_NAME}"
        BIN="build/${APP_NAME}-universal"
    else
        step "Biên dịch (release, $(uname -m))…"
        swift build -c release
        BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
    fi
}

make_icon() {
    if [ ! -f build/AppIcon.icns ]; then
        step "Tạo icon…"
        rm -rf build/AppIcon.iconset
        swift scripts/make-icon.swift build/AppIcon.iconset
        iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    fi
}

bundle() {
    step "Đóng gói ${APP} (v${VERSION} build ${BUILD_NUMBER})…"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
    # Bỏ bảng symbol: binary nhỏ còn ~một nửa (không ảnh hưởng chạy).
    strip -x "$APP/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    make_icon
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

    cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Phu Digital</string>
</dict>
</plist>
EOF
}

# ── Chứng chỉ ký cố định trên máy này ────────────────────────────────────────────────────────────
# Keychain của macOS gắn quyền đọc mật khẩu với CHỮ KÝ của app. Ký ad-hoc thì chữ ký = mã băm file chạy,
# đổi sau mỗi lần build → macOS hỏi quyền Keychain lại. Ký bằng một chứng chỉ tự cấp CỐ ĐỊNH thì chữ ký
# là "identifier + chứng chỉ", không đổi qua các lần build → bấm "Always Allow" một lần là đủ.
# Chứng chỉ nằm trong keychain riêng (không đụng keychain đăng nhập), tự tạo ở lần build đầu tiên.
LOCAL_SIGN_DIR="${MAILBAR_SIGNING_DIR:-$HOME/Library/Application Support/MailBar-Signing}"
LOCAL_SIGN_KC="$LOCAL_SIGN_DIR/signing.keychain-db"
LOCAL_SIGN_NAME="MailBar Local Signing"

ensure_local_identity() {
    [ -f "$LOCAL_SIGN_KC" ] && [ -f "$LOCAL_SIGN_DIR/identity.sha1" ] && return
    step "Tạo chứng chỉ ký cố định \"$LOCAL_SIGN_NAME\" (chỉ lần đầu) tại $LOCAL_SIGN_DIR…"
    mkdir -p "$LOCAL_SIGN_DIR"
    chmod 700 "$LOCAL_SIGN_DIR"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_SIGN_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # /usr/bin/openssl (LibreSSL của macOS) xuất .p12 theo định dạng mà `security import` đọc được.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/id.p12" -passout pass:mailbar -name "$LOCAL_SIGN_NAME"
    local kcpass; kcpass="$(uuidgen)"
    printf '%s' "$kcpass" > "$LOCAL_SIGN_DIR/keychain.pass"
    chmod 600 "$LOCAL_SIGN_DIR/keychain.pass"
    rm -f "$LOCAL_SIGN_KC"
    security create-keychain -p "$kcpass" "$LOCAL_SIGN_KC"
    security set-keychain-settings "$LOCAL_SIGN_KC"          # không tự khoá
    security unlock-keychain -p "$kcpass" "$LOCAL_SIGN_KC"
    security import "$tmp/id.p12" -k "$LOCAL_SIGN_KC" -P mailbar -T /usr/bin/codesign >/dev/null
    # Cho codesign dùng khoá mà không hiện hộp thoại.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpass" "$LOCAL_SIGN_KC" >/dev/null
    /usr/bin/openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' \
        > "$LOCAL_SIGN_DIR/identity.sha1"
    rm -rf "$tmp"
}

sign_local() {
    ensure_local_identity
    local sha1; sha1="$(cat "$LOCAL_SIGN_DIR/identity.sha1")"
    step "Ký bằng chứng chỉ cố định \"$LOCAL_SIGN_NAME\" (${sha1:0:8}…)…"
    security unlock-keychain -p "$(cat "$LOCAL_SIGN_DIR/keychain.pass")" "$LOCAL_SIGN_KC"
    # codesign chỉ tìm identity trong "danh sách tìm kiếm" keychain → thêm tạm keychain ký, xong khôi phục nguyên trạng.
    local orig; orig="$(security list-keychains -d user | tr -d '"' | xargs)"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $orig "$LOCAL_SIGN_KC"
    local rc=0
    codesign --force --keychain "$LOCAL_SIGN_KC" --sign "$sha1" "$1" || rc=$?
    # shellcheck disable=SC2086
    security list-keychains -d user -s $orig
    return $rc
}

sign() {
    if [ "$SIGN_IDENTITY" = "-" ]; then
        step "Ký ad-hoc…"
        codesign --force --sign - "$1"
    elif [ "$SIGN_IDENTITY" = "local" ]; then
        sign_local "$1"
    else
        step "Ký bằng \"$SIGN_IDENTITY\" (hardened runtime)…"
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
    fi
}

dist() {
    local out="dist"
    local dmg="${out}/${APP_NAME}-${VERSION}.dmg"
    local zip="${out}/${APP_NAME}-${VERSION}.zip"
    mkdir -p "$out"
    rm -f "$dmg" "$zip"

    step "Tạo ${zip}…"
    ditto -c -k --keepParent "$APP" "$zip"

    step "Tạo ${dmg}…"
    local stage="build/dmg"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    cp "packaging/Doc-truoc-khi-cai.txt" "$stage/Đọc trước khi cài.txt"
    hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "$stage" -ov -format UDZO "$dmg"
    rm -rf "$stage"

    if [ "$SIGN_IDENTITY" != "-" ] && [ "$SIGN_IDENTITY" != "local" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
        if [ -n "${NOTARY_PROFILE:-}" ]; then
            step "Gửi Apple công chứng (notarize)…"
            xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$dmg"
        fi
    fi

    (cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" > SHA256SUMS.txt)
    echo
    echo "✓ Bản phát hành v${VERSION} (build ${BUILD_NUMBER}):"
    ls -lh "$dmg" "$zip" | awk '{print "   " $5 "\t" $9}'
    echo "   kiến trúc: $(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
}

case "$MODE" in
    app|"")
        compile native; bundle; sign "$APP"
        echo "✓ Xong: $APP  (v${VERSION}, chạy: open $APP)"
        ;;
    install)
        compile native; bundle; sign "$APP"
        step "Cài vào /Applications…"
        pkill -x "$APP_NAME" 2>/dev/null || true
        rm -rf "/Applications/${APP_NAME}.app"
        cp -R "$APP" /Applications/
        open "/Applications/${APP_NAME}.app"
        echo "✓ Đã cài và mở /Applications/${APP_NAME}.app (v${VERSION})"
        ;;
    dist)
        compile universal; bundle; sign "$APP"; dist
        ;;
    *)
        echo "Dùng: ./build.sh [app|install|dist]" >&2
        exit 1
        ;;
esac
