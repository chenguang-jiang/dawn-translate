import AppKit

@MainActor final class SimulatedAudio: ConversationAudio {
    var onText: ((ConversationSide, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts: [(MeetingPlatform, ConversationMode)] = []
    var plays: [(ConversationSide, String, String)] = []
    var stopped = 0
    var muted = false
    var pendingStart: CheckedContinuation<Void, Error>?
    var delayStart = false
    var playbackGate: [ConversationSide: CheckedContinuation<Void, Error>] = [:]
    var delayPlayback = false
    func validate(mode: ConversationMode, device: String, voice: String, readChinese: Bool) throws { }
    func start(platform: MeetingPlatform, mode: ConversationMode) async throws {
        starts.append((platform, mode))
        if delayStart { try await withCheckedThrowingContinuation { pendingStart = $0 } }
    }
    func stop() async { stopped += 1; for side in ConversationSide.allCases { stopPlayback(side) } }
    func mute(_ value: Bool) { muted = value }
    func stopPlayback(_ side: ConversationSide) { playbackGate.removeValue(forKey: side)?.resume() }
    func play(_ text: String, side: ConversationSide, device: String, voice: String) async throws {
        plays.append((side, text, device))
        if delayPlayback { try await withCheckedThrowingContinuation { playbackGate[side] = $0 } }
    }
}
actor TranslationGate {
    struct Request { let text: String; let continuation: CheckedContinuation<String, Error> }
    var pending: [Request] = []
    var inputs: [(String, String)] = []
    func complete(_ prompt: String, _ text: String) async throws -> String {
        inputs.append((prompt, text))
        return try await withCheckedThrowingContinuation { pending.append(Request(text: text, continuation: $0)) }
    }
    func count() -> Int { inputs.count }
    func answer(_ source: String, _ result: String) {
        let i = pending.firstIndex { $0.text == source }!
        pending.remove(at: i).continuation.resume(returning: result)
    }
    func fail(_ source: String) {
        let i = pending.firstIndex { $0.text == source }!
        pending.remove(at: i).continuation.resume(throwing: AppFailure("模拟断网"))
    }
}

@main struct ConversationChecks {
    static var count = 0
    @MainActor static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS \(label)") }
    @MainActor static func eventually(_ label: String, _ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out: \(label)")
    }
    @MainActor static func main() async {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let oldRoute = defaults.object(forKey: "conversation.routeConfirmed")
        let oldPlatform = defaults.object(forKey: "conversation.platform")
        defer {
            if let oldRoute { defaults.set(oldRoute, forKey: "conversation.routeConfirmed") } else { defaults.removeObject(forKey: "conversation.routeConfirmed") }
            if let oldPlatform { defaults.set(oldPlatform, forKey: "conversation.platform") } else { defaults.removeObject(forKey: "conversation.platform") }
        }
        check(MeetingPlatform.feishu.matches("com.electron.lark") && MeetingPlatform.feishu.matches("com.electron.lark.helper"), "Feishu main and child audio processes are included")
        check(MeetingPlatform.feishu.matches("com.larksuite.lark") && !MeetingPlatform.feishu.matches("com.electron.lark-unrelated"), "Lark is supported without matching unrelated apps")
        check(MeetingPlatform.teams.matches("com.microsoft.teams2") && !MeetingPlatform.teams.matches("com.electron.lark"), "Teams and Feishu capture remain isolated")
        check(!AudioDevice(id: "teams", name: "Microsoft Teams Audio", isVirtual: true).isMeetingLoopback && AudioDevice(id: "bh", name: "BlackHole 2ch", isVirtual: true).isMeetingLoopback, "screen-sharing audio drivers are not offered as loopback microphones")
        let audio = SimulatedAudio(), gate = TranslationGate()
        let session = MeetingConversation(audio: audio)
        session.validateConnection = { }
        session.complete = { prompt, text in try await gate.complete(prompt, text) }
        session.routeConfirmed = false
        session.start(device: "virtual", voice: "male")
        check(audio.starts.isEmpty && session.failure != nil, "unconfirmed routing cannot start outgoing audio")
        session.platform = .feishu; session.routeConfirmed = true
        session.start(device: "virtual", voice: "male")
        session.start(device: "virtual", voice: "male")
        await eventually("start") { session.phase == .running }
        check(audio.starts.count == 1 && audio.starts[0].0 == .feishu, "rapid double start opens only the selected client once")
        audio.onText?(.mine, "明天见"); audio.onText?(.partner, "See you tomorrow")
        await eventually("two lanes") { await gate.count() == 2 }
        audio.onText?(.mine, "下午两点")
        check(await gate.count() == 2, "outgoing translations are serialized while the other direction remains independent")
        await gate.answer("See you tomorrow", "明天见")
        await eventually("Chinese playback") { audio.plays.count == 1 }
        check(audio.plays[0].0 == .partner && audio.plays[0].1 == "明天见", "partner speech goes to the local Chinese playback lane")
        await gate.answer("明天见", "See you tomorrow")
        await eventually("second mine") { await gate.count() == 3 }
        await gate.answer("下午两点", "At 2 PM")
        await eventually("all audio") { audio.plays.count == 3 }
        check(audio.plays.filter { $0.0 == .mine }.map { $0.1 } == ["See you tomorrow", "At 2 PM"], "English reaches the outgoing channel in original utterance order")
        audio.onText?(.mine, "不要发送这一句")
        await eventually("before mute") { await gate.count() == 4 }
        session.toggleMute()
        audio.onText?(.mine, "静音期间")
        await gate.answer("不要发送这一句", "Must never play")
        check(audio.muted && session.turns.count == 4, "mute discards microphone segments and invalidates pending outgoing work")
        session.toggleMute()
        audio.onText?(.mine, "恢复")
        await eventually("unmute") { await gate.count() == 5 }
        check(!audio.plays.contains { $0.1 == "Must never play" }, "late muted result cannot play after unmuting")
        await gate.answer("恢复", "Resumed")
        await eventually("resumed playback") { audio.plays.count == 4 }
        audio.onText?(.partner, "A late reply")
        await eventually("before pause") { await gate.count() == 6 }
        session.stop()
        await eventually("paused") { session.phase == .paused }
        await gate.answer("A late reply", "不能播放")
        session.mode = .captions
        session.start(device: "", voice: "")
        await eventually("captions started") { session.phase == .running }
        audio.onText?(.mine, "不能收自己的声音"); audio.onText?(.partner, "Captions only")
        await eventually("captions translating") { await gate.count() == 7 }
        await gate.answer("Captions only", "只显示字幕")
        await eventually("captions complete") { session.turns.last?.state == .completed }
        check(audio.plays.count == 4 && session.turns.last?.translation == "只显示字幕", "caption mode displays translation without either speech output or microphone text")
        check(!audio.plays.contains { $0.1 == "不能播放" }, "paused session result cannot leak into a restarted session")
        audio.onText?(.partner, "Fail this")
        await eventually("before failure") { await gate.count() == 8 }
        await gate.fail("Fail this")
        await eventually("failure paused") { session.phase == .paused }
        check(session.failure == "模拟断网" && session.turns.last?.source == "Fail this" && session.turns.last?.state == .failed, "translation failure stops both lanes and preserves the failed source")
        session.clear(); check(session.turns.isEmpty, "paused conversation can be cleared")
        audio.delayStart = true
        session.start(device: "", voice: "")
        await eventually("pending startup") { audio.pendingStart != nil }
        session.stop(); session.start(device: "", voice: "")
        check(session.phase == .stopping, "Stop during startup prevents a competing capture start")
        audio.pendingStart?.resume(); audio.pendingStart = nil
        await eventually("cancelled startup unwinds") { session.phase == .paused }
        check(audio.stopped == 3, "partial capture startup is cleaned up before restart is enabled")
        audio.delayStart = false; session.mode = .dialogue; session.routeConfirmed = true; audio.delayPlayback = true
        session.start(device: "virtual", voice: "male")
        await eventually("playback test start") { session.phase == .running }
        audio.onText?(.partner, "Reading now")
        await eventually("reading translation") { await gate.count() == 9 }
        await gate.answer("Reading now", "正在朗读")
        await eventually("speech pending") { audio.playbackGate[.partner] != nil }
        session.readChinese = false
        await eventually("cancel reading") { session.turns.last?.state == .completed }
        check(session.phase == .running && audio.playbackGate.isEmpty, "disabling Chinese reading stops only that playback and keeps translation running")
        for i in 0..<8 { audio.onText?(.partner, "Queue \(i)") }
        await eventually("bounded queue paused") { session.phase == .paused }
        check(session.failure?.contains("跟不上") == true, "queue overload pauses instead of sending stale delayed speech")
        print("\n\(count) conversation checks passed. Simulated capture and playback; no external AI or meeting traffic.")
    }
}
