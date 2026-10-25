import AppKit

let directory = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.10, green: 0.29, blue: 0.27, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let heights: [CGFloat] = [130, 250, 430, 590, 350, 210, 390, 170]
NSColor(srgbRed: 0.93, green: 0.97, blue: 0.93, alpha: 1).setStroke()
for (index, height) in heights.enumerated() {
    let path = NSBezierPath()
    path.lineWidth = 45; path.lineCapStyle = .round
    let x = CGFloat(246 + index * 76)
    path.move(to: NSPoint(x: x, y: 512 - height / 2))
    path.line(to: NSPoint(x: x, y: 512 + height / 2))
    path.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("AppIcon.png"))
