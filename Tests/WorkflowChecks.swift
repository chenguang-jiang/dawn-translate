import AppKit
import SwiftUI

// The model's panel is unrelated to these workflow checks; no window is opened.
struct FloatingCaptions: View {
    var model: AppModel
    var speech: SpeechInput
    var body: some View { EmptyView() }
}

actor DelayedCompletion {
    struct Request { let text: String; let continuation: CheckedContinuation<String, Error> }
    private var requests: [Request] = []
    private var received = 0
    func complete(_ text: String) async throws -> String {
        received += 1
        return try await withCheckedThrowingContinuation { requests.append(Request(text: text, continuation: $0)) }
    }
    func count() -> Int { received }
    func answer(_ text: String) { requests.removeFirst().continuation.resume(returning: text) }
    func fail() { requests.removeFirst().continuation.resume(throwing: AppFailure("Simulated network failure")) }
}

@main struct WorkflowChecks {
    @MainActor static func eventually(_ label: String, _ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out: \(label)")
    }
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        print("PASS \(label)")
    }
    @MainActor static func main() async {
        _ = NSApplication.shared
        let gate = DelayedCompletion()
        let model = AppModel(complete: { _, text in try await gate.complete(text) }, registerShortcuts: false)
        model.chineseSpeech = "同意这个时间"
        model.englishSpeech = "That time works for me."
        model.chineseSpeech = "这个时间不行，请改到明天"
        check(model.englishSpeech.isEmpty, "editing the source removes a contradictory previous reply")
        model.play(meeting: true)
        check(model.error?.contains("翻译当前发言") == true && !model.output.isSpeaking, "send rejects an obsolete empty reply before accessing an output device")

        model.autoSend = true
        model.translateSpeech()
        await eventually("first translation") { await gate.count() == 1 }
        check(model.speechPending && model.busy, "pending speech exposes a cancellable state")
        model.stopSpeech()
        check(!model.speechPending && !model.busy, "Stop immediately cancels pending speech")
        await gate.answer("This time does not work for me.")
        // A new request is the ordering barrier: even a non-cooperative old
        // completion must not overwrite it or start playing audio.
        model.chineseSpeech = "请确认日期"
        model.autoSend = false
        model.translateSpeech()
        await eventually("second translation") { await gate.count() == 2 }
        check(model.englishSpeech.isEmpty && !model.output.isSpeaking, "late cancelled completion cannot publish or auto-send its answer")
        await gate.answer("Please confirm the date.")
        await eventually("second result") { !model.busy }
        check(model.englishSpeech == "Please confirm the date." && !model.speechPending, "a fresh translation works after Stop")

        model.translateSpeech()
        await eventually("third translation") { await gate.count() == 3 }
        model.chineseSpeech = "请改到周五"
        await gate.answer("Late answer for the previous source")
        await eventually("cancelled source change") { !model.busy }
        check(model.englishSpeech.isEmpty && !model.output.isSpeaking, "changing the source invalidates an in-flight completion")
        model.translateSpeech()
        await eventually("failed translation") { await gate.count() == 4 }
        await gate.fail()
        await eventually("failure cleanup") { !model.busy }
        check(!model.speechPending && model.chineseSpeech == "请改到周五", "network failure clears pending state and preserves input")

        let captions = DelayedCompletion()
        let meeting = AppModel(complete: { _, text in try await captions.complete(text) }, registerShortcuts: false)
        meeting.enqueue("First segment")
        await eventually("first caption") { await captions.count() == 1 }
        // This is the same queue-resume entry point used after Teams restarts.
        meeting.resumeCaptionTranslations()
        meeting.resumeCaptionTranslations()
        meeting.enqueue("Second segment")
        check(await captions.count() == 1, "rapid resume does not duplicate the active caption worker")
        await captions.answer("第一段")
        await eventually("second caption") { await captions.count() == 2 }
        await captions.answer("第二段")
        await eventually("caption queue drained") { !meeting.meetingBusy }
        check(meeting.captions.map(\.chinese) == ["第一段", "第二段"], "resume while translation is pending drains old and new captions in order")

        meeting.enqueue("Cancelled segment")
        await eventually("caption before clear") { await captions.count() == 3 }
        meeting.clearCaptions()
        meeting.enqueue("Fresh segment")
        await eventually("new session caption") { await captions.count() == 4 }
        await captions.answer("Late cancelled caption")
        check(meeting.captions.count == 1 && meeting.captions[0].chinese == "等待翻译…", "clearing captions isolates late responses from the new session")
        await captions.answer("新会话")
        await eventually("new session drains") { !meeting.meetingBusy }
        check(meeting.captions[0].chinese == "新会话", "old cleanup cannot stop a new caption worker")
        model.shutdown(); meeting.shutdown()
        print("\nWorkflow checks passed. No AI, microphone, Teams capture, or audio playback used.")
    }
}
