import Foundation
import AppKit
import PDFKit
import CoreText
import UniformTypeIdentifiers

@main struct ContentChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dawn-documents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw AppFailure("FAIL: \(message)") }
            print("PASS \(message)")
        }
        let body = "Meeting confirmation\nPlease confirm the meeting time.\n谢谢，请确认会议时间。"
        let attributed = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 22)])
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("doc", .docFormat)] {
            let url = root.appendingPathComponent("meeting.\(ext)")
            try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type]).write(to: url)
            let text = try await ContentImport.extract(url)
            try check(text.contains("confirm the meeting time") && text.contains("请确认会议时间"), "\(ext) preserves Chinese and English paragraphs")
            let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            let dropped = try await ContentImport.load([provider])
            try check(dropped == text, "\(ext) file provider follows document import path")
        }
        let pdfData = NSMutableData()
        let consumer = CGDataConsumer(data: pdfData)!
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 300)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Selectable PDF meeting text", attributes: [.font: NSFont.systemFont(ofSize: 24)])), context)
        context.endPDFPage(); context.closePDF()
        let pdf = PDFDocument(data: pdfData as Data)!
        let image = NSImage(size: NSSize(width: 800, height: 200))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 200).fill()
        ("Scanned page: please confirm." as NSString).draw(at: NSPoint(x: 25, y: 85), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        image.unlockFocus()
        pdf.insert(PDFPage(image: image)!, at: 1)
        let url = root.appendingPathComponent("mixed.pdf")
        try pdf.dataRepresentation()!.write(to: url)
        let text = try await ContentImport.extract(url)
        try check(text.contains("Selectable PDF meeting text"), "PDF extracts selectable text")
        try check(text.contains("Scanned page") && text.contains("please confirm"), "PDF recognizes scanned page locally")
        try check(text.range(of: "Selectable")!.lowerBound < text.range(of: "Scanned")!.lowerBound, "mixed PDF retains page order")
        let corrupt = root.appendingPathComponent("corrupt.pdf")
        try Data("not pdf".utf8).write(to: corrupt)
        do { _ = try await ContentImport.extract(corrupt); throw AppFailure("Unexpected success") }
        catch { try check(!error.localizedDescription.contains("Unexpected success"), "corrupt PDF rejected") }
        do { _ = try ContentImport.validated(String(repeating: "字", count: 60001)); throw AppFailure("Unexpected success") }
        catch { try check(!error.localizedDescription.contains("Unexpected success"), "oversized text rejected without truncation") }
        do { _ = try ContentImport.validated(" \n "); throw AppFailure("Unexpected success") }
        catch { try check(!error.localizedDescription.contains("Unexpected success"), "empty document rejected") }
        let locked = root.appendingPathComponent("locked.pdf")
        guard pdf.write(to: locked, withOptions: [.userPasswordOption: "test-password", .ownerPasswordOption: "owner-password"]) else { throw AppFailure("Unable to create encrypted test fixture") }
        do { _ = try await ContentImport.extract(locked); throw AppFailure("Unexpected success") }
        catch { try check(error.localizedDescription.contains("加密"), "encrypted PDF asks user to unlock") }
        let task = Task { try await ContentImport.extract(url) }
        task.cancel()
        do { _ = try await task.value; throw AppFailure("Unexpected success") }
        catch is CancellationError { try check(true, "cancelled document cannot publish extracted text") }
        print("12 content checks passed. No external service or user file used.")
    }
}
