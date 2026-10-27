import AppKit
import Security
import Vision
import ImageIO
import CoreAudio
import LocalAuthentication

struct KeychainAuthorizationRequired: LocalizedError {
    var errorDescription: String? { "请在设置中授权读取已保存的 AI 密钥。" }
}

enum Keychain {
    private static let service = "local.dawn.translate.ai"
    static func read(allowInteraction: Bool = true) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw KeychainAuthorizationRequired() }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure("无法读取钥匙串中的密钥（\(status)）。") }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        if key.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw AppFailure("无法删除密钥（\(result)）。") }
            return
        }
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("无法保存 API 密钥到钥匙串（\(status)）。") }
    }
}

enum OCR {
    static func recognize(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // English-first without script detection makes Vision interpret Chinese
            // strokes as Latin symbols, even on otherwise clear screenshots.
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: data).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.isEmpty else { throw AppFailure("没有识别到文字，请尝试更清晰的截图。") }
            return text
        }.value
    }
}

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isVirtual: Bool
    // Teams' screen-sharing driver is virtual but is not a loopback microphone.
    var isMeetingLoopback: Bool {
        isVirtual && ["blackhole", "loopback", "soundflower"].contains { name.lowercased().contains($0) }
    }
}

enum AudioDevices {
    static func outputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }
    static func inputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeInput) }
    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var prop = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(device, &prop, 0, nil, &count, &value) == noErr else { return nil }
                return value?.takeRetainedValue() as String?
            }
            var transport = UInt32(0)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportProperty = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(device, &transportProperty, 0, nil, &transportSize, &transport)
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: uid, name: name, isVirtual: transport == kAudioDeviceTransportTypeVirtual)
        }.sorted { $0.name < $1.name }
    }

    static func defaultPhysicalOutputUID() -> String? { defaultPhysicalUID(input: false) }
    static func defaultPhysicalInputUID() -> String? { defaultPhysicalUID(input: true) }
    private static func defaultPhysicalUID(input: Bool) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        property.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() as String?,
              (input ? inputs() : outputs()).contains(where: { $0.id == value && !$0.isVirtual }) else { return nil }
        return value
    }
}
