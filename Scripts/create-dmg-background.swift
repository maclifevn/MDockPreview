#!/usr/bin/env swift
import AppKit
import Foundation

// Draws the installer window backdrop for the release DMG — generated rather
// than checked in as a binary so the version line stays truthful.
//
//   usage: create-dmg-background.swift OUTPUT.png [VERSION] [REQUIREMENTS]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: create-dmg-background.swift OUTPUT.png [VERSION] [REQUIREMENTS]\n".utf8)
    )
    exit(2)
}
let version = arguments.count > 2 ? arguments[2] : ""
let requirements = arguments.count > 3 ? arguments[3] : "macOS 14 or later"

let width = 640
let height = 380
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not allocate DMG background") }

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create drawing context")
}
NSGraphicsContext.current = context

let bounds = NSRect(x: 0, y: 0, width: width, height: height)

// Soft light gradient to match the app's bright UI.
let base = NSGradient(colors: [
    NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
    NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.98, alpha: 1),
])!
base.draw(in: bounds, angle: -90)

// A gentle blue glow near the top, echoing the accent.
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.30, green: 0.52, blue: 1, alpha: 0.14),
    NSColor(calibratedRed: 0.30, green: 0.52, blue: 1, alpha: 0),
])!
glow.draw(
    fromCenter: NSPoint(x: width / 2, y: 250), radius: 0,
    toCenter: NSPoint(x: width / 2, y: 250), radius: 300,
    options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
)

func centered(_ string: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .kern: 0.15,
    ]
    let size = string.size(withAttributes: attributes)
    string.draw(
        at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: y),
        withAttributes: attributes
    )
}

centered(
    version.isEmpty ? "Install MDock Preview" : "Install MDock Preview \(version)",
    y: 326,
    font: .systemFont(ofSize: 22, weight: .semibold),
    color: NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.19, alpha: 1)
)
centered(
    "Drag MDock Preview to Applications",
    y: 302,
    font: .systemFont(ofSize: 12.5, weight: .regular),
    color: NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.52, alpha: 1)
)

// Accent arrow between the two Finder icons.
NSColor(calibratedRed: 0.18, green: 0.42, blue: 1, alpha: 0.9).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 284, y: 176))
arrow.line(to: NSPoint(x: 356, y: 176))
arrow.move(to: NSPoint(x: 344, y: 188))
arrow.line(to: NSPoint(x: 357, y: 176))
arrow.line(to: NSPoint(x: 344, y: 164))
arrow.stroke()

centered(
    requirements,
    y: 31,
    font: .systemFont(ofSize: 10.5, weight: .medium),
    color: NSColor(calibratedRed: 0.60, green: 0.64, blue: 0.70, alpha: 1)
)

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode DMG background")
}
try data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
