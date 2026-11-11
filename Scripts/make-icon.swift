// Draws the app icon and writes Resources/AppIcon.icns.
//
//   swift Scripts/make-icon.swift
//
// The icon is drawn in code so it can be changed without a design tool:
// a blue macOS-style tile, a sheet of paper with an XML bracket and text
// lines, and a green check badge.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid())")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024 × 1024 canvas (origin bottom left).
func draw(_ c: CGContext) {
    // Tile: Apple's grid leaves a 100 pt margin around an 824 pt rounded square.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    c.addPath(tilePath); c.setFillColor(color(0x1F4FBF)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x3D7BFF), color(0x1A3FA8)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    // Paper with a folded top-right corner.
    let paper = CGRect(x: 262, y: 196, width: 470, height: 610)
    let fold: CGFloat = 120
    let sheet = CGMutablePath()
    sheet.move(to: CGPoint(x: paper.minX + 28, y: paper.minY))
    sheet.addLine(to: CGPoint(x: paper.maxX - 28, y: paper.minY))
    sheet.addQuadCurve(to: CGPoint(x: paper.maxX, y: paper.minY + 28), control: CGPoint(x: paper.maxX, y: paper.minY))
    sheet.addLine(to: CGPoint(x: paper.maxX, y: paper.maxY - fold))
    sheet.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY))
    sheet.addLine(to: CGPoint(x: paper.minX + 28, y: paper.maxY))
    sheet.addQuadCurve(to: CGPoint(x: paper.minX, y: paper.maxY - 28), control: CGPoint(x: paper.minX, y: paper.maxY))
    sheet.addLine(to: CGPoint(x: paper.minX, y: paper.minY + 28))
    sheet.addQuadCurve(to: CGPoint(x: paper.minX + 28, y: paper.minY), control: CGPoint(x: paper.minX, y: paper.minY))
    sheet.closeSubpath()

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    c.addPath(sheet); c.setFillColor(color(0xFFFFFF)); c.fillPath()
    c.restoreGState()

    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: paper.maxX - fold, y: paper.maxY))
    flap.addLine(to: CGPoint(x: paper.maxX - fold, y: paper.maxY - fold + 18))
    flap.addQuadCurve(to: CGPoint(x: paper.maxX - fold + 18, y: paper.maxY - fold),
                      control: CGPoint(x: paper.maxX - fold, y: paper.maxY - fold))
    flap.addLine(to: CGPoint(x: paper.maxX, y: paper.maxY - fold))
    flap.closeSubpath()
    c.addPath(flap); c.setFillColor(color(0xD5DEEE)); c.fillPath()

    // "</>" in the top left of the sheet: the hidden XML part.
    c.setStrokeColor(color(0x2E63E0)); c.setLineWidth(26); c.setLineCap(.round); c.setLineJoin(.round)
    let bx = paper.minX + 62, by = paper.maxY - 130
    c.move(to: CGPoint(x: bx + 46, y: by + 46)); c.addLine(to: CGPoint(x: bx, y: by)); c.addLine(to: CGPoint(x: bx + 46, y: by - 46))
    c.move(to: CGPoint(x: bx + 128, y: by + 46)); c.addLine(to: CGPoint(x: bx + 174, y: by)); c.addLine(to: CGPoint(x: bx + 128, y: by - 46))
    c.move(to: CGPoint(x: bx + 104, y: by + 56)); c.addLine(to: CGPoint(x: bx + 70, y: by - 56))
    c.strokePath()

    // Text lines.
    c.setStrokeColor(color(0xC3CCDD)); c.setLineWidth(24)
    for (index, width) in [330.0, 290, 330, 200].enumerated() {
        let y = paper.maxY - 260 - CGFloat(index) * 66
        c.move(to: CGPoint(x: paper.minX + 66, y: y)); c.addLine(to: CGPoint(x: paper.minX + 66 + width, y: y))
    }
    c.strokePath()

    // Green check badge, overlapping the bottom right of the sheet.
    let badge = CGRect(x: 560, y: 150, width: 300, height: 300)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.30))
    c.addEllipse(in: badge); c.setFillColor(color(0xFFFFFF)); c.fillPath()
    c.restoreGState()
    c.addEllipse(in: badge.insetBy(dx: 18, dy: 18)); c.setFillColor(color(0x23A55A)); c.fillPath()
    c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(40)
    c.move(to: CGPoint(x: badge.minX + 82, y: badge.midY + 2))
    c.addLine(to: CGPoint(x: badge.minX + 132, y: badge.midY - 50))
    c.addLine(to: CGPoint(x: badge.maxX - 74, y: badge.midY + 58))
    c.strokePath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.interpolationQuality = .high
    draw(cg)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// A PNG for the README.
try render(pixels: 256).write(to: root.appendingPathComponent("docs/icon.png"))
try? FileManager.default.removeItem(at: work)
print("Wrote \(output.path)")
