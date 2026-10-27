#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library Sources/DawnTranslate/AIClient.swift \
  Sources/DawnTranslate/Translation.swift Sources/DawnTranslate/ImageImport.swift Sources/DawnTranslate/ContentImport.swift Sources/DawnTranslate/LocalSpeech.swift Sources/DawnTranslate/ClipboardShortcuts.swift \
  Sources/DawnTranslate/EmailWorkflow.swift \
  Sources/DawnTranslate/LocalServices.swift Sources/DawnTranslate/AudioServices.swift \
  Tests/Checks.swift -o .build/checks/CoreChecks
.build/checks/CoreChecks
swiftc -swift-version 5 -parse-as-library Sources/DawnTranslate/AIClient.swift \
  Sources/DawnTranslate/Translation.swift Sources/DawnTranslate/ImageImport.swift Sources/DawnTranslate/ContentImport.swift Sources/DawnTranslate/LocalSpeech.swift Sources/DawnTranslate/ClipboardShortcuts.swift \
  Sources/DawnTranslate/EmailWorkflow.swift Sources/DawnTranslate/LocalServices.swift \
  Sources/DawnTranslate/AudioServices.swift Sources/DawnTranslate/QuickAccess.swift \
  Sources/DawnTranslate/MeetingConversation.swift Sources/DawnTranslate/AppModel.swift Tests/WorkflowChecks.swift -o .build/checks/WorkflowChecks
.build/checks/WorkflowChecks
swiftc -swift-version 5 -parse-as-library Sources/DawnTranslate/AIClient.swift \
  Sources/DawnTranslate/Translation.swift Sources/DawnTranslate/ImageImport.swift \
  Sources/DawnTranslate/ContentImport.swift Sources/DawnTranslate/LocalServices.swift \
  Tests/ContentChecks.swift -o .build/checks/ContentChecks
.build/checks/ContentChecks
