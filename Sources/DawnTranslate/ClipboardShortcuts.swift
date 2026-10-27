import AppKit
import UniformTypeIdentifiers

// These shortcuts only handle events delivered to DawnTranslate. They do not
// observe other applications or require Input Monitoring permission.
final class ClipboardShortcuts {
    private var monitor: Any?
    init(paste: @escaping @MainActor () -> Void, submit: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if MainActor.assumeIsolated({ submit(event) }) { return nil }
            guard Self.isPaste(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
            MainActor.assumeIsolated { paste() }
            return nil
        }
    }
    static func isPaste(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        return keyCode == 9 && (relevant == .command || relevant == .control)
    }
    static func isSubmit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, markedText: Bool, repeating: Bool) -> Bool {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        return (keyCode == 36 || keyCode == 76) && relevant.isEmpty && !markedText && !repeating
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

enum ClipboardImages {
    static func providers(from board: NSPasteboard) -> [NSItemProvider] {
        // Some applications publish JPEG/HEIC or an NSImage representation
        // rather than the PNG/TIFF produced by macOS screenshot shortcuts.
        let types = [NSPasteboard.PasteboardType.png, .tiff] + (board.types ?? []).filter {
            $0 != .png && $0 != .tiff && UTType($0.rawValue)?.conforms(to: .image) == true
        }
        for type in types {
            if let data = board.data(forType: type), !data.isEmpty {
                return [NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)]
            }
        }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter(ContentImport.supportsFile)
            .map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        if !files.isEmpty { return files }
        if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation {
            return [NSItemProvider(item: data as NSData, typeIdentifier: UTType.tiff.identifier)]
        }
        return []
    }
}
