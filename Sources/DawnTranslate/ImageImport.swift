import AppKit
import UniformTypeIdentifiers

enum ImageImport {
    static let dropTypes: [UTType] = [.fileURL, .image]
    static let maximumBytes = 25_000_000
    static let maximumFiles = 8

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw AppFailure("请拖入本机图片文件。") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true,
              (values.contentType ?? UTType(filenameExtension: url.pathExtension))?.conforms(to: .image) == true else {
            throw AppFailure("请拖入 PNG、JPEG、HEIC 等图片，不支持文件夹或其他文件。")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw AppFailure("图片过大，请使用小于 25 MB 的截图。") }
        let data = try Data(contentsOf: url)
        try validate(data)
        return data
    }
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw AppFailure("图片为空或超过 25 MB，请换一张截图。") }
    }
    static func supports(_ provider: NSItemProvider) -> Bool {
        dropTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }
    static func load(_ providers: [NSItemProvider]) async throws -> [Data] {
        let images = providers.filter(supports)
        guard !images.isEmpty else { throw AppFailure("请拖入图片文件或截图。") }
        guard images.count <= maximumFiles else { throw AppFailure("一次最多拖入 8 张图片，请分批添加。") }
        var result: [Data] = []
        for provider in images {
            try Task.checkCancellation()
            let data: Data
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        do {
                            if let error { throw error }
                            let url: URL?
                            if let value = item as? URL { url = value }
                            else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                            else { url = nil }
                            guard let url else { throw AppFailure("无法读取拖入的图片，请尝试导入图片。") }
                            continuation.resume(returning: try read(url))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } else {
                let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
                data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: AppFailure("无法读取截图内容。")) }
                    }
                }
                try validate(data)
            }
            result.append(data)
        }
        return result
    }
}
