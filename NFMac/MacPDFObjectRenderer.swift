import AppKit
import CoreText
import PDFKit

enum MacPDFObjectRenderer {
    static func corners(_ object: MacPDFObject) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { anchor(object, MacPDFPoint($0)) }
    }
    static func anchor(_ object: MacPDFObject, _ normalized: MacPDFPoint) -> CGPoint {
        let center = CGPoint(x: object.bounds.midX, y: object.bounds.midY)
        let x = object.bounds.minX + object.bounds.width * normalized.x - center.x
        let y = object.bounds.minY + object.bounds.height * normalized.y - center.y
        return CGPoint(x: center.x + x * cos(object.rotation) - y * sin(object.rotation), y: center.y + x * sin(object.rotation) + y * cos(object.rotation))
    }
    static func endpoints(_ connector: MacPDFObject, objects: [MacPDFObject]) -> (CGPoint, CGPoint)? {
        guard let source = objects.first(where: { $0.id == connector.sourceID && $0.page == connector.page }),
              let target = objects.first(where: { $0.id == connector.targetID && $0.page == connector.page }) else { return nil }
        return (anchor(source, connector.sourceAnchor), anchor(target, connector.targetAnchor))
    }
    static func connectorPath(_ object: MacPDFObject, objects: [MacPDFObject]) -> CGPath? {
        guard let (a, b) = endpoints(object, objects: objects) else { return nil }
        let control = object.connectorOffset.map { CGPoint(x: (a.x + b.x) / 2 + CGFloat($0.x), y: (a.y + b.y) / 2 + CGFloat($0.y)) }
        return connectionPath(from: a, to: b, route: object.style.connectorRoute, control: control)
    }
    static func connectorControlPoint(_ object: MacPDFObject, objects: [MacPDFObject]) -> CGPoint? {
        guard let (a, b) = endpoints(object, objects: objects) else { return nil }
        return CGPoint(x: (a.x + b.x) / 2 + CGFloat(object.connectorOffset?.x ?? 0), y: (a.y + b.y) / 2 + CGFloat(object.connectorOffset?.y ?? 0))
    }
    static func connectionPath(from a: CGPoint, to b: CGPoint, route: String, control: CGPoint? = nil) -> CGPath {
        let path = CGMutablePath(); path.move(to: a)
        if let c = control {
            switch route {
            case "elbow":
                // Both coordinates of the middle grip can move, without ever
                // detaching either endpoint or turning orthogonal legs diagonal.
                path.addLine(to: CGPoint(x: c.x, y: a.y)); path.addLine(to: c)
                path.addLine(to: CGPoint(x: b.x, y: c.y)); path.addLine(to: b)
            case "curve":
                // Quadratic control chosen so t=0.5 passes through the grip.
                path.addQuadCurve(to: b, control: CGPoint(x: 2 * c.x - (a.x + b.x) / 2, y: 2 * c.y - (a.y + b.y) / 2))
            default: path.addLine(to: c); path.addLine(to: b)
            }
            return path
        }
        switch route {
        case "elbow": path.addLine(to: CGPoint(x: (a.x + b.x) / 2, y: a.y)); path.addLine(to: CGPoint(x: (a.x + b.x) / 2, y: b.y)); path.addLine(to: b)
        case "curve": path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
        default: path.addLine(to: b)
        }
        return path
    }
    static func connectorArrowPrevious(_ object: MacPDFObject, objects: [MacPDFObject]) -> CGPoint? {
        guard let (a, b) = endpoints(object, objects: objects) else { return nil }
        if object.connectorOffset != nil, let c = connectorControlPoint(object, objects: objects) {
            switch object.style.connectorRoute {
            case "elbow": return abs(c.y - b.y) > 0.001 ? CGPoint(x: b.x, y: c.y) : c
            case "curve": return CGPoint(x: 2 * c.x - (a.x + b.x) / 2, y: 2 * c.y - (a.y + b.y) / 2)
            default: return c
            }
        }
        let prior = object.style.connectorRoute == "straight" ? a : CGPoint(x: (a.x + b.x) / 2, y: b.y)
        return hypot(prior.x - b.x, prior.y - b.y) > 0.001 ? prior : a
    }
    static func shapePath(_ type: MacPDFShape, bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y) }
        func polygon(_ points: [(Double, Double)]) { guard let first = points.first else { return }; path.move(to: point(first.0, first.1)); for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }; path.closeSubpath() }
        switch type {
        case .rectangle: path.addRect(bounds)
        case .roundedRectangle: path.addRoundedRect(in: bounds, cornerWidth: min(bounds.width, bounds.height) * 0.16, cornerHeight: min(bounds.width, bounds.height) * 0.16)
        case .circle: path.addEllipse(in: bounds)
        case .triangle: polygon([(0.5, 1), (0, 0), (1, 0)])
        case .hexagon: polygon([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case .diamond: polygon([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case .rightArrow: polygon([(0, 0.3), (0.6, 0.3), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.7), (0, 0.7)])
        case .diagonalArrow: polygon([(0.4, 1), (1, 1), (1, 0.4), (0.8, 0.6), (0.2, 0), (0, 0.2), (0.6, 0.8)])
        case .star: polygon((0..<10).map { i in let a = Double.pi / 2 + Double(i) * Double.pi / 5; let r = i.isMultiple(of: 2) ? 0.5 : 0.22; return (0.5 + r * cos(a), 0.5 + r * sin(a)) })
        case .speechBubble:
            path.addRoundedRect(in: CGRect(x: bounds.minX, y: bounds.minY + bounds.height * 0.2, width: bounds.width, height: bounds.height * 0.8), cornerWidth: min(bounds.width, bounds.height) * 0.15, cornerHeight: min(bounds.width, bounds.height) * 0.15)
            polygon([(0.2, 0.25), (0.15, 0), (0.5, 0.25)])
        }
        return path
    }
    static func draw(_ object: MacPDFObject, objects: [MacPDFObject], context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        let style = object.style
        context.setStrokeColor(style.stroke.color.cgColor); context.setFillColor(style.fill.color.cgColor)
        context.setLineWidth(style.width); context.setLineCap(style.roundCap ? .round : .butt); context.setLineJoin(.round)
        if style.dashed { context.setLineDash(phase: 0, lengths: [style.width * 3, style.width * 2]) }
        if object.kind != .ink && object.kind != .connector {
            context.translateBy(x: object.bounds.midX, y: object.bounds.midY); context.rotate(by: object.rotation)
            context.translateBy(x: -object.bounds.midX, y: -object.bounds.midY)
        }
        switch object.kind {
        case .ink:
            context.setStrokeColor(style.stroke.color.cgColor)
            if object.isTransient, let first = object.points.first {
                let path = CGMutablePath(); path.move(to: first.cgPoint); object.points.dropFirst().forEach { path.addLine(to: $0.cgPoint) }
                if object.neonType == .arrow, let end = object.points.last {
                    let distance = hypot(end.x - first.x, end.y - first.y)
                    if distance > 0.01 {
                        let angle = atan2(end.y - first.y, end.x - first.x), length = min(distance * 0.45, max(12, style.width * 5))
                        path.move(to: CGPoint(x: end.x - length * cos(angle - 0.45), y: end.y - length * sin(angle - 0.45)))
                        path.addLine(to: end.cgPoint)
                        path.addLine(to: CGPoint(x: end.x - length * cos(angle + 0.45), y: end.y - length * sin(angle + 0.45)))
                    }
                }
                for (multiplier, opacity) in [(5.2, 0.24), (2.6, 0.64), (1.0, 1.0)] {
                    context.saveGState(); context.setLineWidth(max(0.5, style.width * multiplier)); context.setLineCap(.round)
                    if multiplier == 5.2 { context.setShadow(offset: .zero, blur: max(6, style.width * 2.8), color: style.stroke.color.cgColor) }
                    let color = multiplier == 1 ? NSColor(deviceRed: style.stroke.r * 0.28 + 0.72, green: style.stroke.g * 0.28 + 0.72, blue: style.stroke.b * 0.28 + 0.72, alpha: 1) : style.stroke.color.withAlphaComponent(opacity)
                    context.setStrokeColor(color.cgColor); context.addPath(path); context.strokePath(); context.restoreGState()
                }
                return
            }
            if object.points.count == 1, let p = object.points.first { context.setFillColor(style.stroke.color.cgColor); context.fillEllipse(in: CGRect(x: p.x - style.width / 2, y: p.y - style.width / 2, width: style.width, height: style.width)) }
            if !style.pressure, let first = object.points.first {
                context.move(to: first.cgPoint); for point in object.points.dropFirst() { context.addLine(to: point.cgPoint) }; context.strokePath()
                return
            }
            for i in 1..<max(1, object.points.count) {
                let a = object.points[i - 1], b = object.points[i]
                context.setLineWidth(style.pressure ? style.width * max(0.12, (a.pressure + b.pressure) / 2 * style.pressureStrength) : style.width)
                context.move(to: a.cgPoint); context.addLine(to: b.cgPoint); context.strokePath()
            }
        case .shape:
            context.addPath(shapePath(object.shape, bounds: object.bounds)); context.drawPath(using: .fillStroke)
        case .text:
            context.fill(object.bounds); context.setStrokeColor((style.textBorder?.color ?? .clear).cgColor); if style.width > 0 { context.stroke(object.bounds) }
            let font = NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
            let manager = NSFontManager.shared
            var traits: NSFontTraitMask = []
            if style.bold { traits.insert(.boldFontMask) }; if style.italic { traits.insert(.italicFontMask) }
            let chosen = manager.convert(font, toHaveTrait: traits)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = NSTextAlignment(rawValue: style.alignment) ?? .left
            let attributes: [NSAttributedString.Key: Any] = [.font: chosen, .foregroundColor: style.stroke.color, .paragraphStyle: paragraph, .underlineStyle: style.underline ? 1 : 0, .strikethroughStyle: style.strike ? 1 : 0]
            let attributed = object.textRTF.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
                ?? NSAttributedString(string: object.text, attributes: attributes)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: object.bounds.insetBy(dx: 4, dy: 4), transform: nil), nil)
            context.textMatrix = .identity; CTFrameDraw(frame, context)
        case .image:
            guard let data = object.imageData, let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            if object.flipped { context.translateBy(x: object.bounds.midX * 2, y: 0); context.scaleBy(x: -1, y: 1) }
            var imageBounds = object.bounds
            if object.attachmentName != nil { imageBounds.origin.y += 24; imageBounds.size.height -= 24 }
            context.draw(cgImage, in: imageBounds)
            if let name = object.attachmentName {
                let text = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
                let path = CGPath(rect: CGRect(x: object.bounds.minX + 4, y: object.bounds.minY + 2, width: object.bounds.width - 8, height: 20), transform: nil)
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: object.bounds.minX, y: object.bounds.minY, width: object.bounds.width, height: 24))
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0), path, nil), context)
            }
        case .connector:
            guard let path = connectorPath(object, objects: objects), let (a, b) = endpoints(object, objects: objects) else { return }
            context.addPath(path); context.strokePath()
            if style.arrow {
                let previous = connectorArrowPrevious(object, objects: objects) ?? a
                let angle = atan2(b.y - previous.y, b.x - previous.x), length = max(9, style.width * 4)
                context.setLineDash(phase: 0, lengths: []); context.move(to: CGPoint(x: b.x - length * cos(angle - 0.45), y: b.y - length * sin(angle - 0.45))); context.addLine(to: b); context.addLine(to: CGPoint(x: b.x - length * cos(angle + 0.45), y: b.y - length * sin(angle + 0.45))); context.strokePath()
            }
        }
    }
}

