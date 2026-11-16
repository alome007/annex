import AppKit
import SwiftUI

/// The app's own icon set, drawn on a 24-point grid with round ends, round
/// joins and generous corners. Shapes that enclose a space carry a soft inner
/// tone, so each icon reads as a small object rather than a line drawing.
/// Colour comes from the surrounding foreground style, as with a system symbol.
enum Glyph: CaseIterable {
    case home, apps, system
    case power, download
    case processor, memory, disk, network, updates
    case copy, check, open, search, more, warning, close, trash, chevronRight, package, plus
}

/// One icon as paths on the 24-point grid: an outline that is stroked, an
/// inner tone that is filled faintly, and small details filled solid.
private struct GlyphDrawing {
    var outline = Path()
    var tone: Path?
    var solid: Path?
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

private extension Path {
    /// A closed polygon with every corner rounded to the same radius.
    mutating func addRoundedPolygon(_ points: [CGPoint], radius: CGFloat) {
        guard let first = points.first, let last = points.last else { return }
        move(to: pt((last.x + first.x) / 2, (last.y + first.y) / 2))
        for (index, corner) in points.enumerated() {
            addArc(tangent1End: corner, tangent2End: points[(index + 1) % points.count], radius: radius)
        }
        closeSubpath()
    }

    mutating func addCircle(_ centre: CGPoint, _ radius: CGFloat) {
        addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    mutating func addRounded(_ rect: CGRect, _ radius: CGFloat) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
    }

