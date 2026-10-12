// Draws the Uncloud app icon with Core Graphics: variant C, "Sun reveal".
//   xcrun swift scripts/make-icon.swift                  writes the AppIcon set and icon-final.png
//   xcrun swift scripts/make-icon.swift --variant A|B|C  writes a 1024 px PNG to the scratchpad
//   xcrun swift scripts/make-icon.swift --sheet          writes the A/B/C comparison sheet
// Everything is drawn with bezier paths, gradients and blurred shadows. No SF Symbols or Apple artwork.

import AppKit
import CoreGraphics
import Foundation

let scratch = "/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad"
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSetURL = repoRoot.appendingPathComponent("Uncloud/Assets.xcassets/AppIcon.appiconset")

// MARK: - Helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Stops are (hex, alpha, location).
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map { rgb($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
    CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func pngData(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

/// One cumulus puff. `a` is opacity: opaque puffs form the body, translucent ones the soft tails.
struct Puff {
    let x, y, r, a: CGFloat
    init(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat = 1) {
        self.x = x; self.y = y; self.r = r; self.a = a
    }
}

/// Evenly spaced, tapered rays. Each wedge is clipped and filled with a radial glow, so the rays
/// fade out toward their tips instead of ending in hard spikes.
func drawRays(_ ctx: CGContext, x: CGFloat, y: CGFloat, r: CGFloat, glow: CGFloat) {
    let count = 16
    for i in 0..<count {
        let a = CGFloat(i) * 2 * .pi / CGFloat(count)
        let halfWidth: CGFloat = 0.075  // radians at the base of each wedge
        let r1 = r * 1.08, r2 = glow * 0.95
        ctx.saveGState()
        ctx.move(to: CGPoint(x: x + cos(a - halfWidth) * r1, y: y + sin(a - halfWidth) * r1))
        ctx.addLine(to: CGPoint(x: x + cos(a) * r2, y: y + sin(a) * r2))
        ctx.addLine(to: CGPoint(x: x + cos(a + halfWidth) * r1, y: y + sin(a + halfWidth) * r1))
        ctx.closePath()
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([(0xFFF6E0, 0.42, 0), (0xFFF6E0, 0.18, r1 / glow), (0xFFF6E0, 0, 1)]),
            startCenter: CGPoint(x: x, y: y), startRadius: 0,
            endCenter: CGPoint(x: x, y: y), endRadius: glow, options: [])
        ctx.restoreGState()
    }
}

func drawSun(_ ctx: CGContext, x: CGFloat, y: CGFloat, r: CGFloat, glow: CGFloat, detail: Bool) {
    let c = CGPoint(x: x, y: y)
    // Halo, fading from warm white to nothing.
    ctx.drawRadialGradient(
        gradient([(0xFFF4C4, 0.95, 0), (0xFFD56B, 0.38, r / glow), (0xFF9F1C, 0, 1)]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: glow, options: [])
    if detail { drawRays(ctx, x: x, y: y, r: r, glow: glow) }
    // Disc, lit from the upper left.
    ctx.saveGState()
    ctx.addEllipse(in: circle(x, y, r))
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0xFFF8DC, 1, 0), (0xFFD56B, 1, 0.6), (0xFF9F1C, 1, 1)]),
        startCenter: CGPoint(x: x - r * 0.3, y: y + r * 0.3), startRadius: 0,
        endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Draws a cumulus. Opaque puffs get a soft underside shade and a top-left highlight, and the
/// whole cloud casts a soft blue shadow. Translucent puffs add wispy, fading edges.
func drawCloud(_ ctx: CGContext, _ puffs: [Puff], s: CGFloat) {
    let body = puffs.filter { $0.a >= 0.99 }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s,
                  color: rgb(0x0A2A5C, 0.26))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for p in puffs {
        ctx.setFillColor(rgb(0xFFFFFF, p.a))
        ctx.fillEllipse(in: circle(p.x, p.y, p.r))
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Shading is clipped to the opaque body so it stays inside the silhouette.
    guard !body.isEmpty else { return }
    let union = CGMutablePath()
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for p in body {
        union.addEllipse(in: circle(p.x, p.y, p.r))
        minX = min(minX, p.x - p.r); maxX = max(maxX, p.x + p.r)
        minY = min(minY, p.y - p.r); maxY = max(maxY, p.y + p.r)
    }
    ctx.saveGState()
    ctx.addPath(union)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x9DB3CC, 0, 0), (0x9DB3CC, 0.5, 1)]),
                           start: CGPoint(x: 0, y: maxY), end: CGPoint(x: 0, y: minY), options: [])
    let hl = CGPoint(x: minX + (maxX - minX) * 0.36, y: maxY - (maxY - minY) * 0.22)
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.75, 0), (0xFFFFFF, 0, 1)]),
                           startCenter: hl, startRadius: 0, endCenter: hl,
                           endRadius: (maxX - minX) * 0.55, options: [])
    ctx.restoreGState()
}

