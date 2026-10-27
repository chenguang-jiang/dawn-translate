#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library Sources/DawnTranslate/AIClient.swift \
  Sources/DawnTranslate/Translation.swift Sources/DawnTranslate/LocalSpeech.swift \
  Sources/DawnTranslate/LocalServices.swift Sources/DawnTranslate/AudioServices.swift \
  Sources/DawnTranslate/MeetingConversation.swift Tests/ConversationChecks.swift \
  -o .build/checks/ConversationChecks
.build/checks/ConversationChecks
