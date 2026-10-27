import Foundation
import AVFoundation
import ScreenCaptureKit

@main struct SpeechChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label); checks += 1; print("PASS \(label)")
    }
    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = LocalSpeechEngine(directory: root)
        try engine.validate()
        var segmenter = SpeechSegmenter()
        check(segmenter.append(Array(repeating: 0, count: 160_000)).isEmpty && segmenter.flush() == nil, "silence creates no recognition segment")
        let tone = (0..<32_000).map { Float(sin(Double($0) * 0.08) * 0.2) }
        let split = segmenter.append(tone + Array(repeating: 0, count: 16_000))
        check(split.count == 1 && segmenter.flush() == nil, "speech is emitted exactly once after a pause")
        var short = SpeechSegmenter()
        _ = short.append(Array(tone.prefix(640)))
        check(short.flush() == nil, "a brief click is not treated as speech")
        var bounded = SpeechSegmenter()
        let long = bounded.append(Array(repeating: Float(0.1), count: 480_000))
        check(long.count == 3 && long.allSatisfy { $0.count <= 160_000 }, "long continuous audio is bounded to ten-second segments")
        let wav = root.appendingPathComponent("wave-format-test.wav")
        try SpeechPCM.wave([.nan, 2, -2]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        let file = try AVAudioFile(forReading: wav)
        check(file.length == 16_000 && file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1, "WAV output is valid padded 16 kHz mono PCM")

        let sink = AudioSink()
        sink.start(segment: {}, failure: { fatalError("Unexpected conversion failure") })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        input.frameLength = 96_000
        for channel in 0..<2 { for i in 0..<96_000 { input.floatChannelData![channel][i] = Float(sin(Double(i) * 0.03) * 0.2) } }
        sink.append(input)
        let converted = sink.finish()
        check(converted.count == 1 && abs(converted[0].count - 32_000) < 500, "stereo 48 kHz microphone input resamples to 16 kHz mono: \(converted.map { $0.count })")
        check(sink.drain().isEmpty && sink.finish().isEmpty, "finishing capture drains the tail once without duplicated segments")
        sink.start(segment: {}, failure: {})
        sink.append(input); sink.cancel()
        check(sink.finish().isEmpty, "cancelling capture discards unfinished audio")

        sink.start(segment: {}, failure: { fatalError("Unexpected muted conversion failure") })
        sink.append(input)
        sink.setMuted(true)
        sink.append(input)
        check(sink.drain().isEmpty && sink.finish().isEmpty, "mute discards accumulated and newly arriving microphone audio")
        sink.start(segment: {}, failure: {})
        sink.setMuted(true); sink.append(input); sink.setMuted(false); sink.append(input)
        let unmuted = sink.finish()
        check(unmuted.count == 1 && abs(unmuted[0].count - 32_000) < 500, "unmute resumes with a fresh segment without replaying muted audio")

        sink.start(segment: {}, failure: { fatalError("Unexpected Teams conversion failure") })
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let created = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: format.formatDescription, sampleCount: Int(input.frameLength),
                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                          sampleBufferOut: &sample)
        precondition(created == noErr && sample != nil)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: input.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(sample!) == noErr)
        sink.append(sample!)
        let teams = sink.finish()
        check(teams.count == 1 && abs(teams[0].count - 32_000) < 500, "Teams CMSampleBuffer input reaches the same local speech PCM pipeline")

        let english = try samples(root.appendingPathComponent("english.wav"))
        let chinese = try samples(root.appendingPathComponent("chinese.wav"))
        var conversation = SpeechSegmenter()
        let silence = Array(repeating: Float(0), count: 24_000)
        let chunks = conversation.append(english + silence + chinese + silence + english + silence)
        check(chunks.count == 3, "English-Chinese-English recording is split into three speech turns")
        var recognized: [SpeechRecognition] = []
        for chunk in chunks { recognized.append(try await engine.recognize(chunk)) }
        check(recognized.map(\.language) == ["en", "zh", "en"], "real local ASR automatically switches English to Chinese and back")
        check(recognized[0].text.lowercased().contains("meeting") && recognized[2].text.lowercased().contains("meeting"), "English speech retains its original words")
        check(recognized[1].text.contains("会议") || recognized[1].text.contains("會議"), "Chinese speech retains Chinese text")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("DawnSpeech-") })
        let task = Task { try await engine.recognize(english) }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { check(true, "cancellation terminates real recognition without returning a stale transcript") }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("DawnSpeech-") })
        check(after.subtracting(before).isEmpty, "temporary audio and recognition JSON are removed after cancellation")
        print("\n\(checks) speech checks passed. Local synthetic audio only; no microphone, Teams, AI API or audio playback used.")
    }
}
