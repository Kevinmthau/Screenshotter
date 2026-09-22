import AppKit
import Foundation

// A native vector drawing rendered at Apple's icon sizes; no downloaded assets.
guard CommandLine.arguments.count == 2 else { fatalError("Pass the output .iconset directory") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    let body = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 194, yRadius: 194)
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.50, blue: 0.94, alpha: 1),
               ending: NSColor(calibratedRed: 0.15, green: 0.27, blue: 0.69, alpha: 1))!.draw(in: body, angle: -65)
    let screen = NSBezierPath(roundedRect: NSRect(x: 243, y: 321, width: 538, height: 382), xRadius: 34, yRadius: 34)
    NSColor.white.withAlphaComponent(0.94).setStroke()
    screen.lineWidth = 29
    screen.stroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 309, y: 415))
    line.line(to: NSPoint(x: 435, y: 530))
    line.line(to: NSPoint(x: 528, y: 456))
    line.line(to: NSPoint(x: 648, y: 586))
    line.lineWidth = 27
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.stroke()
    let sun = NSBezierPath(ovalIn: NSRect(x: 323, y: 579, width: 49, height: 49))
    NSColor.white.withAlphaComponent(0.94).setFill()
    sun.fill()
    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: 759, y: 823))
    sparkle.curve(to: NSPoint(x: 869, y: 713), controlPoint1: NSPoint(x: 770, y: 741), controlPoint2: NSPoint(x: 787, y: 724))
    sparkle.curve(to: NSPoint(x: 759, y: 603), controlPoint1: NSPoint(x: 787, y: 702), controlPoint2: NSPoint(x: 770, y: 685))
    sparkle.curve(to: NSPoint(x: 649, y: 713), controlPoint1: NSPoint(x: 748, y: 685), controlPoint2: NSPoint(x: 731, y: 702))
    sparkle.curve(to: NSPoint(x: 759, y: 823), controlPoint1: NSPoint(x: 731, y: 724), controlPoint2: NSPoint(x: 748, y: 741))
    NSColor(calibratedRed: 0.98, green: 0.86, blue: 0.50, alpha: 1).setFill()
    sparkle.fill()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try drawIcon(size: points * multiplier).write(to: file)
    }
}
