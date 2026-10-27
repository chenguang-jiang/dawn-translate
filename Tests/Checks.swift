import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class SpeechProbe {
    let synthesizer = AVSpeechSynthesizer()
    var continuation: CheckedContinuation<Bool, Never>?
    func run() async -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dawn-test-\(UUID()).caf")
        let writer = SpeechFileWriter(url: url)
        defer { writer.cancel() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let utterance = AVSpeechUtterance(string: "Hello. This is a translation test.")
            utterance.voice = try? EnglishMaleVoice.resolve()
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, let result = writer.consume(pcm) else { return }
                Task { @MainActor in
                    let okay: Bool
                    if case .success = result { okay = (try? AVAudioFile(forReading: url).length) ?? 0 > 0 }
                    else { okay = false }
                    self.finish(okay)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if self.continuation != nil { self.synthesizer.stopSpeaking(at: .immediate); self.finish(false) }
            }
        }
    }
    private func finish(_ okay: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: okay)
    }
}

final class MockProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct Checks {
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw AppFailure("FAIL: \(name)") }
        count += 1; print("PASS \(name)")
    }
    static func rejects(_ config: AIConfiguration) -> Bool { (try? config.endpoint()) == nil }
    static func main() async throws {
        try check(TranslationMode.chinese.direction(for: "你好") == .toChinese, "manual Chinese target overrides detection")
        try check(TranslationMode.english.direction(for: "Hello") == .toEnglish, "manual English target overrides detection")
        try check(TranslationMode.automatic.direction(for: "你好，明天见。") == .toEnglish, "automatic mode detects Chinese")
        var history = TranslationHistory()
        history.append(source: "Hello", result: "你好", direction: .toChinese)
        history.append(source: "Hello", result: "你好", direction: .toChinese)
        try check(history.records.count == 1, "history deduplicates repeated result")
        history.append(source: " ", result: "text", direction: .toEnglish)
        try check(history.records.count == 1, "history excludes blank inputs")
        for n in 0..<35 { history.append(source: "Source \(n)", result: "Result \(n)", direction: .toChinese) }
        try check(history.records.count == 30 && history.records.first?.source == "Source 34", "history bounds memory and lists newest first")
        history.clear()
        try check(history.records.isEmpty, "clear history removes session records")

        try check(ClipboardShortcuts.isSubmit(keyCode: 36, modifiers: [], markedText: false, repeating: false), "Return submits translation")
        try check(ClipboardShortcuts.isSubmit(keyCode: 76, modifiers: .capsLock, markedText: false, repeating: false), "keypad Enter submits with Caps Lock")
        try check(!ClipboardShortcuts.isSubmit(keyCode: 36, modifiers: .shift, markedText: false, repeating: false), "Shift-Return preserves newline")
        try check(!ClipboardShortcuts.isSubmit(keyCode: 36, modifiers: [], markedText: true, repeating: false), "IME candidate confirmation does not submit")
        try check(!ClipboardShortcuts.isSubmit(keyCode: 36, modifiers: [], markedText: false, repeating: true), "held Return does not submit repeatedly")
        try check(!ClipboardShortcuts.isSubmit(keyCode: 36, modifiers: .option, markedText: false, repeating: false), "modified Return preserves native editing")
        try check(ClipboardShortcuts.isPaste(keyCode: 9, modifiers: .command), "Command-V enters unified paste handling")
        try check(ClipboardShortcuts.isPaste(keyCode: 9, modifiers: [.control, .capsLock]), "Control-V works with Caps Lock")
        try check(!ClipboardShortcuts.isPaste(keyCode: 9, modifiers: [.command, .shift]) && !ClipboardShortcuts.isPaste(keyCode: 8, modifiers: .command), "paste shortcuts preserve other key combinations")
        try check(Prompt.emailSystem.contains("不是逐字翻译") && Prompt.emailSystem.contains("段落之间空一行"), "email prompt asks for a sendable complete body rather than a literal translation")
        try check(Prompt.emailSystem(direction: .toEnglish).contains("署名“姜晨光”") && Prompt.emailSystem(direction: .toChinese).contains("署名“姜晨光”"), "Chinese and English email replies use the authorized sender name")
        try check(Prompt.emailSystem.contains("不虚构") && Prompt.emailSystem.contains("不要擅自承诺"), "email drafting prohibits invented identity and commitments")

        var languageMail = EmailDraft()
        languageMail.updateContext("你好，请确认明天的会议时间。")
        languageMail.updateIntent("That works for me.")
        try check(languageMail.contextDirection == .toEnglish && languageMail.replyDirection == .toChinese, "Chinese email is read in English and answered in Chinese")
        languageMail.updateContext("Please confirm tomorrow's meeting time.")
        try check(languageMail.contextDirection == .toChinese && languageMail.replyDirection == .toEnglish, "English email is read in Chinese and answered in English")
        try check(Prompt.emailSystem(direction: .toChinese).contains("只输出中文回复。"), "Chinese reply prompt sets explicit target")
        try check(Prompt.emailSystem(direction: .toEnglish).contains("只输出英文回复。"), "English reply prompt sets explicit target")

        var mail = EmailDraft()
        try check(!mail.canGenerate && !mail.canCopyReply, "empty email cannot generate or copy")
        mail.updateContext("Please confirm the meeting time.")
        mail.updateIntent("知道了，谢谢")
        try check(mail.canGenerate, "context and intent enable generation")
        let original = mail.inputs
        mail.applyContextTranslation("请确认会议时间。", for: original.context)
        mail.applyReply("Noted, thank you.", for: original)
        mail.applyReplyTranslation("知道了，谢谢。", reply: mail.reply, inputs: original)
        try check(mail.canCopyReply && !mail.replyIsStale, "current reply is copyable")
        mail.updateIntent("请改到周五")
        try check(mail.reply == "Noted, thank you." && mail.replyIsStale && !mail.canCopyReply, "changing intent preserves draft but blocks copying stale reply")
        try check(!mail.applyReply("Late response", for: original), "late generation cannot overwrite updated intent")
        mail.editReply("Could we move it to Friday?")
        try check(mail.canCopyReply && mail.replyTranslation.isEmpty, "manual English edit restores copying and removes stale meaning")
        mail.updateContext("A different message")
        try check(mail.contextTranslation.isEmpty && mail.replyIsStale, "changing source removes old translation and marks reply stale")
        try check(!mail.applyContextTranslation("Wrong old translation", for: original.context), "late source translation is ignored")
        let updated = mail.inputs
        mail.applyReply("Friday works for me.", for: updated)
        mail.updateTone("正式礼貌")
        try check(mail.replyIsStale, "changing tone marks generated reply stale")
        try check(!mail.applyReplyTranslation("Old meaning", reply: "Friday works for me.", inputs: updated), "late meaning cannot attach to changed tone")
        let maleVoice = try EnglishMaleVoice.resolve()
        let naturalVoice = try EnglishMaleVoice.natural(identifier: maleVoice.identifier)
        try check(naturalVoice.gender == .male && naturalVoice.language == maleVoice.language && naturalVoice.quality.rawValue >= maleVoice.quality.rawValue, "natural voice keeps the selected male language and never downgrades quality")
        try check(!EnglishMaleVoice.qualityLabel(naturalVoice).isEmpty, "voice quality is explicitly labeled")
        if let compact = EnglishMaleVoice.available.first(where: { $0.identifier.contains("compact") }),
           let upgraded = try? EnglishMaleVoice.natural(identifier: compact.identifier) {
            let best = EnglishMaleVoice.available.filter { $0.language == compact.language && $0.name.components(separatedBy: " (").first == compact.name.components(separatedBy: " (").first }.map { $0.quality.rawValue }.max()!
            try check(upgraded.quality.rawValue == best, "a saved compact identifier upgrades to the downloaded Enhanced variant even when its display name differs")
        }
        try check(maleVoice.gender == .male && maleVoice.language.hasPrefix("en-"), "default voice is an installed English male")
        try check(try EnglishMaleVoice.resolve(identifier: maleVoice.identifier).identifier == maleVoice.identifier, "explicit male voice is preserved for preview and sending")
        do { _ = try EnglishMaleVoice.resolve(identifier: "unavailable-voice"); throw AppFailure("Expected voice failure") }
        catch let error as AppFailure { try check(error.message.contains("不可用"), "missing male voice does not silently fall back to a female voice") }
        try check(TranslationDirection.detect("明天上午十点开会，请确认时间。") == .toEnglish, "detect Chinese to English")
        try check(TranslationDirection.detect("Please confirm the meeting time.") == .toChinese, "detect English to Chinese")
        try check(TranslationDirection.detect("請確認明天的會議時間。") == .toEnglish, "detect traditional Chinese")
        try check(TranslationDirection.detect("请帮我确认 Teams 会议时间和 API 配置。") == .toEnglish, "detect Chinese with English terms")
        try check(TranslationDirection.detect("Please confirm the API settings for Teams.") == .toChinese, "detect English with technical terms")
        try check(TranslationDirection.detect(" \n12345 !") == .undetermined, "neutral input has no invented source language")
        try check(TranslationDirection.toEnglish.prompt.contains("英文") && TranslationDirection.toChinese.prompt.contains("简体中文"), "direction selects target language")
        var config = AIConfiguration()
        try check(try config.endpoint().absoluteString == "https://api.openai.com/v1/chat/completions", "base URL joins endpoint")
        config.baseURL = "https://example.com/v1/chat/completions/"
        try check(try config.endpoint().path == "/v1/chat/completions", "full endpoint not duplicated")
        for value in ["http://remote.example/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#key", "file:///tmp/data", "not a URL"] {
            config.baseURL = value
            try check(rejects(config), "reject unsafe endpoint \(value)")
        }
        config.baseURL = "http://127.0.0.1:18943/v1"
        try check(try config.endpoint().host == "127.0.0.1", "allow local service")
        config.model = "test-model"
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let api = AIClient(configuration: config, apiKey: "test-key-never-networked", session: session)
        MockProtocol.body = Data(#"{"choices":[{"message":{"content":"  你好  "}}]}"#.utf8)
        let answer = try await api.complete(system: Prompt.translation, text: "Hello")
        try check(answer == "你好", "parse translated result")
        let request = MockProtocol.captured!
        try check(request.httpMethod == "POST", "request uses POST")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-never-networked", "bearer authentication")
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let amount = stream.read(&buffer, maxLength: buffer.count)
                if amount <= 0 { break }; bytes.append(buffer, count: amount)
            }
            data = bytes
        } else { throw AppFailure("Missing request body") }
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        try check(body["model"] as? String == "test-model", "preserve model identifier")
        try check(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["content"] == "Hello", "message roles and input")
        for status in [401, 403, 429, 500, 302] {
            MockProtocol.status = status
            do { _ = try await api.complete(system: "test", text: "Hello"); throw AppFailure("Expected HTTP rejection") }
            catch let error as AppFailure { try check(!error.message.contains("test-key") && !error.message.contains("Expected"), "HTTP \(status) handled without exposing credentials") }
        }
        MockProtocol.status = 200; MockProtocol.body = Data(#"{"choices":[]}"#.utf8)
        do { _ = try await api.complete(system: "test", text: "Hello"); throw AppFailure("Expected empty rejection") }
        catch let error as AppFailure { try check(error.message.contains("空内容"), "empty result reported") }
        MockProtocol.body = Data("<html>not an API</html>".utf8)
        do { _ = try await api.complete(system: "test", text: "Hello"); throw AppFailure("Expected format rejection") }
        catch let error as AppFailure { try check(error.message.contains("不兼容"), "malformed response reported") }
        do { _ = try await api.complete(system: "test", text: " \n"); throw AppFailure("Expected input rejection") }
        catch let error as AppFailure { try check(error.message.contains("输入"), "blank input rejected") }
        do { _ = try await api.complete(system: "test", text: String(repeating: "x", count: 60_001)); throw AppFailure("Expected size rejection") }
        catch let error as AppFailure { try check(error.message.contains("过长"), "oversized input rejected") }
        let task = Task {
            try Task.checkCancellation()
            return try await api.complete(system: "test", text: "Hello")
        }
        task.cancel()
        do { _ = try await task.value; throw AppFailure("Expected cancellation") }
        catch is CancellationError { try check(true, "cancellation propagates") }

        let png = await MainActor.run { () -> Data in
            let image = NSImage(size: NSSize(width: 1100, height: 180))
            image.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 180).fill()
            ("Please confirm the meeting time." as NSString).draw(at: NSPoint(x: 35, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            return bitmap.representation(using: .png, properties: [:])!
        }
        let fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("dawn-drop-\(UUID()).png")
        try png.write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let fileProvider = NSItemProvider(item: fixtureURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let imageProvider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("Reply intent", forType: .string)
        try check(ClipboardImages.providers(from: clipboard).isEmpty, "plain clipboard text stays on the native text editing path")
        clipboard.clearContents(); clipboard.setData(png, forType: .png)
        let imagePaste = try await ImageImport.load(ClipboardImages.providers(from: clipboard))
        try check(imagePaste == [png], "screenshot clipboard data enters the same OCR import pipeline")
        let jpeg = NSBitmapImageRep(data: png)!.representation(using: .jpeg, properties: [:])!
        clipboard.clearContents(); clipboard.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        let jpegPaste = try await ImageImport.load(ClipboardImages.providers(from: clipboard))
        try check(jpegPaste.count == 1 && NSBitmapImageRep(data: jpegPaste[0]) != nil, "JPEG clipboard images produce a readable image")
        let jpegText = try await OCR.recognize(jpegPaste[0])
        try check(jpegText.contains("confirm the meeting"), "JPEG clipboard image reaches the real OCR pipeline")
        clipboard.clearContents(); clipboard.writeObjects([fixtureURL as NSURL])
        let filePaste = try await ImageImport.load(ClipboardImages.providers(from: clipboard))
        try check(filePaste == [png], "copied Finder images are accepted by keyboard paste")
        let loaded = try await ImageImport.load([fileProvider, imageProvider])
        try check(loaded.count == 2 && loaded.allSatisfy { $0 == png }, "drop loader accepts Finder URLs and raw screenshot data in order")
        let droppedText = try await OCR.recognize(loaded[0])
        try check(droppedText.contains("confirm the meeting"), "dropped file reaches the real OCR pipeline")
        do { _ = try await ImageImport.load(Array(repeating: imageProvider, count: 9)); throw AppFailure("Expected drop limit") }
        catch { try check(!error.localizedDescription.contains("Expected"), "drop loader rejects more than eight images") }
        let invalidURL = fixtureURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("Not an image".utf8).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        do { _ = try ImageImport.read(invalidURL); throw AppFailure("Expected non-image rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "drop loader rejects non-image files") }
        do { try ImageImport.validate(Data(count: 25_000_001)); throw AppFailure("Expected oversized image rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "drop loader rejects oversized clipboard images") }
        let recognized = try await OCR.recognize(png)
        try check(recognized.lowercased().contains("confirm the meeting"), "Vision OCR reads generated email image locally")
        for dark in [false, true] {
            let bilingual = await MainActor.run { () -> Data in
                let image = NSImage(size: NSSize(width: 1000, height: 240))
                image.lockFocus()
                (dark ? NSColor.black : NSColor.white).setFill()
                NSRect(x: 0, y: 0, width: 1000, height: 240).fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: dark ? NSColor.white : NSColor.black]
                ("文字翻译 邮件回复 会议字幕" as NSString).draw(at: NSPoint(x: 25, y: 150), withAttributes: attributes)
                ("输入中英文，或粘贴截图" as NSString).draw(at: NSPoint(x: 25, y: 100), withAttributes: attributes)
                ("Please confirm the meeting time." as NSString).draw(at: NSPoint(x: 25, y: 50), withAttributes: attributes)
                image.unlockFocus()
                return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            }
            let text = try await OCR.recognize(bilingual)
            try check(text.contains("文字翻译") && text.contains("邮件回复") && text.contains("输入中英文"), "mixed Chinese screenshot stays readable in \(dark ? "dark" : "light") mode")
            try check(text.contains("confirm the meeting"), "mixed screenshot preserves English in \(dark ? "dark" : "light") mode")
        }
        do { _ = try await OCR.recognize(Data("invalid image".utf8)); throw AppFailure("Expected OCR rejection") }
        catch { try check(!error.localizedDescription.contains("Expected OCR"), "invalid image handled") }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("dawn-writer-test-\(UUID()).caf")
        let writer = SpeechFileWriter(url: audioURL)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        audio.frameLength = 240
        memset(audio.floatChannelData![0], 0, 240 * MemoryLayout<Float>.size)
        _ = writer.consume(audio)
        let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        _ = writer.consume(end)
        let frames = try AVAudioFile(forReading: audioURL).length
        try check(frames == 240, "speech buffers create readable audio")
        writer.cancel()
        _ = writer.consume(audio)
        try check(!FileManager.default.fileExists(atPath: audioURL.path), "cancel removes audio and rejects late buffers")
        let speechOkay = await SpeechProbe().run()
        try check(speechOkay, "system English voice renders real audio without playing it")
        print("\n\(count) checks passed. No external AI service called.")
    }
}
