// Draws the CamTool app icon (a bullet camera on a ceiling mount) and writes Packaging/AppIcon.icns.
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

func drawIcon() {
    // Background: macOS rounded-square tile, desaturated graphite blue.
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
    fill(tilePath, [color(0x2A3444), color(0x1A2130), color(0x111620)])

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()

    // Ceiling mount.
    let plate = NSBezierPath(roundedRect: NSRect(x: 250, y: 690, width: 220, height: 46), xRadius: 18, yRadius: 18)
    fill(plate, [color(0xD7DCE4), color(0xA9B1BF)])
    let arm = NSBezierPath(roundedRect: NSRect(x: 332, y: 540, width: 56, height: 165), xRadius: 22, yRadius: 22)
    fill(arm, [color(0xC9CFD9), color(0x9099A9)], angle: 0)

    // Bullet camera, tilted down.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 500, yBy: 480)
    transform.rotate(byDegrees: -14)
    transform.concat()

    let body = NSBezierPath(roundedRect: NSRect(x: -270, y: -95, width: 500, height: 190), xRadius: 95, yRadius: 95)
    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = color(0x000000, 0.4)
    bodyShadow.shadowBlurRadius = 30
    bodyShadow.shadowOffset = NSSize(width: 0, height: -16)
    bodyShadow.set()
    color(0xFFFFFF).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    fill(body, [color(0xF3F5F8), color(0xD5DAE2), color(0xAEB6C3)])

    // Sun shield.
    let visor = NSBezierPath(roundedRect: NSRect(x: -290, y: 70, width: 545, height: 50), xRadius: 25, yRadius: 25)
    fill(visor, [color(0x3A4252), color(0x232935)])

    // Front bezel and lens.
    let center = NSPoint(x: 205, y: -5)
    let bezel = NSBezierPath(ovalIn: NSRect(x: center.x - 98, y: center.y - 98, width: 196, height: 196))
    fill(bezel, [color(0x2C323E), color(0x12151C)])
    let glass = NSBezierPath(ovalIn: NSRect(x: center.x - 68, y: center.y - 68, width: 136, height: 136))
    fill(glass, [color(0x0C1220), color(0x15284A), color(0x2A5C9E)], angle: -50)
    let core = NSBezierPath(ovalIn: NSRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
    color(0x07090E).setFill()
    core.fill()
    // Single soft reflection.
    color(0xFFFFFF, 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x + 12, y: center.y + 22, width: 22, height: 22)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

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
