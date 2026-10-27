import AppKit
import AVFoundation
import ScreenCaptureKit

enum MeetingPlatform: String, CaseIterable, Identifiable {
    case teams = "Teams", feishu = "飞书"
    var id: String { rawValue }
    var bundleIdentifiers: [String] {
        switch self {
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .feishu: ["com.electron.lark", "com.larksuite.lark"]
        }
    }
    func matches(_ identifier: String) -> Bool {
        bundleIdentifiers.contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
    }
}

// Convert capture buffers to the same 16 kHz mono PCM used by local ASR.
// A lock covers converter/segmenter state because capture callbacks are not on MainActor.
final class AudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var segmenter = SpeechSegmenter()
    private var onSegment: (() -> Void)?
    private var pending: [[Float]] = []
    private var onFailure: (() -> Void)?
    private var muted = false
    func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value; segmenter = SpeechSegmenter(); pending = []; converter = nil; inputFormat = nil
    }
    func start(segment: @escaping () -> Void, failure: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        converter = nil; inputFormat = nil; segmenter = SpeechSegmenter(); pending = []; muted = false
        onSegment = segment; onFailure = failure
    }
    func drain() -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = []; return result
    }
    func finish() -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        onSegment = nil; onFailure = nil
        // Flush the sample-rate converter's delayed tail before ending the last
        // speech segment, otherwise the final phoneme can be truncated.
        if let converter, let tail = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) {
            var error: NSError?
            converter.convert(to: tail, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if error == nil, tail.frameLength > 0, let channel = tail.floatChannelData?[0] {
                pending += segmenter.append(Array(UnsafeBufferPointer(start: channel, count: Int(tail.frameLength))))
            }
        }
        converter = nil; inputFormat = nil
        if let tail = segmenter.flush() { pending.append(tail) }
        let result = pending; pending = []; return result
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        onSegment = nil; onFailure = nil; pending = []; converter = nil; inputFormat = nil; segmenter = SpeechSegmenter()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let callback = onSegment, !muted else { lock.unlock(); return }
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate + 64)) else {
            let failure = onFailure; lock.unlock(); failure?(); return
        }
        var used = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else {
            let failure = onFailure; lock.unlock(); failure?(); return
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let segments = segmenter.append(samples)
        pending += segments
        lock.unlock()
        if !segments.isEmpty { callback() }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        append(sample)
    }
    func append(_ sample: CMSampleBuffer) {
        guard sample.isValid, sample.numSamples > 0, sample.numSamples < 1_000_000,
              let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: pcm.mutableAudioBufferList) == noErr else { return }
        append(pcm)
    }
}