    static func build(_ draw: (inout Path) -> Void) -> Path {
        var path = Path()
        draw(&path)
        return path
    }
}

extension Glyph {
    fileprivate var drawing: GlyphDrawing {
        switch self {
        case .home:
            let house = Path.build {
                $0.addRoundedPolygon([pt(3.8, 10.6), pt(12, 3.8), pt(20.2, 10.6), pt(20.2, 20.2), pt(3.8, 20.2)], radius: 2.6)
            }
            let door = Path.build { $0.addRounded(CGRect(x: 9.7, y: 14.3, width: 4.6, height: 6.3), 2.1) }
            return GlyphDrawing(outline: house, tone: house, solid: door)

        case .apps:
            let tiles = Path.build {
                $0.addRounded(CGRect(x: 3.5, y: 3.5, width: 7.6, height: 7.6), 2.6)
                $0.addRounded(CGRect(x: 12.9, y: 3.5, width: 7.6, height: 7.6), 2.6)
                $0.addRounded(CGRect(x: 3.5, y: 12.9, width: 7.6, height: 7.6), 2.6)
                $0.addCircle(pt(16.7, 16.7), 3.8)
            }
            return GlyphDrawing(outline: tiles, tone: tiles)

        case .system:
            var points: [CGPoint] = []
            for tooth in 0..<8 {
                let centre = Double(tooth) * 45
                for (offset, radius) in [(-15.0, 7.0), (-8.0, 9.8), (8.0, 9.8), (15.0, 7.0)] {
                    let angle = (centre + offset) * .pi / 180
                    points.append(pt(12 + CGFloat(radius * cos(angle)), 12 + CGFloat(radius * sin(angle))))
                }
            }
            let gear = Path.build {
                $0.addRoundedPolygon(points, radius: 1.1)
                $0.addCircle(pt(12, 12), 3.1)
            }
            return GlyphDrawing(outline: gear, tone: gear)

        case .power:
            let centre = pt(12, 13.2)
            let ring = Path.build {
                $0.addArc(center: centre, radius: 7.6, startAngle: .degrees(-58), endAngle: .degrees(238), clockwise: false)
                $0.move(to: pt(12, 3.4))
                $0.addLine(to: pt(12, 11.2))
            }
            return GlyphDrawing(outline: ring, tone: Path.build { $0.addCircle(centre, 7.6) })

        case .download:
            let shape = Path.build {
                $0.addLines([pt(12, 3.6), pt(12, 14.2)])
                $0.addLines([pt(7.8, 10.2), pt(12, 14.4), pt(16.2, 10.2)])
                $0.move(to: pt(4, 14.2))
                $0.addArc(tangent1End: pt(4, 20.4), tangent2End: pt(20, 20.4), radius: 3)
                $0.addArc(tangent1End: pt(20, 20.4), tangent2End: pt(20, 14.2), radius: 3)
                $0.addLine(to: pt(20, 14.2))
            }
            return GlyphDrawing(outline: shape)

        case .processor:
            let chip = Path.build {
                $0.addRounded(CGRect(x: 6, y: 6, width: 12, height: 12), 3.2)
                for position in [9.2, 12, 14.8] as [CGFloat] {
                    $0.addLines([pt(position, 2.8), pt(position, 6)])
                    $0.addLines([pt(position, 18), pt(position, 21.2)])
                    $0.addLines([pt(2.8, position), pt(6, position)])
                    $0.addLines([pt(18, position), pt(21.2, position)])
                }
            }
            let body = Path.build { $0.addRounded(CGRect(x: 6, y: 6, width: 12, height: 12), 3.2) }
            let core = Path.build { $0.addRounded(CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8), 1.4) }
            return GlyphDrawing(outline: chip, tone: body, solid: core)

        case .memory:
            let stick = Path.build {
                $0.addRounded(CGRect(x: 2.8, y: 6.6, width: 18.4, height: 9.6), 2.6)
                for position in [6.2, 10.1, 13.9, 17.8] as [CGFloat] {
                    $0.addLines([pt(position, 16.2), pt(position, 19.2)])
                }
            }
            let body = Path.build { $0.addRounded(CGRect(x: 2.8, y: 6.6, width: 18.4, height: 9.6), 2.6) }
            let chips = Path.build {
                for left in [5.4, 10.2, 15.0] as [CGFloat] {
                    $0.addRounded(CGRect(x: left, y: 9.2, width: 3.6, height: 4.4), 1)
                }
            }
            return GlyphDrawing(outline: stick, tone: body, solid: chips)

        case .disk:
            let drive = Path.build {
                $0.addRounded(CGRect(x: 3, y: 5.4, width: 18, height: 13.2), 4)
                $0.addLines([pt(3.6, 11), pt(20.4, 11)])
                $0.addLines([pt(6.8, 14.8), pt(11.2, 14.8)])
            }
            let body = Path.build { $0.addRounded(CGRect(x: 3, y: 5.4, width: 18, height: 13.2), 4) }
            return GlyphDrawing(outline: drive, tone: body, solid: Path.build { $0.addCircle(pt(16.8, 14.8), 1.25) })

        case .network:
            let globe = Path.build {
                $0.addCircle(pt(12, 12), 8.4)
                $0.addEllipse(in: CGRect(x: 8.4, y: 3.6, width: 7.2, height: 16.8))
                $0.addLines([pt(3.8, 12), pt(20.2, 12)])
            }
            return GlyphDrawing(outline: globe, tone: Path.build { $0.addCircle(pt(12, 12), 8.4) })

        case .updates:
            let shape = Path.build {
                $0.addCircle(pt(12, 12), 8.6)
                $0.addLines([pt(12, 7.4), pt(12, 15.8)])
                $0.addLines([pt(8.6, 12.6), pt(12, 16), pt(15.4, 12.6)])
            }
            return GlyphDrawing(outline: shape, tone: Path.build { $0.addCircle(pt(12, 12), 8.6) })

        case .copy:
            let front = Path.build { $0.addRounded(CGRect(x: 3.8, y: 8.2, width: 12, height: 12), 3) }
            let sheets = Path.build {
                $0.addPath(front)
                // The sheet behind shows only where the front one does not cover it.
                $0.move(to: pt(8.2, 8.2))
                $0.addArc(tangent1End: pt(8.2, 3.8), tangent2End: pt(20.2, 3.8), radius: 3)
                $0.addArc(tangent1End: pt(20.2, 3.8), tangent2End: pt(20.2, 15.8), radius: 3)
                $0.addArc(tangent1End: pt(20.2, 15.8), tangent2End: pt(15.8, 15.8), radius: 3)
                $0.addLine(to: pt(15.8, 15.8))
            }
            return GlyphDrawing(outline: sheets, tone: front)

        case .check:
            return GlyphDrawing(outline: Path.build { $0.addLines([pt(5, 12.6), pt(9.8, 17.4), pt(19, 6.8)]) })

        case .open:
            return GlyphDrawing(outline: Path.build {
                $0.addLines([pt(6.8, 17.2), pt(17, 7)])
                $0.addLines([pt(9.4, 7), pt(17, 7), pt(17, 14.6)])
            })

        case .search:
            let lens = Path.build { $0.addCircle(pt(10.6, 10.6), 6.4) }
            let shape = Path.build {
                $0.addPath(lens)
                $0.addLines([pt(15.4, 15.4), pt(20, 20)])
            }
            return GlyphDrawing(outline: shape, tone: lens)

        case .more:
            return GlyphDrawing(solid: Path.build {
                for x in [5.6, 12, 18.4] as [CGFloat] { $0.addCircle(pt(x, 12), 1.7) }
            })

        case .warning:
            let triangle = Path.build { $0.addRoundedPolygon([pt(12, 3.4), pt(21, 19.6), pt(3, 19.6)], radius: 2.6) }
            let shape = Path.build {
                $0.addPath(triangle)
                $0.addLines([pt(12, 9.2), pt(12, 13.4)])
            }
            return GlyphDrawing(outline: shape, tone: triangle, solid: Path.build { $0.addCircle(pt(12, 16.4), 1.15) })

        case .close:
            return GlyphDrawing(outline: Path.build {
                $0.addLines([pt(6.5, 6.5), pt(17.5, 17.5)])
                $0.addLines([pt(17.5, 6.5), pt(6.5, 17.5)])
            })

        case .trash:
            let bin = Path.build { $0.addRoundedPolygon([pt(5.6, 6.6), pt(18.4, 6.6), pt(17.2, 20.4), pt(6.8, 20.4)], radius: 2.4) }
            let shape = Path.build {
                $0.addPath(bin)
                $0.addLines([pt(3.8, 6.6), pt(20.2, 6.6)])
                $0.move(to: pt(9.2, 6.6))
                $0.addArc(tangent1End: pt(9.2, 3.6), tangent2End: pt(14.8, 3.6), radius: 1.6)
                $0.addArc(tangent1End: pt(14.8, 3.6), tangent2End: pt(14.8, 6.6), radius: 1.6)
                $0.addLine(to: pt(14.8, 6.6))
                $0.addLines([pt(10.2, 10.4), pt(10.2, 16.6)])
                $0.addLines([pt(13.8, 10.4), pt(13.8, 16.6)])
            }
            return GlyphDrawing(outline: shape, tone: bin)

        case .chevronRight:
            return GlyphDrawing(outline: Path.build { $0.addLines([pt(9.2, 5.2), pt(15.8, 12), pt(9.2, 18.8)]) })

        case .package:
            let box = Path.build {
                $0.addRoundedPolygon(
                    [pt(12, 2.8), pt(20.4, 7.4), pt(20.4, 16.6), pt(12, 21.2), pt(3.6, 16.6), pt(3.6, 7.4)],
                    radius: 2.2
                )
            }
            let shape = Path.build {
                $0.addPath(box)
                $0.addLines([pt(3.9, 7.6), pt(12, 12), pt(20.1, 7.6)])
                $0.addLines([pt(12, 12), pt(12, 20.9)])
            }
            return GlyphDrawing(outline: shape, tone: box)

        case .plus:
            return GlyphDrawing(outline: Path.build {
                $0.addLines([pt(12, 5.5), pt(12, 18.5)])
                $0.addLines([pt(5.5, 12), pt(18.5, 12)])
            })
        }
    }
}

