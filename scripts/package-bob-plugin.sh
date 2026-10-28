#!/bin/bash
# Builds dist/DawnTranslate.bobplugin: a zip of the plugin folder's contents (not the folder).
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/bin/python3 -c 'import json; print(json.load(open("bob-plugin/info.json"))["version"])')
out="$PWD/dist/DawnTranslate-$version.bobplugin"
mkdir -p dist
rm -f "$out"
(cd bob-plugin && /usr/bin/zip -q -X -r "$out" info.json main.js icon.png lib -x '*.DS_Store')
echo "$out"
shasum -a 256 "$out"
