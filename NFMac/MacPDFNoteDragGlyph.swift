import SwiftUI

struct MacPDFNoteDragGlyph: Shape {
    let indicator: PDFNoteDragIndicator?

    var octant: Int {
        guard let offset = indicator?.heading, offset != .zero else { return 7 }
        let angle = atan2(offset.height, offset.width)
        return (Int((angle / (.pi / 4)).rounded()) + 8) % 8
    }

    func path(in rect: CGRect) -> Path {
        let diagonal = !octant.isMultiple(of: 2)
        let zoom = indicator?.kind != .move
        let turns = diagonal ? ((octant + 1) / 2) % 4 : octant / 2
        var glyph = Path()
        if diagonal {
            glyph.move(to: CGPoint(x: 13, y: 3))
            glyph.addLine(to: CGPoint(x: 6, y: 3))
            glyph.addQuadCurve(to: CGPoint(x: 3, y: 6), control: CGPoint(x: 3, y: 3))
            glyph.addLine(to: CGPoint(x: 3, y: 18))
            glyph.addQuadCurve(to: CGPoint(x: 6, y: 21), control: CGPoint(x: 3, y: 21))
            glyph.addLine(to: CGPoint(x: 18, y: 21))
            glyph.addQuadCurve(to: CGPoint(x: 21, y: 18), control: CGPoint(x: 21, y: 21))
            glyph.addLine(to: CGPoint(x: 21, y: 11))
            glyph.move(to: CGPoint(x: 9, y: 15))
            glyph.addLine(to: CGPoint(x: 21, y: 3))
            glyph.move(to: CGPoint(x: 16, y: 3))
            glyph.addLine(to: CGPoint(x: 21, y: 3))
            glyph.addLine(to: CGPoint(x: 21, y: 8))
            if zoom {
                glyph.move(to: CGPoint(x: 9, y: 10))
                glyph.addLine(to: CGPoint(x: 9, y: 15))
                glyph.addLine(to: CGPoint(x: 14, y: 15))
            }
        } else {
            glyph.addRoundedRect(in: CGRect(x: 3, y: 3, width: 15, height: 18), cornerSize: CGSize(width: 3, height: 3))
            glyph.move(to: CGPoint(x: 8, y: 12))
            glyph.addLine(to: CGPoint(x: 22, y: 12))
            glyph.move(to: CGPoint(x: 17, y: 7))
            glyph.addLine(to: CGPoint(x: 22, y: 12))
            glyph.addLine(to: CGPoint(x: 17, y: 17))
            if zoom {
                glyph.move(to: CGPoint(x: 12, y: 8))
                glyph.addLine(to: CGPoint(x: 8, y: 12))
                glyph.addLine(to: CGPoint(x: 12, y: 16))
            }
        }
        let transform = CGAffineTransform(translationX: -12, y: -12)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
            .concatenating(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return glyph.applying(transform)
    }
}