@MainActor
final class SpeechInput: NSObject, ObservableObject, SCStreamDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var partial = ""
    @Published private(set) var detectedLanguage = ""
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let sink = AudioSink()
    private let recognizer: LocalSpeechEngine
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var stream: SCStream?
    private var generation = UUID()
    private var meetingMode = false
    private var capturedPlatform: MeetingPlatform = .teams
    private var starting = false
    private var queued: [[Float]] = []
    private var worker: Task<Void, Never>?
    private var acceptingSegments = false

    init(recognizer: LocalSpeechEngine = LocalSpeechEngine()) { self.recognizer = recognizer; super.init() }

    private func begin(meeting: Bool) throws {
        try recognizer.validate()
        generation = UUID(); meetingMode = meeting
        partial = ""; detectedLanguage = ""; queued = []; acceptingSegments = true
        let token = generation
        sink.start(segment: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.acceptingSegments else { return }
                for samples in self.sink.drain() { self.enqueue(samples) }
            }
        }, failure: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.isRunning else { return }
                self.onError?("无法转换录音格式，请检查输入设备。")
                await self.stop()
            }
        })
    }
    func startMicrophone(continuous: Bool = false) async throws {
        guard !isRunning, !isTranscribing, !starting else { return }
        starting = true; defer { starting = false }
        try recognizer.validate()
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AppFailure("请在系统设置 → 隐私与安全性 → 麦克风中允许 DawnTranslate。") }
        let engine = AVAudioEngine()
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure("没有可用的麦克风，请检查系统输入设备。") }
        try begin(meeting: continuous)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        self.engine = engine; isRunning = true
        do {
            engine.prepare(); try engine.start()
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.onError?("麦克风配置发生变化，录音已停止。请检查系统输入设备后重试。")
                    await self.stop()
                }
            }
        } catch { await stop(); throw error }
    }
    func startTeams() async throws { try await startMeeting(.teams) }
    func startMeeting(_ platform: MeetingPlatform) async throws {
        guard !isRunning, !isTranscribing, !starting else { return }
        starting = true; defer { starting = false }
        try recognizer.validate()
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw AppFailure("无法获取 \(platform.rawValue) 音频。请在系统设置的“屏幕与系统音频录制”中允许本应用，然后重新打开应用。") }
        let applications = content.applications.filter { platform.matches($0.bundleIdentifier) }
        guard !applications.isEmpty else { throw AppFailure("未找到 \(platform.rawValue) 桌面客户端。请先启动客户端；暂不支持浏览器中的会议。") }
        guard let display = content.displays.first else { throw AppFailure("没有可用的显示器，无法创建会议音频捕获。") }
        capturedPlatform = platform
        try begin(meeting: true)
        let filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000; config.channelCount = 1
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.dawn.translate.meeting-audio"))
        stream = capture; isRunning = true
        do { try await capture.startCapture() } catch { await stop(); throw error }
    }
    private func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard queued.count < 6 else {
            onError?("本机识别暂时跟不上语速，已停止收音。请分段说话后重试。")
            Task { await self.stop() }; return
        }
        queued.append(samples)
        guard worker == nil else { return }
        let token = generation
        isTranscribing = true
        worker = Task {
            defer { if generation == token { worker = nil; isTranscribing = false } }
            while !queued.isEmpty, !Task.isCancelled, generation == token {
                let audio = queued.removeFirst()
                do {
                    let result = try await recognizer.recognize(audio)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    guard !result.text.isEmpty else { continue }
                    detectedLanguage = result.languageLabel
                    if meetingMode { onUtterance?(result.text) }
                    else {
                        guard partial.count + result.text.count < 60_000 else {
                            onError?("发言内容较长，已停止录音；请先处理当前内容后再录制。")
                            await stop(); return
                        }
                        partial += (partial.isEmpty ? "" : " ") + result.text
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, generation == token else { return }
                    onError?(error.localizedDescription)
                    // Do not automatically send an incomplete microphone transcript.
                    if !meetingMode { generation = UUID(); queued = []; worker = nil; isTranscribing = false; await stop(); return }
                }
            }
        }
    }
    private func stopCapture() async {
        isRunning = false
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        let capture = stream; stream = nil
        try? await capture?.stopCapture()
    }
    private func finishCapture() async {
        await stopCapture()
        // Drain captured segments and the tail in capture order, including any
        // whose notification has not yet reached MainActor.
        for samples in sink.finish() { enqueue(samples) }
        acceptingSegments = false
        let current = worker
        await current?.value
    }
    func finishMicrophone() async -> String {
        let token = generation
        await finishCapture()
        return generation == token ? partial : ""
    }
    func finishMeeting() async { await finishCapture() }
    func discardPendingRecognition() {
        let running = isRunning, mode = meetingMode
        cancelRecognition()
        partial = ""; detectedLanguage = ""
        if running {
            do { try begin(meeting: mode) }
            catch { onError?(error.localizedDescription); Task { await self.stop() } }
        }
    }
    func setMuted(_ value: Bool) {
        discardPendingRecognition()
        sink.setMuted(value)
    }
    func cancelRecognition() {
        acceptingSegments = false; generation = UUID()
        worker?.cancel(); worker = nil; queued = []; isTranscribing = false
        sink.cancel()
    }
    func stop() async {
        cancelRecognition()
        await stopCapture()
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.onError?("\(self.capturedPlatform.rawValue) 音频已中断：\(error.localizedDescription)")
            await self.stop()
        }
    }
}

@MainActor
final class SpeechOutput: NSObject, ObservableObject, NSSoundDelegate {
    @Published var isSpeaking = false
    @Published var status = ""
    var onError: ((String) -> Void)?
    private var synthesizer = AVSpeechSynthesizer()
    private var sound: NSSound?
    private var fileURL: URL?
    private var monitor: Timer?
    private var writer: SpeechFileWriter?
    private var renderTimeout: Task<Void, Never>?
    private var token = UUID()

    func speak(_ text: String, deviceUID: String?, toMeeting: Bool, voiceIdentifier: String? = nil, language: String = "en") throws {
        guard !isSpeaking else { throw AppFailure("请等待当前语音结束，或先停止播放。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("没有可播放的译文。") }
        guard text.count < 12_000 else { throw AppFailure("发言过长，请分段发送。") }
        if toMeeting {
            guard let deviceUID, AudioDevices.outputs().contains(where: { $0.id == deviceUID && $0.isVirtual }) else {
                throw AppFailure("请选择已连接的虚拟音频通道，并在会议软件中把它选为麦克风。")
            }
        }
        let voice: AVSpeechSynthesisVoice
        if language == "zh" {
            guard let chinese = AVSpeechSynthesisVoice(language: "zh-CN") else { throw AppFailure("请在系统设置中下载普通话声音后开启中文朗读。") }
            voice = chinese
        } else { voice = try EnglishMaleVoice.natural(identifier: voiceIdentifier) }
        token = UUID(); let activeToken = token
        isSpeaking = true; status = "正在生成\(language == "zh" ? "中文" : "英文")语音…"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dawn-voice-\(UUID().uuidString).caf")
        fileURL = url
        let writer = SpeechFileWriter(url: url)
        self.writer = writer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // A measured conversational pace lets punctuation carry the phrasing;
        // do not randomize pitch or timing, which makes synthesized speech less natural.
        utterance.rate = language == "en" ? 0.48 : AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        renderTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.token == activeToken else { return }
            self.fail("语音生成超时，请检查系统声音后重试。")
        }
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let outcome = writer.consume(pcm)
            if let outcome {
                Task { @MainActor in
                    guard let self, self.token == activeToken else { return }
                    switch outcome {
                    case .failure(let error): self.fail(error.localizedDescription)
                    case .success:
                        do { try self.play(url, deviceUID: deviceUID, toMeeting: toMeeting) }
                        catch { self.fail(error.localizedDescription) }
                    }
                }
            }
        }
    }

