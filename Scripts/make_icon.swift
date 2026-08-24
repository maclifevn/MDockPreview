import AppKit

// Renders a 1024×1024 macOS-style app icon mirroring the app: a window-preview
// card popping up above the hovered (middle) Dock icon. The preview shows an
// image thumbnail — the Maclife logo — with the app's red ✕ close button at the
// thumbnail's top-right corner. Output PNG path is argv[1].

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIconMaster.png"

let S = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor
}
func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
    ctx.addPath(rrect(r, radius)); ctx.setFillColor(c); ctx.fillPath()
}

// --- Background squircle ---
let inset: CGFloat = 100
let bg = CGRect(x: inset, y: inset, width: CGFloat(S) - 2*inset, height: CGFloat(S) - 2*inset)
ctx.saveGState()
ctx.addPath(rrect(bg, 185)); ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [rgb(74, 144, 255), rgb(45, 82, 226)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: bg.minX, y: bg.maxY), end: CGPoint(x: bg.maxX, y: bg.minY), options: [])
ctx.drawLinearGradient(
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: bg.midX, y: bg.maxY), end: CGPoint(x: bg.midX, y: bg.midY), options: [])
ctx.restoreGState()

let midX: CGFloat = 512

// --- Dock strip with three centered icons ---
let dockRect = CGRect(x: 272, y: 170, width: 480, height: 140)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(10, 25, 80, 0.30))
fill(dockRect, 42, rgb(255, 255, 255, 0.22))
ctx.restoreGState()
ctx.addPath(rrect(dockRect, 42)); ctx.setStrokeColor(rgb(255, 255, 255, 0.40)); ctx.setLineWidth(3); ctx.strokePath()

let dockColors = [rgb(255, 138, 61), rgb(18, 195, 244), rgb(166, 108, 255)] // middle = Maclife cyan
let iconSize: CGFloat = 96
let dockStep: CGFloat = 140
for i in 0..<3 {
    let cx = midX + CGFloat(i - 1) * dockStep
    let hovered = i == 1
    let cy = dockRect.midY + (hovered ? 12 : 0)
    let r = CGRect(x: cx - iconSize/2, y: cy - iconSize/2, width: iconSize, height: iconSize)
    if hovered {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: rgb(255, 255, 255, 0.95))
        fill(r, 24, dockColors[i])
        ctx.restoreGState()
    }
    fill(r, 24, dockColors[i])
    fill(CGRect(x: r.minX + 20, y: r.maxY - 34, width: r.width - 40, height: 14), 7, rgb(255, 255, 255, 0.55))
}

// --- Preview card centered above the middle icon ---
let card = CGRect(x: midX - 262, y: 352, width: 524, height: 402)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: midX - 34, y: card.minY + 4))
tail.addLine(to: CGPoint(x: midX, y: card.minY - 34))
tail.addLine(to: CGPoint(x: midX + 34, y: card.minY + 4))
tail.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(10, 25, 80, 0.38))
ctx.addPath(tail); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
fill(card, 52, rgb(255, 255, 255))
ctx.restoreGState()

// --- Image thumbnail inside the card ---
let thumb = CGRect(x: card.minX + 36, y: card.minY + 36, width: card.width - 72, height: card.height - 72)
ctx.saveGState()
ctx.addPath(rrect(thumb, 22)); ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [rgb(240, 246, 255), rgb(223, 234, 249)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: thumb.midX, y: thumb.maxY), end: CGPoint(x: thumb.midX, y: thumb.minY), options: [])
ctx.restoreGState()
ctx.addPath(rrect(thumb, 22)); ctx.setStrokeColor(rgb(210, 222, 240)); ctx.setLineWidth(2); ctx.strokePath()

// Maclife logo (from recut/public/favicon.svg, viewBox 64×54.75) centered.
let logoMinX: CGFloat = 1.29, logoMinY: CGFloat = 2.94
let logoW: CGFloat = 62.16 - 1.29, logoH: CGFloat = 50.15 - 2.94
let padX: CGFloat = 96, padY: CGFloat = 70
let scale = min((thumb.width - 2*padX) / logoW, (thumb.height - 2*padY) / logoH)
let drawW = logoW * scale, drawH = logoH * scale
let originX = thumb.midX - drawW/2
let originY = thumb.midY - drawH/2   // bottom of logo box (y-up)
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    // SVG is y-down; flip into the y-up context.
    CGPoint(x: originX + (x - logoMinX) * scale,
            y: originY + drawH - (y - logoMinY) * scale)
}
func poly(_ pts: [(CGFloat, CGFloat)], _ c: CGColor) {
    let p = CGMutablePath()
    p.move(to: P(pts[0].0, pts[0].1))
    for pt in pts.dropFirst() { p.addLine(to: P(pt.0, pt.1)) }
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath()
}
poly([(13.77, 17.46), (1.29, 50.15), (12.29, 50.15), (27.56, 26.78)], rgb(18, 195, 244))
poly([(43.12, 2.94), (27.56, 26.78), (62.16, 50.15)], rgb(57, 164, 220))
poly([(27.56, 26.78), (12.29, 50.15), (62.16, 50.15)], rgb(0, 102, 171))

// --- Red close button at the thumbnail's top-right corner ---
let closeR: CGFloat = 34
let closeC = CGPoint(x: thumb.maxX - closeR - 6, y: thumb.maxY - closeR - 6)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: rgb(0, 0, 0, 0.25))
ctx.setFillColor(rgb(255, 69, 58))
ctx.fillEllipse(in: CGRect(x: closeC.x - closeR, y: closeC.y - closeR, width: closeR*2, height: closeR*2))
ctx.restoreGState()
ctx.setStrokeColor(rgb(255, 255, 255))
ctx.setLineWidth(7); ctx.setLineCap(.round)
let d: CGFloat = 13
ctx.move(to: CGPoint(x: closeC.x - d, y: closeC.y - d)); ctx.addLine(to: CGPoint(x: closeC.x + d, y: closeC.y + d))
ctx.move(to: CGPoint(x: closeC.x - d, y: closeC.y + d)); ctx.addLine(to: CGPoint(x: closeC.x + d, y: closeC.y - d))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
