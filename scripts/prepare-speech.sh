#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
speech_revision="231638a0717b7822784297e5980965ffcec05810"
model_sha="ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
assets="$PWD/.build/speech-assets"
source_dir="$PWD/.build/whisper-src"
build_dir="$PWD/.build/whisper-build"
mkdir -p "$assets"
if [[ ! -x "$build_dir/bin/whisper-cli" ]] ||    [[ "$(awk -F= '/^CMAKE_OSX_DEPLOYMENT_TARGET:/ { print $2 }' "$build_dir/CMakeCache.txt" 2>/dev/null || true)" != "14.0" ]] ||    [[ "$(cat "$build_dir/dawn-revision.txt" 2>/dev/null || true)" != "$speech_revision" ]]; then
  if [[ ! -d "$source_dir/.git" ]]; then
    git init "$source_dir"
    git -C "$source_dir" remote add origin https://github.com/ggml-org/whisper.cpp.git
  fi
  if [[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" != "$speech_revision" ]]; then
    git -C "$source_dir" fetch --depth 1 origin "$speech_revision"
    git -C "$source_dir" checkout --detach "$speech_revision"
  fi
  cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_ACCELERATE=ON -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  cmake --build "$build_dir" --target whisper-cli -j 6
  printf '%s\n' "$speech_revision" > "$build_dir/dawn-revision.txt"
fi
model="$assets/ggml-small-q5_1.bin"
if [[ ! -f "$model" ]]; then
  curl -L --fail --retry 4 --retry-all-errors \
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin?download=true' -o "$model.download"
  printf '%s  %s\n' "$model_sha" "$model.download" | shasum -a 256 --check --status
  mv "$model.download" "$model"
fi
printf '%s  %s\n' "$model_sha" "$model" | shasum -a 256 --check --status
printf '%s\n' "$speech_revision" > "$assets/whisper-revision.txt"