/// Draws a glyph at a size, in the current foreground style.
struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 18
    /// A stronger inner tone, for the chosen item or a switched-on control.
    var emphasis = false

    var body: some View {
        let drawing = glyph.drawing
        let scale = CGAffineTransform(scaleX: size / 24, y: size / 24)
        ZStack {
            if let tone = drawing.tone {
                tone.applying(scale)
                    .fill(ForegroundStyle().opacity(emphasis ? 0.34 : 0.14), style: FillStyle(eoFill: true))
            }
            drawing.outline.applying(scale)
                .stroke(ForegroundStyle(), style: StrokeStyle(lineWidth: max(1.3, size * 0.075), lineCap: .round, lineJoin: .round))
            if let solid = drawing.solid {
                solid.applying(scale).fill(ForegroundStyle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Glyphs as template images, for the places that only take an image: menu
/// labels and the menu bar. The system tints a template image to match.
@MainActor
enum GlyphImage {
    private static var cache: [String: NSImage] = [:]

    static func template(_ glyph: Glyph, size: CGFloat, emphasis: Bool = false) -> NSImage {
        let key = "\(glyph)-\(size)-\(emphasis)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: GlyphView(glyph: glyph, size: size, emphasis: emphasis).foregroundStyle(.black))
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            preconditionFailure("The \(glyph) glyph could not be drawn into an image.")
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}
