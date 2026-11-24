#!/usr/bin/env swift
import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("No graphics context")
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

// Transparent canvas.
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Background: rounded square with a deep blue vertical gradient.
let backgroundRect = NSRect(x: 32, y: 32, width: size - 64, height: size - 64)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 218, yRadius: 218)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.11, green: 0.18, blue: 0.32, alpha: 1),
    NSColor(srgbRed: 0.035, green: 0.055, blue: 0.11, alpha: 1)
])!
gradient.draw(in: background, angle: -90)

// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
background.addClip()
let highlight = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.12),
    NSColor(white: 1, alpha: 0)
])!
highlight.draw(
    from: NSPoint(x: size / 2, y: size),
    to: NSPoint(x: size / 2, y: size * 0.55),
    options: []
)
NSGraphicsContext.restoreGraphicsState()

// Thin inner border.
NSColor(white: 1, alpha: 0.10).setStroke()
background.lineWidth = 3
background.stroke()

// Monitor.
let monitorRect = NSRect(x: 196, y: 286, width: 632, height: 430)
let monitor = NSBezierPath(roundedRect: monitorRect, xRadius: 56, yRadius: 56)
NSColor(srgbRed: 0.92, green: 0.96, blue: 1.0, alpha: 0.95).setStroke()
monitor.lineWidth = 28
monitor.stroke()

// Screen.
let screenRect = NSRect(x: 232, y: 322, width: 560, height: 358)
let screen = NSBezierPath(roundedRect: screenRect, xRadius: 34, yRadius: 34)
NSColor(srgbRed: 0.055, green: 0.095, blue: 0.17, alpha: 1).setFill()
screen.fill()

// Resolution swatches: four different aspect-ratio bars.
let swatchColors: [NSColor] = [
    NSColor(srgbRed: 0.35, green: 0.80, blue: 0.98, alpha: 0.92),
    NSColor(srgbRed: 0.36, green: 0.56, blue: 0.96, alpha: 0.92),
    NSColor(srgbRed: 0.67, green: 0.55, blue: 0.98, alpha: 0.92),
    NSColor(srgbRed: 0.98, green: 0.65, blue: 0.32, alpha: 0.92)
]
let widths: [CGFloat] = [286, 360, 430, 498]
let heights: [CGFloat] = [38, 38, 38, 38]
let baseY: CGFloat = 360
for index in 0..<4 {
    let rect = NSRect(
        x: 268,
        y: baseY + CGFloat(index) * 58,
        width: widths[index],
        height: heights[index]
    )
    let path = NSBezierPath(roundedRect: rect, xRadius: 19, yRadius: 19)
    swatchColors[index].setFill()
    path.fill()
}

// Small white cursor mark on the top swatch.
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 500, y: 470))
cursor.line(to: NSPoint(x: 566, y: 432))
cursor.line(to: NSPoint(x: 538, y: 426))
cursor.line(to: NSPoint(x: 552, y: 394))
cursor.line(to: NSPoint(x: 530, y: 384))
cursor.line(to: NSPoint(x: 516, y: 416))
cursor.line(to: NSPoint(x: 492, y: 398))
cursor.close()
NSColor(white: 1, alpha: 0.95).setFill()
cursor.fill()

// Stand.
let neck = NSBezierPath(roundedRect: NSRect(x: 478, y: 218, width: 68, height: 76), xRadius: 22, yRadius: 22)
NSColor(srgbRed: 0.92, green: 0.96, blue: 1.0, alpha: 0.95).setFill()
neck.fill()

let foot = NSBezierPath(roundedRect: NSRect(x: 384, y: 186, width: 256, height: 38), xRadius: 19, yRadius: 19)
foot.fill()

// Status dot.
let dot = NSBezierPath(ovalIn: NSRect(x: 728, y: 800, width: 58, height: 58))
NSColor(srgbRed: 0.35, green: 0.88, blue: 0.62, alpha: 1).setFill()
dot.fill()
NSColor(white: 1, alpha: 0.55).setStroke()
dot.lineWidth = 3
dot.stroke()

image.unlockFocus()

// Write 1024 master.
let masterURL = outputDirectory.appendingPathComponent("icon_512x512@2x.png")
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: masterURL)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512)
]

for variant in variants {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = [
        "-z", "\(variant.pixels)", "\(variant.pixels)",
        masterURL.path,
        "--out", outputDirectory.appendingPathComponent(variant.name).path
    ]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
}

print("Iconset written to \(outputDirectory.path)")
