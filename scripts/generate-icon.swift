import AppKit

// Owned geometric A / audio mark. Render each size directly, with no raster resampling.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
func render(_ size: Int, mac: Bool = false, to url: URL) throws {
    let side = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    let inset: CGFloat = mac ? side * 0.1 : 0
    let box = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    NSColor.black.setFill()
    if mac { NSBezierPath(roundedRect: box, xRadius: side * 0.18, yRadius: side * 0.18).fill() }
    else { NSBezierPath(rect: box).fill() }
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: box.minX + box.width * (0.2 + 0.6 * x), y: box.maxY - box.height * (0.2 + 0.6 * y))
    }
    let path = NSBezierPath(); path.lineWidth = box.width * 0.072; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: point(0.05, 0.9)); path.line(to: point(0.41, 0.12))
    path.curve(to: point(0.59, 0.12), controlPoint1: point(0.47, -0.0066667), controlPoint2: point(0.53, -0.0066667))
    path.line(to: point(0.95, 0.9))
    NSColor.white.setStroke(); path.stroke()
    let wave = NSBezierPath(); wave.lineWidth = box.width * 0.032; wave.lineCapStyle = .round
    for (x, height) in [(CGFloat(0.39), CGFloat(0.10)), (0.5, 0.24), (0.61, 0.10)] {
        wave.move(to: point(x, 0.64 - height / 2)); wave.line(to: point(x, 0.64 + height / 2))
    }
    wave.stroke(); NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
let phone = root.appendingPathComponent("Sources/Phone/Assets.xcassets/AppIcon.appiconset")
try render(1024, to: phone.appendingPathComponent("AppIcon.png"))
let watch = root.appendingPathComponent("Sources/Watch/Assets.xcassets/AppIcon.appiconset")
let watchContents = try JSONSerialization.jsonObject(with: Data(contentsOf: watch.appendingPathComponent("Contents.json"))) as! [String: Any]
for item in watchContents["images"] as! [[String: String]] {
    let points = Double(item["size"]!.split(separator: "x")[0])!
    let scale = Double(item["scale"]!.dropLast())!
    try render(Int(points * scale), to: watch.appendingPathComponent(item["filename"]!))
}
let mac = root.appendingPathComponent("Sources/Mac/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon-\(points)-\(scale)x.png"
        try render(points * scale, mac: true, to: mac.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let content: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys]).write(to: mac.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}\n".utf8).write(to: mac.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Rendered monochrome phone, watch and Mac icons.")
