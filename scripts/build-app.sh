#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="${DAWN_APP_DIR:-$PWD/.build/app.noindex/DawnTranslate.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
mkdir -p .build
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil --convert icns .build/AppIcon.iconset --output "$app_dir/Contents/Resources/AppIcon.icns"
bash scripts/prepare-speech.sh
mkdir -p "$app_dir/Contents/Resources/Speech"
cp .build/whisper-build/bin/whisper-cli "$app_dir/Contents/Resources/Speech/whisper-cli"
cp .build/speech-assets/ggml-small-q5_1.bin "$app_dir/Contents/Resources/Speech/"
cp .build/whisper-src/LICENSE "$app_dir/Contents/Resources/Speech/Whisper-LICENSE.txt"
cp docs/third-party/Whisper-model-LICENSE.txt "$app_dir/Contents/Resources/Speech/Whisper-Model-LICENSE.txt"
cp .build/speech-assets/whisper-revision.txt "$app_dir/Contents/Resources/Speech/"
codesign --force --sign - "$app_dir/Contents/Resources/Speech/whisper-cli"
arch_name="$(uname -m)"
swiftc -swift-version 5 -O -parse-as-library -target "$arch_name-apple-macosx14.0" \
  Sources/DawnTranslate/*.swift -o "$app_dir/Contents/MacOS/DawnTranslate"
cp Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier local.dawn.translate "$app_dir"
echo "$app_dir"
