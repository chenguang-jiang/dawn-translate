#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/prepare-speech.sh
assets="$PWD/.build/speech-assets"
cp .build/whisper-build/bin/whisper-cli "$assets/whisper-cli"
chinese_voice="$(say -v '?' | awk '/zh_CN/ { sub(/[[:space:]]+zh_CN.*/, ""); print; exit }')"
if [[ -z "$chinese_voice" ]]; then
  echo 'No installed Mandarin voice available for the speech fixture.' >&2
  exit 1
fi
say -v Daniel -o "$assets/english.aiff" 'Please confirm the meeting time. We can discuss the project tomorrow.'
say -v "$chinese_voice" -o "$assets/chinese.aiff" '你好，请确认明天的会议时间，我们可以一起讨论项目进度。'
afconvert "$assets/english.aiff" "$assets/english.wav" -f WAVE -d LEI16@16000 -c 1
afconvert "$assets/chinese.aiff" "$assets/chinese.wav" -f WAVE -d LEI16@16000 -c 1
swiftc -swift-version 5 -parse-as-library Sources/DawnTranslate/AIClient.swift \
  Sources/DawnTranslate/Translation.swift Sources/DawnTranslate/LocalSpeech.swift \
  Sources/DawnTranslate/LocalServices.swift Sources/DawnTranslate/AudioServices.swift \
  Tests/SpeechChecks.swift -o .build/checks/SpeechChecks
.build/checks/SpeechChecks "$assets"
