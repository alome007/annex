import AppKit
import SwiftUI

// Draws the Annex app icon: the app's glass power key, carrying its
// house icon, on a black body. Every size is drawn from the vectors rather
// than scaled down, so the small ones stay sharp.
//
// Run from the repository root:  swift scripts/makeicon.swift
// Writes icon_1024.png and AppIcon.icns.

/// All geometry is on Apple's 1024-point icon grid, y pointing down.
let grid: CGFloat = 1024
/// The icon body sits inside the grid with room for its shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4
/// The glass key, nudged up a little so it looks centred above its shadow.
let key = CGRect(x: 236, y: 226, width: 552, height: 552)
let keyRadius: CGFloat = 168
/// The house is the app's own glyph, drawn on its 24-point grid.
let houseSize: CGFloat = 350
/// At 16 and 32 pixels the key leaves the house too small to read, so those
/// sizes draw the house alone on the body, larger and heavier.
let smallHouseSize: CGFloat = 560

func white(_ alpha: CGFloat) -> CGColor { CGColor(gray: 1, alpha: alpha) }
func gray(_ value: CGFloat) -> CGColor { CGColor(gray: value, alpha: 1) }

func continuous(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// The house outline and door from the app's glyph set, placed and scaled.
func house(centre: CGPoint, size: CGFloat) -> (outline: CGPath, door: CGPath) {
    let scale = size / 24
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + (x - 12) * scale, y: centre.y + (y - 12) * scale)
    }
    let corners = [point(3.8, 10.6), point(12, 3.8), point(20.2, 10.6), point(20.2, 20.2), point(3.8, 20.2)]
    let outline = CGMutablePath()
    let first = corners[0], last = corners[corners.count - 1]
    outline.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for (index, corner) in corners.enumerated() {
        outline.addArc(tangent1End: corner, tangent2End: corners[(index + 1) % corners.count], radius: 2.6 * scale)
    }
    outline.closeSubpath()
    let doorRect = CGRect(origin: point(9.7, 14.3), size: CGSize(width: 4.6 * scale, height: 6.3 * scale))
    return (outline, continuous(doorRect, 2.1 * scale))
}

func linear(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ context: CGContext, _ colors: [CGColor], centre: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
}

/// Fills a band along a path's edge with a gradient: a rim of light.
func rim(_ context: CGContext, _ path: CGPath, width: CGFloat, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.addPath(path)
    context.setLineWidth(width * 2)
    context.replacePathWithStrokedPath()
    context.clip()
    linear(context, colors, from: start, to: end)
    context.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let pixelScale = CGFloat(pixels) / grid
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: pixelScale, y: -pixelScale)
    // Shadow offsets and blur are in pixels and ignore the flip: negative y is down.
    func shadow(down: CGFloat, blur: CGFloat, alpha: CGFloat) {
        context.setShadow(offset: CGSize(width: 0, height: -down * pixelScale), blur: blur * pixelScale, color: CGColor(gray: 0, alpha: alpha))
    }

    let bodyPath = continuous(body, bodyRadius)
    let keyPath = continuous(key, keyRadius)

    // The body: black, lit softly from above like a glossy object.
    context.saveGState()
    shadow(down: 10, blur: 22, alpha: 0.32)
    context.addPath(bodyPath)
    context.setFillColor(gray(0.06))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    linear(context, [gray(0.13), gray(0.02)], from: CGPoint(x: 512, y: body.minY), to: CGPoint(x: 512, y: body.maxY))
    radial(context, [white(0.07), white(0)], centre: CGPoint(x: 512, y: 150), radius: 520)
    context.restoreGState()
    rim(context, bodyPath, width: 2.5, [white(0.24), white(0.03)], from: CGPoint(x: 512, y: body.minY), to: CGPoint(x: 512, y: body.midY))

    let tiny = pixels <= 32
    if !tiny {
    // The key's shadow on the body, then the glass itself.
    context.saveGState()
    shadow(down: 24, blur: 56, alpha: 0.7)
    context.addPath(keyPath)
    context.setFillColor(gray(0.10))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(keyPath)
    context.clip()
    linear(context, [gray(0.27), gray(0.13)], from: CGPoint(x: 512, y: key.minY), to: CGPoint(x: 512, y: key.maxY))
    // A sheen across the upper half, where glass catches the light.
    radial(context, [white(0.16), white(0)], centre: CGPoint(x: 430, y: key.minY + 40), radius: 380)
    context.restoreGState()
    rim(context, keyPath, width: 3.5, [white(0.85), white(0.22), white(0.06)], from: CGPoint(x: key.minX, y: key.minY), to: CGPoint(x: key.maxX, y: key.maxY))
    }

    // The house, white with a soft inner tone and a faint glow.
    let size = tiny ? smallHouseSize : houseSize
    let centre = tiny ? CGPoint(x: body.midX, y: body.midY + 10) : CGPoint(x: key.midX, y: key.midY + 6)
    let (outline, door) = house(centre: centre, size: size)
    let stroke = (tiny ? 2.6 : pixels <= 64 ? 2.4 : 1.95) * size / 24
    context.saveGState()
    context.setShadow(offset: .zero, blur: 26 * pixelScale, color: white(0.28))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(outline)
    context.setFillColor(white(0.2))
    context.fillPath()
    context.addPath(outline)
    context.setStrokeColor(white(1))
    context.setLineWidth(stroke)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
    context.addPath(door)
    context.setFillColor(white(1))
    context.fillPath()
    context.endTransparencyLayer()
    context.restoreGState()

    return context.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try png(render(pixels: 1024)).write(to: root.appending(path: "icon_1024.png"))

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(render(pixels: points)).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(render(pixels: points * 2)).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil could not build AppIcon.icns")
}
print("wrote icon_1024.png and AppIcon.icns")
