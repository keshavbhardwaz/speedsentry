#!/usr/bin/env swift
import AppKit
import Foundation

// Original geometric artwork, rendered locally with macOS frameworks.
// Usage: swift scripts/make-icon.swift [output.icns] [optional-preview.png]
let project = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : project.appendingPathComponent("Resources/SpeedSentry.icns")
let files = FileManager.default
let temporary = files.temporaryDirectory.appendingPathComponent("SpeedSentry-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("SpeedSentry.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }

func png(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 212, yRadius: 212)
    NSGradient(
        starting: NSColor(srgbRed: 0.10, green: 0.30, blue: 0.58, alpha: 1),
        ending: NSColor(srgbRed: 0.035, green: 0.12, blue: 0.29, alpha: 1)
    )!.draw(in: background, angle: -60)

    let center = NSPoint(x: 512, y: 430)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 296, startAngle: 210, endAngle: -30, clockwise: true)
    arc.lineWidth = 58
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    for angle in stride(from: 210.0, through: -30.0, by: -60) {
        let radians = angle * .pi / 180
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: center.x + cos(radians) * 217, y: center.y + sin(radians) * 217))
        tick.line(to: NSPoint(x: center.x + cos(radians) * 245, y: center.y + sin(radians) * 245))
        tick.lineWidth = 23
        tick.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.86).setStroke()
        tick.stroke()
    }

    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: 664, y: 603))
    needle.lineWidth = 36
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 49, y: center.y - 49, width: 98, height: 98)).fill()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
process.standardError = Pipe()
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    // If iconutil cannot encode on the current system, ICNS also supports
    // PNG-backed elements directly; write that container without extra tools.
    func bigEndian(_ value: Int) -> Data {
        var integer = UInt32(value).bigEndian
        return withUnsafeBytes(of: &integer) { Data($0) }
    }
    let elements = [
        ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
    ]
    var payload = Data()
    for (type, filename) in elements {
        let data = try Data(contentsOf: iconset.appendingPathComponent(filename))
        payload.append(Data(type.utf8))
        payload.append(bigEndian(data.count + 8))
        payload.append(data)
    }
    var container = Data("icns".utf8)
    container.append(bigEndian(payload.count + 8))
    container.append(payload)
    try container.write(to: output, options: .atomic)
}
if CommandLine.arguments.count > 2 {
    try png(size: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("Created \(output.path)")
