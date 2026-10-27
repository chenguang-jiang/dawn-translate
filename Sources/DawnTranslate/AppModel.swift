import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Workspace: String, CaseIterable, Identifiable {
    case translate = "文字翻译", email = "邮件回复", meeting = "会议翻译", speak = "单句翻译", settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .translate: "character.bubble"
        case .email: "envelope"
        case .meeting: "captions.bubble"
        case .speak: "waveform"
        case .settings: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .translate: "自动识别中英文，双向翻译。"
        case .email: "给出上下文，用自己的意思回复。"
        case .meeting: "说中文，听中文；Teams 与飞书双向翻译。"
        case .speak: "用中文组织想法，让英文替你表达。"
        case .settings: "连接你的模型，设置会议语音通道。"
        }
    }
}

struct Caption: Identifiable {
    let id = UUID()
    let date = Date()
    let english: String
    var chinese = "等待翻译…"
    var failed = false
}

@MainActor
private final class CaptionPanel: NSPanel {
    var onClose: (() -> Void)?
    override func close() { super.close(); onClose?() }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var workspace: Workspace = .translate
    @Published var configuration = AIConfiguration()
    @Published var apiKey = ""
    @Published var requiresKeyAuthorization = false
    @Published var authorizingKey = false
    @Published var savedConfiguration = AIConfiguration()
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var source = "" {
        didSet { if oldValue != source { translationMode = .automatic; translation = ""; resultDirection = nil } }
    }
    @Published var translationMode: TranslationMode = .automatic {
        didSet { if oldValue != translationMode { translation = ""; resultDirection = nil } }
    }
    @Published var translationHistory = TranslationHistory()
    @Published var translation = ""
    @Published var resultDirection: TranslationDirection?
    var detectedDirection: TranslationDirection { translationMode.direction(for: source) }
    @Published var emailDraft = EmailDraft()
    var emailContext: String { get { emailDraft.context } set { emailDraft.updateContext(newValue) } }
    var emailIntent: String { get { emailDraft.intent } set { emailDraft.updateIntent(newValue) } }
    var emailTone: String { get { emailDraft.tone } set { emailDraft.updateTone(newValue) } }
    var emailReply: String { get { emailDraft.reply } set { emailDraft.editReply(newValue) } }
    var contextMeaning: String { emailDraft.contextTranslation }
    var replyMeaning: String { emailDraft.replyTranslation }
    @Published var chineseSpeech = "" {
        didSet {
            guard oldValue != chineseSpeech else { return }
            let hadReply = !englishSpeech.isEmpty || speechPending
            stopSpeech()
            englishSpeech = ""
            if hadReply { notice = "发言已修改，请重新翻译。" }
        }
    }
    @Published private(set) var speechPending = false
    private var speechRequestID: UUID?
    private var speechStopID = UUID()
    private let completionOverride: (@MainActor (String, String) async throws -> String)?
    @Published var englishSpeech = ""
    @Published var autoSend = false
    @Published var voiceIdentifier = UserDefaults.standard.string(forKey: "speech.maleVoice") ?? "" {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "speech.maleVoice") }
    }
    var voiceName: String { (try? EnglishMaleVoice.natural(identifier: voiceIdentifier).name) ?? "选择英文男声" }
    var outputDeviceName: String? { devices.first(where: { $0.id == savedConfiguration.outputDeviceUID })?.name }
    @Published var captions: [Caption] = []
    @Published var devices: [AudioDevice] = []
    @Published var meetingBusy = false
    @Published var transitioningAudio = false
    @Published var showFloating = false
    let microphone = SpeechInput()
    let meeting = SpeechInput()
    let output = SpeechOutput()
    let conversation: MeetingConversation
    private var quickAccess: QuickAccess?
    private var clipboardShortcuts: ClipboardShortcuts?
    var translationInputFocused = false
    @Published var quickAccessAvailable = true
    private var savedKey = ""
    private var work: Task<Void, Never>?
    private var workToken = UUID()
    private var captionTask: Task<Void, Never>?
    private var captionQueue: [UUID] = []
    private var meetingSession = UUID()
    private var panel: NSPanel?

    init(complete: (@MainActor (String, String) async throws -> String)? = nil, registerShortcuts: Bool = true,
         conversationAudio: (any ConversationAudio)? = nil) {
        conversation = MeetingConversation(audio: conversationAudio)
        completionOverride = complete
        if let data = UserDefaults.standard.data(forKey: "ai.configuration"), let value = try? JSONDecoder().decode(AIConfiguration.self, from: data) {
            configuration = value; savedConfiguration = value
        }
        if !voiceIdentifier.isEmpty, let upgraded = try? EnglishMaleVoice.natural(identifier: voiceIdentifier), upgraded.identifier != voiceIdentifier {
            voiceIdentifier = upgraded.identifier
        }
        // macOS may require user interaction after a local re-sign. Load only
        // through the explicit connection action so startup cannot be blocked.
        requiresKeyAuthorization = !savedConfiguration.model.isEmpty
        conversation.complete = { [weak self] prompt, text in
            guard let self else { throw CancellationError() }
            return try await self.complete(system: prompt, text: text)
        }
        conversation.validateConnection = { [weak self] in
            guard let self else { throw CancellationError() }
            if self.completionOverride == nil { _ = try self.client() }
            guard !self.microphone.isRunning, !self.microphone.isTranscribing,
                  !self.meeting.isRunning, !self.output.isSpeaking, !self.speechPending else {
                throw AppFailure("请先停止单句翻译的录音或播放，再开始会议对话。")
            }
        }
        if registerShortcuts { refreshDevices() }
        microphone.onError = { [weak self] message in
            guard let self else { return }
            self.error = message
            if !self.microphone.partial.isEmpty { self.chineseSpeech = self.microphone.partial }
        }
        microphone.onUtterance = { [weak self] value in
            self?.chineseSpeech = value
            self?.translateSpeech()
        }
        meeting.onError = { [weak self] message in
            self?.error = message
            self?.cancelCaptions()
        }
        output.onError = { [weak self] in self?.error = $0 }
        meeting.onUtterance = { [weak self] in self?.enqueue($0) }
        if registerShortcuts {
        clipboardShortcuts = ClipboardShortcuts(paste: { [weak self] in self?.pasteFromClipboard() }, submit: { [weak self] event in
            guard let self, workspace == .translate, translationInputFocused,
                  let window = event.window, window === NSApplication.shared.keyWindow,
                  !(window is NSPanel), NSApplication.shared.modalWindow == nil,
                  window.attachedSheet == nil, let editor = window.firstResponder as? NSTextView, editor.isEditable,
                  ClipboardShortcuts.isSubmit(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                             markedText: editor.hasMarkedText(), repeating: event.isARepeat) else { return false }
            if !busy && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translate() }
            return true
        })
        quickAccess = QuickAccess { [weak self] action in
            guard let self else { return }
            workspace = .translate
            // Opening our running bundle also reopens its SwiftUI window if closed.
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: options)
            if action == 2 { importTranslation(paste: true) }
        }
        }
        quickAccessAvailable = quickAccess?.available ?? false
    }

    func client() throws -> AIClient {
        guard !requiresKeyAuthorization else { throw KeychainAuthorizationRequired() }
        _ = try savedConfiguration.endpoint()
        guard !savedConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("先在“AI 与设备”中填写服务地址、模型与密钥，并保存设置。") }
        return AIClient(configuration: savedConfiguration, apiKey: savedKey)
    }

    func save() {
        do {
            _ = try configuration.endpoint()
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("请填写模型名称。") }
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requiresKeyAuthorization || !key.isEmpty else { throw KeychainAuthorizationRequired() }
            guard !key.contains("\n"), !key.contains("\r") else { throw AppFailure("密钥不能包含换行符。") }
            try Keychain.write(key)
            UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: "ai.configuration")
            savedConfiguration = configuration; savedKey = key; apiKey = key
            requiresKeyAuthorization = false
            notice = "设置已保存，密钥保存在 Mac 钥匙串中。"; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func authorizeSavedKey() {
        guard !authorizingKey else { return }
        authorizingKey = true
        Task {
            defer { authorizingKey = false }
            do {
                let key = try await Task.detached(priority: .userInitiated) { try Keychain.read() }.value
                apiKey = key; savedKey = key; requiresKeyAuthorization = false
                error = nil; notice = "AI 密钥已连接。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importLocalDeepSeek() {
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.credentials.yaml")
            let text = try String(contentsOf: url, encoding: .utf8)
            let expression = try NSRegularExpression(pattern: #"(?m)^\s*DEEPSEEK_API_KEY:\s*["']?([A-Za-z0-9_-]+)["']?\s*(?:#.*)?$"#)
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), !text[range].isEmpty else {
                throw AppFailure("本机 DeepSeek 配置中没有可读取的 API 密钥，请手动填写。")
            }
            configuration.baseURL = "https://api.deepseek.com"
            configuration.model = "deepseek-flash"
            apiKey = String(text[range])
            save()
        } catch {
            self.error = "无法导入本机 DeepSeek 配置，请在下面手动填写服务信息。"
        }
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        cancelWork()
        error = nil; notice = nil; busy = true
        let token = UUID(); workToken = token
        work = Task {
            defer { if workToken == token { busy = false; work = nil } }
            do { try await operation() }
            catch is CancellationError { }
            catch let failure as URLError where failure.code == .cancelled { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancelWork() {
        workToken = UUID(); work?.cancel(); work = nil; busy = false
        speechRequestID = nil; speechPending = false
    }
    private func complete(system: String, text: String) async throws -> String {
        if let completionOverride { return try await completionOverride(system, text) }
        return try await client().complete(system: system, text: text)
    }

    func translate() {
        let input = source
        let direction = detectedDirection
        let mode = translationMode
        run { [self] in
            let answer = try await client().complete(system: direction.prompt, text: input)
            try Task.checkCancellation()
            guard source == input, translationMode == mode else { return }
            translation = answer; resultDirection = direction
            translationHistory.append(source: input, result: answer, direction: direction)
        }
    }
    func swapTranslation() {
        guard !translation.isEmpty, !busy else { return }
        let original = source, translated = translation
        let reverse: TranslationDirection = (resultDirection ?? detectedDirection) == .toEnglish ? .toChinese : .toEnglish
        translationMode = reverse == .toChinese ? .chinese : .english
        source = translated
        translation = original
        resultDirection = reverse
    }
    func restoreTranslation(_ record: TranslationRecord) {
        cancelWork()
        translationMode = record.direction == .undetermined ? .automatic : (record.direction == .toEnglish ? .english : .chinese)
        source = record.source; translation = record.result; resultDirection = record.direction
    }
    func pasteFromClipboard() {
        let images = ClipboardImages.providers(from: .general)
        if !images.isEmpty, workspace == .translate || workspace == .email {
            guard !busy else { notice = "正在处理内容，请稍后粘贴。"; return }
            _ = importDroppedImages(images, to: workspace == .email ? .email : .translation)
            return
        }
        // Preserve native text insertion, selection replacement and Undo in all
        // editable fields, including the reply intent and connection settings.
        if let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.paste(nil)
            return
        }
        // The translated reference is read-only: pasting there still adds a
        // new incoming message, then the UI switches back to its source tab.
        switch workspace {
        case .email: if !busy { importImage(paste: true) }
        case .translate: if !busy { importTranslation(paste: true) }
        default: NSApplication.shared.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }
    enum ImageDestination { case translation, email }
    @discardableResult
    func importDroppedImages(_ providers: [NSItemProvider], to destination: ImageDestination) -> Bool {
        guard !busy else { return false }
        guard providers.contains(where: ImageImport.supports) else { return false }
        let original = source
        run { [self] in
            let text = try await ContentImport.load(providers)
            try Task.checkCancellation()
            switch destination {
            case .translation:
                guard source == original else { return }
                translationMode = .automatic
                source = text
            case .email:
                emailContext += (emailContext.isEmpty ? "" : "\n\n") + text
            }
            notice = "内容已导入，确认后可翻译，语言会自动识别。"
        }
        return true
    }
    func importTranslation(paste: Bool) {
        guard !busy else { return }
        error = nil; notice = nil
        var data: Data?
        if paste {
            let providers = ClipboardImages.providers(from: .general)
            if !providers.isEmpty { _ = importDroppedImages(providers, to: .translation); return }
            let board = NSPasteboard.general
            data = board.data(forType: .png) ?? board.data(forType: .tiff)
            if data == nil, let text = board.string(forType: .string), !text.isEmpty {
                translationMode = .automatic
                source = text
                notice = "已粘贴，确认内容后点击翻译。"
                return
            }
        } else {
            let picker = NSOpenPanel()
            picker.allowedContentTypes = ContentImport.allowedTypes
            picker.canChooseDirectories = false
            picker.allowsMultipleSelection = true
            guard picker.runModal() == .OK else { return }
            let providers = picker.urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
            _ = importDroppedImages(providers, to: .translation)
            return
        }
        guard let data else { error = "剪贴板中没有文字或图片。请先复制截图，或按 ⌃⇧⌘4 截图到剪贴板，也可直接拖入图片文件。"; return }
        guard data.count <= 25_000_000 else { error = "图片过大，请使用小于 25 MB 的截图。"; return }
        let original = source
        run { [self] in
            let text = try await OCR.recognize(data)
            try Task.checkCancellation()
            guard source == original else { return }
            translationMode = .automatic
            source = text
            notice = "截图已取字，可修改后翻译。"
        }
    }
    func generateEmail() {
        let snapshot = emailDraft.inputs
        let direction = emailDraft.replyDirection
        run { [self] in
            guard emailDraft.canGenerate else { throw AppFailure("请先添加来信，再写下你想回复的意思。") }
            let api = try client()
            let answer = try await api.complete(system: Prompt.emailSystem(direction: direction), text: Prompt.email(context: snapshot.context, intent: snapshot.intent, tone: snapshot.tone))
            try Task.checkCancellation()
            guard emailDraft.applyReply(answer, for: snapshot) else { return }
            let meaning = try await api.complete(system: TranslationDirection.detect(answer).prompt, text: answer)
            try Task.checkCancellation()
            emailDraft.applyReplyTranslation(meaning, reply: answer, inputs: snapshot)
        }
    }
    func translateEmailContext() {
        let input = emailContext
        run { [self] in
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("请先添加来信。") }
            if TranslationDirection.detect(input) == .undetermined {
                emailDraft.applyContextTranslation(input, for: input)
                return
            }
            let answer = try await client().complete(system: TranslationDirection.detect(input).prompt, text: input)
            try Task.checkCancellation(); emailDraft.applyContextTranslation(answer, for: input)
        }
    }
    func translateSpeech() {
        let input = chineseSpeech
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请先录音或输入发言内容。"; return
        }
        let requestID = UUID()
        let sendAutomatically = autoSend
        let deviceUID = savedConfiguration.outputDeviceUID, voice = voiceIdentifier
        run { [self] in
            defer {
                if speechRequestID == requestID { speechPending = false; speechRequestID = nil }
            }
            let answer = try await complete(system: Prompt.spokenEnglish, text: input)
            try Task.checkCancellation()
            guard speechRequestID == requestID, chineseSpeech == input else { return }
            englishSpeech = answer
            if sendAutomatically && autoSend {
                guard savedConfiguration.outputDeviceUID == deviceUID, voiceIdentifier == voice else {
                    notice = "声音或发送通道已改变，请核对后手动发送。"; return
                }
                try output.speak(answer, deviceUID: deviceUID, toMeeting: true, voiceIdentifier: voice)
            }
        }
        speechRequestID = requestID; speechPending = true
    }
    func stopSpeech() {
        speechStopID = UUID()
        if microphone.isTranscribing && !microphone.isRunning {
            Task { await microphone.stop() }
        }
        // Cancel the pending translation as well as current audio, so a late
        // completion cannot start playback after the user has pressed Stop.
        if speechPending { cancelWork() }
        output.stop()
    }
    func testConnection() {
        if requiresKeyAuthorization && apiKey.isEmpty { error = KeychainAuthorizationRequired().localizedDescription; return }
        let config = configuration, key = apiKey
        run { [self] in
            _ = try await AIClient(configuration: config, apiKey: key).complete(system: "Reply only OK.", text: "Connection test")
            try Task.checkCancellation(); notice = "连接成功，模型已返回内容。请保存设置后使用。"
        }
    }
    func refreshDevices() { devices = AudioDevices.outputs().filter(\.isMeetingLoopback) }
    func setOutputDevice(_ uid: String) {
        guard conversation.canConfigure else { error = "请先暂停会议翻译再修改音频通道。"; return }
        if uid != savedConfiguration.outputDeviceUID { conversation.routeConfirmed = false }
        var updated = savedConfiguration
        updated.outputDeviceUID = uid
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: "ai.configuration")
            savedConfiguration = updated
            configuration.outputDeviceUID = uid
            notice = "发送通道已保存。"
        } catch { self.error = error.localizedDescription }
    }
    func play(meeting: Bool) {
        do {
            guard !speechPending, !microphone.isRunning, !microphone.isTranscribing, !transitioningAudio else {
                throw AppFailure("请先结束录音或等待翻译完成。")
            }
            if meeting && englishSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppFailure("请先翻译当前发言，再发送英文。")
            }
            let deviceUID: String
            if meeting { deviceUID = savedConfiguration.outputDeviceUID }
            else {
                guard let uid = AudioDevices.defaultPhysicalOutputUID() else { throw AppFailure("请先将 Mac 默认输出设为耳机或扬声器，再进行本机试听。") }
                deviceUID = uid
            }
            let text = !meeting && englishSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Hello, thank you for your message. I'll get back to you shortly." : englishSpeech
            try output.speak(text, deviceUID: deviceUID, toMeeting: meeting, voiceIdentifier: voiceIdentifier)
        }
        catch { self.error = error.localizedDescription }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "已复制。" }
    func importImage(paste: Bool) {
        error = nil; notice = nil
        var data: Data?
        if paste {
            let providers = ClipboardImages.providers(from: .general)
            if !providers.isEmpty { _ = importDroppedImages(providers, to: .email); return }
            let board = NSPasteboard.general
            data = board.data(forType: .png) ?? board.data(forType: .tiff)
            if data == nil, let text = board.string(forType: .string) {
                emailContext += (emailContext.isEmpty ? "" : "\n\n") + text
                return
            }
        } else {
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
            picker.canChooseDirectories = false
            if picker.runModal() == .OK, let url = picker.url {
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 25_000_000 else { throw AppFailure("图片过大，请选择小于 25 MB 的图片。") }
                    data = try Data(contentsOf: url)
                } catch { self.error = error.localizedDescription; return }
            } else { return }
        }
        guard let data else { error = "剪贴板中没有文字或图片。请先复制截图，或按 ⌃⇧⌘4 截图到剪贴板，也可直接拖入图片文件。"; return }
        run { [self] in
            let text = try await OCR.recognize(data)
            try Task.checkCancellation()
            emailContext += (emailContext.isEmpty ? "" : "\n\n") + text
            notice = "截图文字已追加到上下文，可先修正再生成回复。"
        }
    }

    func toggleMicrophone() {
        guard !conversation.isActive else { error = "请先暂停会议对话。"; return }
        guard !transitioningAudio else { return }
        transitioningAudio = true
        Task {
            defer { transitioningAudio = false }
            do {
                if microphone.isRunning {
                    let stopID = speechStopID
                    let transcript = await microphone.finishMicrophone()
                    guard stopID == speechStopID else { return }
                    chineseSpeech = transcript
                    if !chineseSpeech.isEmpty { translateSpeech() }
                } else {
                    stopSpeech()
                    try microphoneCheck()
                    try await microphone.startMicrophone()
                    englishSpeech = ""
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func microphoneCheck() throws { _ = try client() }

    func toggleMeeting() {
        guard !transitioningAudio else { return }
        transitioningAudio = true
        Task {
            defer { transitioningAudio = false }
            if meeting.isRunning {
                await meeting.finishMeeting()
            } else {
                do {
                    _ = try client()
                    try await meeting.startMeeting(conversation.platform)
                    resumeCaptionTranslations()
                    notice = "正在监听 \(conversation.platform.rawValue)。请确认会议扬声器仍是耳机。"
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func enqueue(_ text: String) {
        guard captionQueue.count < 20 else {
            error = "翻译速度暂时跟不上语音，已暂停监听。请等待当前字幕完成后重试。"
            Task { await meeting.stop() }
            return
        }
        let item = Caption(english: text)
        captions.append(item); captionQueue.append(item.id)
        if captions.count > 300 { captions.removeFirst(captions.count - 300) }
        resumeCaptionTranslations()
    }
    func resumeCaptionTranslations() {
        // Pause/resume retains the same translation session and its worker.
        // Only explicit cancellation/clearing creates a new session.
        guard captionTask == nil, !captionQueue.isEmpty else { return }
        let session = meetingSession
        meetingBusy = true
        captionTask = Task {
            defer { if meetingSession == session { captionTask = nil; meetingBusy = false } }
            while !captionQueue.isEmpty, !Task.isCancelled, meetingSession == session {
                let id = captionQueue.removeFirst()
                guard let caption = captions.first(where: { $0.id == id }) else { continue }
                do {
                    let answer = try await complete(system: TranslationDirection.detect(caption.english).prompt, text: caption.english)
                    try Task.checkCancellation()
                    guard meetingSession == session else { return }
                    if let index = captions.firstIndex(where: { $0.id == id }) { captions[index].chinese = answer }
                } catch {
                    guard !Task.isCancelled, meetingSession == session else { return }
                    if let index = captions.firstIndex(where: { $0.id == id }) {
                        captions[index].chinese = "翻译失败，可复制原文重试。"
                        captions[index].failed = true
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func cancelCaptions() {
        meetingSession = UUID(); captionTask?.cancel(); captionTask = nil; captionQueue = []; meetingBusy = false
        for index in captions.indices where captions[index].chinese == "等待翻译…" {
            captions[index].chinese = "翻译已取消"; captions[index].failed = true
        }
    }
    func clearCaptions() { meeting.discardPendingRecognition(); cancelCaptions(); captions = [] }
    func exportCaptions() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "会议字幕.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = captions.map { "[\($0.date.formatted(date: .omitted, time: .standard))]\n\($0.english)\n\($0.chinese)" }.joined(separator: "\n\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "字幕已导出。"
        } catch { self.error = error.localizedDescription }
    }
    func toggleFloating() {
        if let panel { panel.close(); self.panel = nil; showFloating = false; return }
        let panel = CaptionPanel(contentRect: NSRect(x: 160, y: 140, width: 740, height: 220), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onClose = { [weak self] in self?.panel = nil; self?.showFloating = false }
        panel.title = "DawnTranslate · 会议字幕"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatingCaptions(model: self, speech: meeting))
        panel.orderFront(nil); self.panel = panel; showFloating = true
    }
    func shutdown() {
        conversation.stop()
        cancelWork(); cancelCaptions(); output.stop()
        microphone.cancelRecognition(); meeting.cancelRecognition()
        LocalSpeechEngine.shutdown()
        Task { await microphone.stop(); await meeting.stop() }
    }
}