final class MacPDFObjectAnnotation: PDFAnnotation {
    var object: MacPDFObject
    var allObjects: [MacPDFObject]
    var selected = false
    var scale: CGFloat = 1
    init(object: MacPDFObject, objects: [MacPDFObject], pageBounds: CGRect) {
        self.object = object; allObjects = objects
        // A page-sized connector drawing area keeps attached endpoints unclipped.
        super.init(bounds: pageBounds, forType: .stamp, withProperties: nil)
        // PDFKit may use the annotation color alpha for its screen layer even
        // with a custom draw implementation. Keep that layer visible; individual
        // object stroke/fill opacity is handled by our renderer.
        color = .systemBlue; shouldDisplay = true; shouldPrint = true
    }
    required init?(coder: NSCoder) { fatalError("Mac PDF objects are restored from the edit archive") }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        MacPDFObjectRenderer.draw(object, objects: allObjects, context: context)
        guard selected else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(NSColor.systemBlue.cgColor); context.setLineWidth(1 / max(scale, 0.1)); context.setLineDash(phase: 0, lengths: [4 / max(scale, 0.1), 3 / max(scale, 0.1)])
        if object.kind == .connector, let path = MacPDFObjectRenderer.connectorPath(object, objects: allObjects) { context.addPath(path); context.strokePath(); return }
        if object.kind != .ink {
            context.translateBy(x: object.bounds.midX, y: object.bounds.midY); context.rotate(by: object.rotation); context.translateBy(x: -object.bounds.midX, y: -object.bounds.midY)
        }
        context.stroke(object.bounds.insetBy(dx: -3 / scale, dy: -3 / scale)); context.setLineDash(phase: 0, lengths: [])
        for point in MacPDFEditingView.corners(object.bounds) {
            let side = 7 / max(scale, 0.1); context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)); context.stroke(CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        }
    }
}
