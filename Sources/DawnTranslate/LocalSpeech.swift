import Foundation

struct SpeechRecognition: Equatable {
    let text: String
    let language: String
    var languageLabel: String { language == "zh" ? "中文" : (language == "en" ? "English" : language) }
}

// 20 ms windows, short pre-roll, silence-based boundaries and a hard bound.
// Silence never produces an inference request, reducing Whisper hallucinations.
struct SpeechSegmenter {
    static let sampleRate = 16_000
    private var remainder: [Float] = []
    private var preRoll: [Float] = []
    private var current: [Float] = []
    private var voiced = 0
    private var silent = 0
    private(set) var capturedSamples = 0
    mutating func append(_ samples: [Float]) -> [[Float]] {
        capturedSamples += samples.count
        remainder += samples
        var output: [[Float]] = []
        var offset = 0
        while offset + 320 <= remainder.count {
            let window = Array(remainder[offset..<(offset + 320)])
            offset += 320
            let energy = window.reduce(Float(0)) { $0 + $1 * $1 } / 320
            let speech = energy > 0.000049 // RMS > 0.007, approximately -43 dBFS.
            if current.isEmpty {
                preRoll += window
                if preRoll.count > 4800 { preRoll.removeFirst(preRoll.count - 4800) }
                guard speech else { continue }
                current = preRoll; preRoll = []; voiced = 320; silent = 0
            } else {
                current += window
                if speech { voiced += 320; silent = 0 } else { silent += 320 }
            }
            if silent >= 14_400 || current.count >= 160_000 {
                if let segment = finishSegment() { output.append(segment) }
            }
        }
        if offset > 0 { remainder.removeFirst(offset) }
        return output
    }
    mutating func flush() -> [Float]? {
        if !current.isEmpty { current += remainder }
        remainder = []
        return finishSegment()
    }
    private mutating func finishSegment() -> [Float]? {
        defer { current = []; voiced = 0; silent = 0; preRoll = [] }
        guard voiced >= 3200 else { return nil }
        // Retain only 200 ms of trailing silence.
        let trim = max(0, silent - 3200)
        return Array(current.prefix(current.count - min(trim, current.count)))
    }
}

enum SpeechPCM {
    static func wave(_ samples: [Float]) -> Data {
        let padded = samples + Array(repeating: Float(0), count: max(0, 16_000 - samples.count))
        var data = Data()
        func string(_ value: String) { data.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        string("RIFF"); number(UInt32(36 + padded.count * 2)); string("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000))
        number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16))
        string("data"); number(UInt32(padded.count * 2))
        for sample in padded { number(Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * 32767)) }
        return data
    }
}

private final class SpeechProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

private final class SpeechTemporaryFiles: @unchecked Sendable {
    static let shared = SpeechTemporaryFiles()
    private let lock = NSLock()
    private var folders: Set<URL> = []
    private var shuttingDown = false
    func create() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DawnSpeech-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folders.insert(folder); return folder
    }
    func remove(_ folder: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder); folders.remove(folder)
    }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        shuttingDown = true
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }
}

struct LocalSpeechEngine {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? Bundle.main.resourceURL!.appendingPathComponent("Speech")
    }
    var executable: URL { directory.appendingPathComponent("whisper-cli") }
    var model: URL { directory.appendingPathComponent("ggml-small-q5_1.bin") }
    func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 190_085_487 else {
            throw AppFailure("本机中英文语音模型不完整，请重新构建或安装 DawnTranslate。")
        }
    }
    func recognize(_ samples: [Float]) async throws -> SpeechRecognition {
        try validate()
        try Task.checkCancellation()
        let folder = try SpeechTemporaryFiles.shared.create()
        defer { SpeechTemporaryFiles.shared.remove(folder) }
        let input = folder.appendingPathComponent("input.wav"), output = folder.appendingPathComponent("result")
        try SpeechPCM.wave(samples).write(to: input, options: .atomic)
        let process = Process(), controller = SpeechProcess()
        process.executableURL = executable
        process.arguments = ["-m", model.path, "-f", input.path, "-l", "auto", "-oj", "-of", output.path,
                             "-t", "4", "-np", "-sns", "-bs", "1", "-bo", "1", "-nf"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            controller.cancel()
        }
        defer { timeout.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try controller.start(process) }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: { controller.cancel() }
        try Task.checkCancellation()
        guard status == 0 else { throw AppFailure("本机语音识别未完成，请重试；较长发言可以分段录制。") }
        let data = try Data(contentsOf: output.appendingPathExtension("json"))
        return try Self.parse(data)
    }
    static func shutdown() { SpeechTemporaryFiles.shared.shutdown() }
    static func parse(_ data: Data) throws -> SpeechRecognition {
        struct Result: Decodable {
            struct Language: Decodable { let language: String }
            struct Segment: Decodable { let text: String }
            let result: Language
            let transcription: [Segment]
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let text = result.transcription.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 60_000 else { throw AppFailure("语音识别内容过长，请分段录制。") }
        guard text.isEmpty || ["zh", "en"].contains(result.result.language) else {
            throw AppFailure("这段声音未能可靠识别为中文或英文，请说完整一句后重试。")
        }
        return SpeechRecognition(text: text, language: result.result.language)
    }
}
