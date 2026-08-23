import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let output = assets.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct IconVariant {
    let points: Int
    let scale: Int

    var pixels: Int {
        points * scale
    }

    var fileName: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

let variants = [
    IconVariant(points: 16, scale: 1),
    IconVariant(points: 16, scale: 2),
    IconVariant(points: 32, scale: 1),
    IconVariant(points: 32, scale: 2),
    IconVariant(points: 128, scale: 1),
    IconVariant(points: 128, scale: 2),
    IconVariant(points: 256, scale: 1),
    IconVariant(points: 256, scale: 2),
    IconVariant(points: 512, scale: 1),
    IconVariant(points: 512, scale: 2)
]

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let scale = CGFloat(size) / 1024.0
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }

    let background = NSBezierPath(roundedRect: rect(96, 96, 832, 832), xRadius: 196 * scale, yRadius: 196 * scale)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.184, green: 0.478, blue: 0.961, alpha: 1),
        NSColor(calibratedRed: 0.125, green: 0.157, blue: 0.227, alpha: 1),
        NSColor(calibratedRed: 0.094, green: 0.71, blue: 0.541, alpha: 1)
    ])!
    gradient.draw(in: background, angle: -42)

    let foreground = NSColor(calibratedWhite: 0.96, alpha: 0.96)
    foreground.setStroke()

    let window = NSBezierPath(roundedRect: rect(238, 412, 548, 374), xRadius: 62 * scale, yRadius: 62 * scale)
    window.lineWidth = 58 * scale
    window.stroke()

    let titleBar = NSBezierPath()
    titleBar.lineWidth = 44 * scale
    titleBar.lineCapStyle = .round
    titleBar.move(to: NSPoint(x: 308 * scale, y: 684 * scale))
    titleBar.line(to: NSPoint(x: 716 * scale, y: 684 * scale))
    titleBar.stroke()

    let arrowStem = NSBezierPath()
    arrowStem.lineWidth = 64 * scale
    arrowStem.lineCapStyle = .round
    arrowStem.move(to: NSPoint(x: 512 * scale, y: 636 * scale))
    arrowStem.line(to: NSPoint(x: 512 * scale, y: 394 * scale))
    arrowStem.stroke()

    let arrowHead = NSBezierPath()
    arrowHead.lineWidth = 64 * scale
    arrowHead.lineCapStyle = .round
    arrowHead.lineJoinStyle = .round
    arrowHead.move(to: NSPoint(x: 400 * scale, y: 490 * scale))
    arrowHead.line(to: NSPoint(x: 512 * scale, y: 378 * scale))
    arrowHead.line(to: NSPoint(x: 624 * scale, y: 490 * scale))
    arrowHead.stroke()

    let minimizedBar = NSBezierPath()
    minimizedBar.lineWidth = 62 * scale
    minimizedBar.lineCapStyle = .round
    minimizedBar.move(to: NSPoint(x: 338 * scale, y: 280 * scale))
    minimizedBar.line(to: NSPoint(x: 686 * scale, y: 280 * scale))
    minimizedBar.stroke()

    NSColor(calibratedWhite: 0.96, alpha: 0.36).setStroke()
    let shadowBar = NSBezierPath()
    shadowBar.lineWidth = 28 * scale
    shadowBar.lineCapStyle = .round
    shadowBar.move(to: NSPoint(x: 384 * scale, y: 212 * scale))
    shadowBar.line(to: NSPoint(x: 640 * scale, y: 212 * scale))
    shadowBar.stroke()

    return image
}

for variant in variants {
    let image = drawIcon(size: variant.pixels)
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to render \(variant.fileName)")
    }

    try png.write(to: iconset.appendingPathComponent(variant.fileName))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconset.path,
    "-o",
    output.path
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print("Generated \(output.path)")