    private func play(_ url: URL, deviceUID: String?, toMeeting: Bool) throws {
        renderTimeout?.cancel(); renderTimeout = nil
        if toMeeting {
            guard AudioDevices.outputs().contains(where: { $0.id == deviceUID && $0.isVirtual }) else { throw AppFailure("虚拟音频设备已断开，已取消发送。") }
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else { throw AppFailure("无法读取生成的语音。") }
        sound.delegate = self
        if let deviceUID {
            sound.playbackDeviceIdentifier = deviceUID
            guard sound.playbackDeviceIdentifier == deviceUID else { throw AppFailure("无法选择指定的输出设备，已取消播放。") }
        }
        self.sound = sound
        guard sound.play() else { throw AppFailure("无法播放到所选设备，请检查音频设备连接。") }
        status = toMeeting ? "正在输出到会议麦克风" : "正在本机播放"
        if toMeeting, let deviceUID {
            monitor = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if !AudioDevices.outputs().contains(where: { $0.id == deviceUID && $0.isVirtual }) {
                        self?.fail("虚拟设备已断开，已停止发送。")
                    }
                }
            }
        }
    }

    private func fail(_ message: String) { stop(); onError?(message) }
    func stop() {
        token = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        renderTimeout?.cancel(); renderTimeout = nil
        writer?.cancel(); writer = nil
        sound?.stop(); sound = nil
        monitor?.invalidate(); monitor = nil
        isSpeaking = false; status = ""
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }
    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.sound === sound else { return }
            if flag { self.stop() } else { self.fail("播放已中断，请检查输出设备。") }
        }
    }
}

enum EnglishMaleVoice {
    static var available: [AVSpeechSynthesisVoice] {
        let preferredNames = ["Daniel", "Alex", "Tom", "Evan", "Oliver", "Aaron", "Lee", "Rishi", "Fred"]
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-") && $0.gender == .male }
            .sorted { left, right in
                if left.quality != right.quality { return left.quality.rawValue > right.quality.rawValue }
                let leftRank = preferredNames.firstIndex(of: left.name) ?? 100
                let rightRank = preferredNames.firstIndex(of: right.name) ?? 100
                if leftRank != rightRank { return leftRank < rightRank }
                return left.identifier < right.identifier
            }
    }

    static func resolve(identifier: String? = nil) throws -> AVSpeechSynthesisVoice {
        if let identifier, !identifier.isEmpty {
            guard let voice = available.first(where: { $0.identifier == identifier }) else {
                throw AppFailure("所选英文男声不可用，请在声音菜单重新选择，或在系统设置中下载该声音。")
            }
            return voice
        }
        guard let voice = available.first else {
            throw AppFailure("本机没有可用的英文男声，请在系统设置 → 辅助功能 → 朗读内容中下载英文男声。")
        }
        return voice
    }
    static func natural(identifier: String? = nil) throws -> AVSpeechSynthesisVoice {
        let selected = try resolve(identifier: identifier)
        // Downloaded enhanced/premium variants may coexist with the compact
        // identifier saved by a previous version. Prefer the same voice upgraded.
        return available.first(where: { baseName($0) == baseName(selected) && $0.language == selected.language && $0.quality.rawValue > selected.quality.rawValue }) ?? selected
    }
    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "高级"
        case .enhanced: "增强"
        default: "普通"
        }
    }
    private static func baseName(_ voice: AVSpeechSynthesisVoice) -> String { voice.name.components(separatedBy: " (").first ?? voice.name }
    static func displayName(_ voice: AVSpeechSynthesisVoice) -> String { "\(baseName(voice)) · \(qualityLabel(voice))" }
}

final class SpeechFileWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var completed = false
    init(url: URL) { self.url = url }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        completed = true; file = nil
        try? FileManager.default.removeItem(at: url)
    }
    func consume(_ buffer: AVAudioPCMBuffer) -> Result<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return nil }
        do {
            if buffer.frameLength == 0 {
                completed = true; file = nil
                guard FileManager.default.fileExists(atPath: url.path) else { throw AppFailure("系统未生成语音，请检查英文声音是否已下载。") }
                return .success(())
            }
            if file == nil { file = try AVAudioFile(forWriting: url, settings: buffer.format.settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved) }
            try file?.write(from: buffer)
            return nil
        } catch { completed = true; file = nil; return .failure(error) }
    }
}
