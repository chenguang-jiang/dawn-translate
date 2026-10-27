#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
arch_name="$(uname -m)"
case "$arch_name" in arm64|x86_64) ;; *) echo 'Unsupported architecture' >&2; exit 1 ;; esac
stage="$PWD/.build/release.noindex"
app_dir="$stage/DawnTranslate.app"
disk_dir="$stage/disk"
output_dir="${DAWN_RELEASE_DIR:-$PWD/dist}"
mkdir -p "$stage" "$output_dir"
# Build solely from source and named resources. Never copy the user's installed
# app, preferences, keychain, credentials, recordings, or development tree.
if [[ -e "$app_dir" ]]; then rm -rf "$app_dir"; fi
DAWN_APP_DIR="$app_dir" bash scripts/build-app.sh
codesign --verify --deep --strict "$app_dir"
if [[ -e "$disk_dir" ]]; then rm -rf "$disk_dir"; fi
mkdir -p "$disk_dir"
ditto "$app_dir" "$disk_dir/DawnTranslate.app"
ln -s /Applications "$disk_dir/Applications"
cp docs/安装说明.txt "$disk_dir/安装说明.txt"
base="DawnTranslate-${version}-macOS-${arch_name}"
if [[ -e "$output_dir/$base.dmg" ]]; then rm "$output_dir/$base.dmg"; fi
hdiutil create -volname "DawnTranslate $version" -srcfolder "$disk_dir" -format UDZO -ov "$output_dir/$base.dmg"
(
  cd "$stage"
  if [[ -e "$output_dir/$base.zip" ]]; then rm "$output_dir/$base.zip"; fi
  ditto -c -k --keepParent DawnTranslate.app "$output_dir/$base.zip"
)
(
  cd "$output_dir"
  shasum -a 256 "$base.dmg" "$base.zip" > "$base-SHA256SUMS.txt"
)
echo "Installer: $output_dir/$base.dmg"
echo "Portable archive: $output_dir/$base.zip"
echo 'Local ad-hoc signature; not Apple-notarized.'
