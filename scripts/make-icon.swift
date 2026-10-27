import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
] {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(red: 0.10, green: 0.34, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 210, yRadius: 210).fill()
    NSColor(red: 0.70, green: 0.91, blue: 0.81, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 172, y: 363, width: 472, height: 426), xRadius: 94, yRadius: 94).fill()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 218, y: 407)); tail.line(to: NSPoint(x: 218, y: 292)); tail.line(to: NSPoint(x: 348, y: 407)); tail.close(); tail.fill()
    ("A" as NSString).draw(at: NSPoint(x: 260, y: 452), withAttributes: [.font: NSFont.systemFont(ofSize: 250, weight: .semibold), .foregroundColor: NSColor(red: 0.10, green: 0.34, blue: 0.30, alpha: 1)])
    // A small dawn mark gives this original bilingual dialogue icon its identity.
    NSColor(red: 1, green: 0.80, blue: 0.43, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 734, y: 752, width: 92, height: 92)).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 455, y: 219, width: 389, height: 358), xRadius: 80, yRadius: 80).fill()
    let secondTail = NSBezierPath()
    secondTail.move(to: NSPoint(x: 792, y: 278)); secondTail.line(to: NSPoint(x: 792, y: 168)); secondTail.line(to: NSPoint(x: 674, y: 278)); secondTail.close(); secondTail.fill()
    ("文" as NSString).draw(at: NSPoint(x: 536, y: 279), withAttributes: [.font: NSFont.systemFont(ofSize: 220, weight: .medium), .foregroundColor: NSColor(red: 0.10, green: 0.34, blue: 0.30, alpha: 1)])
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
