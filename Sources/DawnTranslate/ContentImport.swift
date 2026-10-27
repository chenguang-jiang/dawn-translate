import AppKit
import PDFKit
import UniformTypeIdentifiers

enum ContentImport {
    static let allowedTypes: [UTType] = [.image, .pdf, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "doc")!]
    static let maximumCharacters = 60_000
    static func supportsFile(_ url: URL) -> Bool {
        ["pdf", "docx", "doc"].contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
    static func extract(_ url: URL) async throws -> String {
        guard url.isFileURL, supportsFile(url) else { throw AppFailure("请选择图片、PDF 或 Word（.docx、.doc）文件。") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AppFailure("不支持文件夹，请选择文件。") }
        guard (values.fileSize ?? 0) <= ImageImport.maximumBytes else { throw AppFailure("文件超过 25 MB，请拆分后导入。") }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= ImageImport.maximumBytes else { throw AppFailure("文件为空或超过 25 MB。") }
        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "pdf" {
            text = try await pdf(data)
        } else if ext == "docx" || ext == "doc" {
            text = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let type: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : .docFormat
                do {
                    return try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
                } catch { throw AppFailure("无法读取 Word 文档，文件可能损坏或加密。请另存为 .docx 或 PDF 后重试。") }
            }.value
        } else {
            text = try await OCR.recognize(data)
        }
        try Task.checkCancellation()
        return try validated(text)
    }
    static func validated(_ text: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AppFailure("文件中没有可提取的文字。Word 中只有图片时，请另存为 PDF 后导入。") }
        guard result.count <= maximumCharacters else { throw AppFailure("文档文字超过 60,000 字，请拆分后导入；未截断或替换当前原文。") }
        return result
    }
    private static func pdf(_ data: Data) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data) else { throw AppFailure("无法读取 PDF，文件可能已损坏。") }
            guard !document.isLocked else { throw AppFailure("PDF 已加密，请解锁后再导入。") }
            guard document.pageCount <= 100 else { throw AppFailure("PDF 超过 100 页，请拆分后导入。") }
            var pages: [String] = []
            var length = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw AppFailure("无法读取 PDF 第 \(index + 1) 页。") }
                var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    let image = page.thumbnail(of: NSSize(width: 2000, height: 2000), for: .mediaBox)
                    guard let bitmap = image.tiffRepresentation else { throw AppFailure("无法识别 PDF 第 \(index + 1) 页。") }
                    do { text = try await OCR.recognize(bitmap) }
                    catch let error as AppFailure where error.message.contains("没有识别到文字") { text = "" }
                }
                length += text.count + 2
                guard length <= maximumCharacters else { throw AppFailure("PDF 文字超过 60,000 字，请拆分后导入。") }
                if !text.isEmpty { pages.append(text) }
            }
            return pages.joined(separator: "\n\n")
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    static func load(_ providers: [NSItemProvider]) async throws -> String {
        let items = providers.filter(ImageImport.supports)
        guard !items.isEmpty, items.count <= ImageImport.maximumFiles else { throw AppFailure("一次请选择 1–8 个图片、PDF 或 Word 文件。") }
        var texts: [String] = []
        for item in items {
            try Task.checkCancellation()
            if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL = try await withCheckedThrowingContinuation { continuation in
                    item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                        if let error { continuation.resume(throwing: error); return }
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url else { continuation.resume(throwing: AppFailure("无法读取文件，请尝试“导入内容”。")); return }
                        continuation.resume(returning: url)
                    }
                }
                texts.append(try await extract(url))
            } else {
                let data = try await ImageImport.load([item])
                texts.append(try await OCR.recognize(data[0]))
            }
        }
        return try validated(texts.joined(separator: "\n\n"))
    }
}
