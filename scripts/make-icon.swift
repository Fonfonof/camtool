// Draws the CamTool app icon (a front-facing camera lens) and writes Packaging/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func fill(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat = -90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func circle(_ center: NSPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func drawIcon() {
    // Background: macOS rounded-square tile, graphite.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x000000).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    fill(tilePath, [color(0x2B3340), color(0x161B24), color(0x0D1117)])

    // Front-facing lens module, centered.
    let center = NSPoint(x: 512, y: 512)

    // Aluminium bezel with a soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let bezelShadow = NSShadow()
    bezelShadow.shadowColor = color(0x000000, 0.55)
    bezelShadow.shadowBlurRadius = 40
    bezelShadow.shadowOffset = NSSize(width: 0, height: -20)
    bezelShadow.set()
    color(0xFFFFFF).setFill()
    circle(center, 262).fill()
    NSGraphicsContext.restoreGraphicsState()
    fill(circle(center, 262), [color(0xF4F6F9), color(0xD3D8E0), color(0xA7AFBC)])
    // Thin bevel.
    fill(circle(center, 236), [color(0x9AA2AF), color(0xE9ECF1)])

    // Dark front plate.
    fill(circle(center, 228), [color(0x232934), color(0x0C0F15)])

    // Ring of infrared LEDs.
    for i in 0..<12 {
        let angle = CGFloat(i) / 12 * 2 * .pi
        let led = NSPoint(x: center.x + cos(angle) * 196, y: center.y + sin(angle) * 196)
        fill(circle(led, 11), [color(0x3A2128), color(0x1A1015)])
    }

    // Glass.
    fill(circle(center, 168), [color(0x0A0F1A), color(0x1A1F2A)], angle: -90)
    let glass = circle(center, 150)
    NSGradient(colors: [color(0x2A5FAE), color(0x0F2F66), color(0x050B18)])!
        .draw(in: glass, relativeCenterPosition: NSPoint(x: -0.25, y: 0.25))

    // Iris ring and pupil.
    let iris = circle(center, 92)
    iris.lineWidth = 3
    color(0x8DB8FF, 0.16).setStroke()
    iris.stroke()
    fill(circle(center, 58), [color(0x05070C), color(0x0B1220)])

    // Single crisp reflection, plus a faint secondary one.
    color(0xFFFFFF, 0.7).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 86, y: center.y + 52, width: 46, height: 28)).fill()
    color(0xFFFFFF, 0.18).setFill()
    circle(NSPoint(x: center.x + 70, y: center.y - 78), 12).fill()

    // Thin inner border for a crisp edge on dark backgrounds.
    let border = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    border.lineWidth = 4
    color(0xFFFFFF, 0.07).setStroke()
    border.stroke()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(size) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: root.appendingPathComponent("Packaging/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Packaging/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Packaging/AppIcon.icns" : "iconutil failed")
