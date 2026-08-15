import AppKit

// Draws the HAOS Runner icon: an HA-blue squircle, a white house, and a blue
// play triangle inside it — "run Home Assistant". Outputs icon_1024.png.
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let haBlue = NSColor(srgbRed: 0.012, green: 0.663, blue: 0.957, alpha: 1)
let haBlueDeep = NSColor(srgbRed: 0.008, green: 0.533, blue: 0.820, alpha: 1)

// Rounded-rect background (macOS squircle-ish). Slight inset so it isn't edge-to-edge.
let inset = 64.0
let bgRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
haBlue.setFill()
bg.fill()
// A faint deeper edge at the bottom for a touch of depth (still flat, HA-ish).
haBlueDeep.withAlphaComponent(0.18).setFill()
let shade = NSBezierPath(roundedRect: bgRect.insetBy(dx: 0, dy: 0), xRadius: 200, yRadius: 200)
shade.setClip()
let bottomBand = NSBezierPath(rect: NSRect(x: inset, y: inset, width: size - inset * 2, height: 120))
bottomBand.fill()
NSGraphicsContext.current?.cgContext.resetClip()

// White house (pentagon silhouette), centered.
let house = NSBezierPath()
house.move(to: NSPoint(x: 512, y: 780))     // apex
house.line(to: NSPoint(x: 760, y: 560))     // right eave
house.line(to: NSPoint(x: 700, y: 300))     // bottom-right
house.line(to: NSPoint(x: 324, y: 300))     // bottom-left
house.line(to: NSPoint(x: 264, y: 560))     // left eave
house.close()
house.lineJoinStyle = .round
NSColor.white.setFill()
house.fill()

// Blue play triangle inside the body — "run".
let play = NSBezierPath()
play.move(to: NSPoint(x: 452, y: 610))
play.line(to: NSPoint(x: 452, y: 400))
play.line(to: NSPoint(x: 636, y: 505))
play.close()
play.lineJoinStyle = .round
haBlue.setFill()
play.fill()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