// MARK: - Variants (1024-unit canvas, origin bottom left)

/// A: overcast sky breaking to a clear sky. A cumulus drifts left, and a sun rises lower right.
func drawVariantA(_ ctx: CGContext, s: CGFloat, detail: Bool) {
    ctx.drawLinearGradient(gradient([(0x7F93AA, 1, 0), (0x8CC8F0, 1, 0.45), (0x3E8FF0, 1, 1)]),
                           start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    drawSun(ctx, x: 712, y: 298, r: 120, glow: 380, detail: detail)
    drawCloud(ctx, [
        Puff(300, 600, 88), Puff(396, 650, 112), Puff(500, 628, 104), Puff(588, 575, 80),
        Puff(410, 552, 96), Puff(262, 552, 62), Puff(350, 520, 82),
        Puff(170, 520, 46, 0.65), Puff(104, 482, 30, 0.4), Puff(60, 450, 18, 0.2),
    ], s: s)
}

/// B: a cloudy sky top left and a sunny sky bottom right, joined by a soft light burst.
func drawVariantB(_ ctx: CGContext, s: CGFloat, detail: Bool) {
    ctx.drawLinearGradient(gradient([(0xB9C6D6, 1, 0), (0x7D8DA3, 1, 1)]),
                           start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    let sun = CGPoint(x: 800, y: 224)
    ctx.drawRadialGradient(
        gradient([(0xFFEFB8, 1, 0), (0xFFC766, 0.95, 0.14), (0x8ED0FF, 0.95, 0.42), (0x6EC6FF, 0, 0.8)]),
        startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 700, options: [])
    drawSun(ctx, x: sun.x, y: sun.y, r: 112, glow: 330, detail: detail)
    drawCloud(ctx, [
        Puff(150, 700, 84), Puff(262, 746, 112), Puff(384, 730, 118), Puff(500, 758, 100),
        Puff(612, 716, 80), Puff(230, 640, 86), Puff(362, 648, 104), Puff(486, 668, 92),
        Puff(120, 620, 58, 0.8), Puff(640, 660, 60, 0.7),
    ], s: s)
}

/// C: a big sun on a rich blue sky, with a soft cloud drifting off its upper left edge.
func drawVariantC(_ ctx: CGContext, s: CGFloat, detail: Bool) {
    ctx.drawLinearGradient(gradient([(0x6EC6FF, 1, 0), (0x2E7BEF, 1, 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    drawSun(ctx, x: 540, y: 470, r: 190, glow: 520, detail: detail)
    // Motion lines trail the cloud to the left. Drawn before the cloud so the cloud overlaps them.
    if detail {
        ctx.setLineCap(.round)
        for (x0, y0, len, alpha, width) in [(120.0, 548.0, 190.0, 0.5, 11.0),
                                            (150.0, 500.0, 150.0, 0.32, 9.0)] {
            ctx.saveGState()
            ctx.setStrokeColor(rgb(0xFFFFFF, CGFloat(alpha)))
            ctx.setLineWidth(CGFloat(width))
            ctx.move(to: CGPoint(x: x0, y: y0))
            ctx.addCurve(to: CGPoint(x: x0 + CGFloat(len), y: y0 + 12),
                         control1: CGPoint(x: x0 + CGFloat(len) * 0.35, y: y0 - 4),
                         control2: CGPoint(x: x0 + CGFloat(len) * 0.7, y: y0 + 16))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
    // Moved up and left from the sun, with a gradual fade on the trailing puffs.
    drawCloud(ctx, [
        Puff(190, 646, 72), Puff(270, 714, 98), Puff(370, 752, 90), Puff(434, 696, 74),
        Puff(300, 642, 80),
        Puff(130, 642, 48, 0.7), Puff(84, 614, 32, 0.45), Puff(50, 590, 20, 0.2),
    ], s: s)
}

/// Renders one variant as a squircle app icon at `px` pixels.
func renderVariant(_ variant: String, px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    // Rays need 64 px or more, and motion lines 128 px or more, to read rather than shimmer.
    let detail = px >= 64
    let ctx = makeContext(width: px, height: px)
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: rgb(0x0B0530, 0.4))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x2E7BEF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    switch variant {
    case "A": drawVariantA(ctx, s: s, detail: detail)
    case "B": drawVariantB(ctx, s: s, detail: detail)
    default: drawVariantC(ctx, s: s, detail: detail)
    }
    // Hairline rim for edge definition on dark backgrounds.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 101.5, y: 101.5, width: 821, height: 821),
                       cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Outputs

/// The macOS AppIcon slots: point size, scale, and the pixel size each one needs.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                          (256, 1), (256, 2), (512, 1), (512, 2)]

func writeIconSet(variant: String) throws {
    try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    var rendered: [Int: CGImage] = [:]
    for slot in slots {
        let px = slot.points * slot.scale
        let filename = "icon_\(slot.points)x\(slot.points)" + (slot.scale == 2 ? "@2x" : "") + ".png"
        if rendered[px] == nil { rendered[px] = renderVariant(variant, px: px) }
        try pngData(rendered[px]!).write(to: iconSetURL.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(slot.scale)x",
                       "size": "\(slot.points)x\(slot.points)"])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents,
                                          options: [.prettyPrinted, .sortedKeys])
    try json.write(to: iconSetURL.appendingPathComponent("Contents.json"))
    print(iconSetURL.path)
}

/// Light and dark bands, each with the icon at 512 px and 64, 32 and 16 px beside it.
func writeSheet(name: String, variants: [String]) throws {
    let margin: CGFloat = 48, col: CGFloat = 512, gutter: CGFloat = 48
    let bandH: CGFloat = 700
    let width = margin * 2 + col * CGFloat(variants.count) + gutter * CGFloat(variants.count - 1)
    let ctx = makeContext(width: Int(width), height: Int(bandH * 2))
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsContext
    let bands: [(bg: UInt32, ink: NSColor, bottom: CGFloat)] = [
        (0x1E1E22, NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), 0),
        (0xF2F4F7, NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), bandH),
    ]
    let names = ["A  Breaking through", "B  Split day", "C  Sun reveal"]
    for band in bands {
        ctx.setFillColor(rgb(band.bg))
        ctx.fill(CGRect(x: 0, y: band.bottom, width: width, height: bandH))
        let top = band.bottom + bandH
        for (i, variant) in variants.enumerated() {
            let x = margin + CGFloat(i) * (col + gutter)
            (names[variant == "A" ? 0 : variant == "B" ? 1 : 2] as NSString).draw(
                at: CGPoint(x: x, y: top - 44),
                withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                                 .foregroundColor: band.ink])
            ctx.draw(renderVariant(variant, px: 512),
                     in: CGRect(x: x, y: top - 72 - col, width: col, height: col))
            let smallBottom = top - 72 - col - 40 - 64
            var sx = x
            for px in [64, 32, 16] {
                ctx.draw(renderVariant(variant, px: px),
                         in: CGRect(x: sx, y: smallBottom, width: CGFloat(px), height: CGFloat(px)))
                sx += CGFloat(px) + 28
            }
        }
    }
    let url = URL(fileURLWithPath: scratch + "/" + name)
    try pngData(ctx.makeImage()!).write(to: url)
    print(url.path)
}

let args = CommandLine.arguments
if args.contains("--sheet") {
    try writeSheet(name: "icon-variants.png", variants: ["A", "B", "C"])
} else if let i = args.firstIndex(of: "--variant"), i + 1 < args.count {
    let variant = args[i + 1].uppercased()
    let url = URL(fileURLWithPath: scratch + "/icon-variant-\(variant).png")
    try pngData(renderVariant(variant, px: 1024)).write(to: url)
    print(url.path)
} else {
    try writeIconSet(variant: "C")
    try writeSheet(name: "icon-final.png", variants: ["C"])
}
