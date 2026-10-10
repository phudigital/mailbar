#!/bin/bash
# Tạo GitHub Release cho phiên bản trong file VERSION, từ các file đã build bằng `./build.sh dist`.
#   ./scripts/release.sh
# Điều kiện: đã `gh auth login`, đã commit hết thay đổi, đã chạy `./build.sh dist`.
# App đời 1.4.0+ tự cập nhật bằng cách hỏi release mới nhất của repo này (xem Updater.swift), nên release PHẢI có:
#   MailBar-<ver>.zip  và  SHA256SUMS.txt (chỉ chứa mã băm của phiên bản này).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="phudigital/mailbar"
VER="$(tr -d '[:space:]' < VERSION)"
TAG="v$VER"
ZIP="dist/MailBar-$VER.zip"
DMG="dist/MailBar-$VER.dmg"

[ -f "$ZIP" ] && [ -f "$DMG" ] || { echo "Thiếu $ZIP hoặc $DMG — chạy ./build.sh dist trước." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Còn thay đổi chưa commit — commit rồi chạy lại." >&2; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "Release $TAG đã tồn tại." >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( cd dist && shasum -a 256 "MailBar-$VER.dmg" "MailBar-$VER.zip" ) > "$TMP/SHA256SUMS.txt"
# Ghi chú release = mục của phiên bản này trong CHANGELOG.md.
awk -v v="$VER" '$0 ~ "^## \\["v"\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md > "$TMP/notes.md"
[ -s "$TMP/notes.md" ] || echo "Phiên bản $VER" > "$TMP/notes.md"

git push origin HEAD
gh release create "$TAG" "$DMG" "$ZIP" "$TMP/SHA256SUMS.txt" \
    --repo "$REPO" --target "$(git rev-parse HEAD)" --title "MailBar $VER" --notes-file "$TMP/notes.md"
echo "✓ Đã phát hành $TAG: https://github.com/$REPO/releases/tag/$TAG"
