import AppKit
import PDFKit

/// Decode the actual iOS annotation formats, not PDF body text/images. Unknown
/// or damaged metadata remains in the source PDF, never silently discarded.
extension MacPDFEditorState {
    func importEditableAnnotations() {
        var imported = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let replacements = annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "ink" ? MacPDFAnnotationImport.standardInk(annotation, page: index) : MacPDFAnnotationImport.objects(contents: annotation.contents ?? "", page: index, fallbackColor: annotation.color)
                guard !replacements.isEmpty else { continue }
                objects.append(contentsOf: replacements); page.removeAnnotation(annotation); imported = true
                for object in replacements where object.kind == .text {
                    page.annotations.filter { $0.userName == "NF Editable Text Link \(object.id.uuidString)" }.forEach(page.removeAnnotation)
                }
            }
        }
        if imported { markImportedAnnotationsChanged() }
    }
}

enum MacPDFAnnotationImport {
    static func standardInk(_ annotation: PDFAnnotation, page: Int) -> [MacPDFObject] {
        var style = MacPDFStyle(); style.stroke = .init(annotation.color); style.width = max(0.3, annotation.border?.lineWidth ?? 2)
        var result: [MacPDFObject] = []
        for path in annotation.paths ?? [] {
            var points: [MacPDFPoint] = [], prior = CGPoint.zero
            func append(_ point: CGPoint) { points.append(MacPDFPoint(CGPoint(x: point.x + annotation.bounds.minX, y: point.y + annotation.bounds.minY))) }
            for i in 0..<path.elementCount {
                var p = [CGPoint](repeating: .zero, count: 3)
                let element = p.withUnsafeMutableBufferPointer { path.element(at: i, associatedPoints: $0.baseAddress!) }
                switch element {
                case .moveTo, .lineTo: append(p[0]); prior = p[0]
                case .curveTo, .cubicCurveTo:
                    let initial = prior
                    for sample in 1...20 {
                        let t = CGFloat(sample) / 20, u = 1 - t
                        append(CGPoint(x: u*u*u*initial.x + 3*u*u*t*p[0].x + 3*u*t*t*p[1].x + t*t*t*p[2].x, y: u*u*u*initial.y + 3*u*u*t*p[0].y + 3*u*t*t*p[1].y + t*t*t*p[2].y))
                    }; prior = p[2]
                case .quadraticCurveTo:
                    let initial = prior
                    for sample in 1...20 { let t = CGFloat(sample) / 20, u = 1 - t; append(CGPoint(x: u*u*initial.x + 2*u*t*p[0].x + t*t*p[1].x, y: u*u*initial.y + 2*u*t*p[0].y + t*t*p[1].y)) }; prior = p[1]
                case .closePath: break
                @unknown default: return []
                }
            }
            if !points.isEmpty {
                let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 0.1, height: 0.1))) }.insetBy(dx: -style.width, dy: -style.width)
                result.append(MacPDFObject(page: page, kind: .ink, bounds: bounds, style: style, points: points))
            }
        }
        return result
    }
    private struct Text: Decodable {
        let id: UUID, text: String, bounds: CGRect, fontName: String, fontSize: Double
        let textColorRGBA: [Double], fillColorRGBA: [Double], borderColorRGBA: [Double]
        let isBold: Bool, isItalic: Bool, isUnderlined: Bool, isStruckThrough: Bool
        let alignmentRawValue: Int, linkURL: String?, attributedTextRTF: Data?
    }
    private struct Image: Decodable { let imageData: Data, bounds: CGRect, rotationAngle: Double, isHorizontallyFlipped: Bool }
    private struct Shape: Decodable { let shapeType: String, bounds: CGRect, lineWidth: Double, lineColorRGBA: [Double], fillColorRGBA: [Double], rotationAngle: Double }
    private struct Stroke: Decodable { let points: [[Double]], pressures: [Double] }
    private struct Ink: Decodable { let points: [[Double]], pressures: [Double], baseLineWidth: Double, colorRGBA: [Double]? }
    private struct Group: Decodable { let strokes: [Stroke], baseLineWidth: Double, colorRGBA: [Double]? }
    private static func color(_ values: [Double]?, fallback: NSColor) -> MacPDFRGBA {
        guard let values, values.count == 4, values.allSatisfy({ $0.isFinite }) else { return .init(fallback) }
        return .init(NSColor(deviceRed: values[0], green: values[1], blue: values[2], alpha: values[3]))
    }
    static func objects(contents: String, page: Int, fallbackColor: NSColor) -> [MacPDFObject] {
        let prefixes = ["NF_EDITABLE_TEXT_V1:", "NF_EDITABLE_IMAGE_V1:", "NF_EDITABLE_SHAPE_V1:", "NF_PRESSURE_INK_V1:", "NF_PRESSURE_INK_V2:", "NF_PRESSURE_INK_V3:"]
        guard let prefix = prefixes.first(where: contents.hasPrefix), let data = Data(base64Encoded: String(contents.dropFirst(prefix.count))), data.count <= 100_000_000 else { return [] }
        let decoder = JSONDecoder()
        if prefix == prefixes[0], let m = try? decoder.decode(Text.self, from: data), valid(m.bounds) {
            var style = MacPDFStyle(); style.fontName = m.fontName; style.fontSize = max(6, min(144, m.fontSize)); style.stroke = color(m.textColorRGBA, fallback: .black); style.fill = color(m.fillColorRGBA, fallback: .clear)
            style.textBorder = color(m.borderColorRGBA, fallback: .clear); style.width = 1; style.bold = m.isBold; style.italic = m.isItalic; style.underline = m.isUnderlined; style.strike = m.isStruckThrough; style.alignment = m.alignmentRawValue
            var object = MacPDFObject(page: page, kind: .text, bounds: m.bounds, style: style, text: m.text, textRTF: m.attributedTextRTF, link: m.linkURL); object.id = m.id
            return [object]
        }
        if prefix == prefixes[1], let m = try? decoder.decode(Image.self, from: data), valid(m.bounds), NSImage(data: m.imageData) != nil {
            return [MacPDFObject(page: page, kind: .image, bounds: m.bounds, imageData: m.imageData, originalImageData: m.imageData, rotation: m.rotationAngle, flipped: m.isHorizontallyFlipped)]
        }
        if prefix == prefixes[2], let m = try? decoder.decode(Shape.self, from: data), valid(m.bounds), let shape = MacPDFShape(rawValue: m.shapeType) {
            var style = MacPDFStyle(); style.width = m.lineWidth; style.stroke = color(m.lineColorRGBA, fallback: fallbackColor); style.fill = color(m.fillColorRGBA, fallback: .clear)
            return [MacPDFObject(page: page, kind: .shape, bounds: m.bounds, style: style, shape: shape, rotation: m.rotationAngle)]
        }
        if prefix == prefixes[3], let m = try? decoder.decode(Ink.self, from: data) { return strokes([Stroke(points: m.points, pressures: m.pressures)], width: m.baseLineWidth, rgba: m.colorRGBA, fallback: fallbackColor, page: page) }
        if prefix == prefixes[4], let m = try? decoder.decode(Group.self, from: data) { return strokes(m.strokes, width: m.baseLineWidth, rgba: m.colorRGBA, fallback: fallbackColor, page: page) }
        if prefix == prefixes[5] { return compact(data, fallback: fallbackColor, page: page) }
        return []
    }
    private static func valid(_ rect: CGRect) -> Bool { [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0 }
    private static func strokes(_ strokes: [Stroke], width: Double, rgba: [Double]?, fallback: NSColor, page: Int) -> [MacPDFObject] {
        guard width.isFinite, width > 0, strokes.allSatisfy({ !$0.points.isEmpty && $0.points.count == $0.pressures.count && $0.points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) && $0.pressures.allSatisfy(\.isFinite) }) else { return [] }
        var style = MacPDFStyle(); style.width = width; style.stroke = color(rgba, fallback: fallback); style.pressure = true
        return strokes.map { stroke in
            let points = zip(stroke.points, stroke.pressures).map { MacPDFPoint(CGPoint(x: $0.0[0], y: $0.0[1]), pressure: $0.1) }
            let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 0.1, height: 0.1))) }.insetBy(dx: -width, dy: -width)
            return MacPDFObject(page: page, kind: .ink, bounds: bounds, style: style, points: points)
        }
    }
    private struct Reader {
        let data: Data; var offset = 0
        mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= data.count else { return nil }
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
    }
    private static func compact(_ data: Data, fallback: NSColor, page: Int) -> [MacPDFObject] {
        var reader = Reader(data: data)
        guard reader.read(UInt8.self) == 1, let flags = reader.read(UInt8.self), let count = reader.read(UInt16.self), let width = reader.read(UInt32.self) else { return [] }
        var rgba: [Double]?
        if flags & 1 == 1 {
            guard let r = reader.read(UInt16.self), let g = reader.read(UInt16.self), let b = reader.read(UInt16.self), let a = reader.read(UInt16.self) else { return [] }
            rgba = [r, g, b, a].map { Double($0) / 65535 }
        }
        var result: [Stroke] = []
        for _ in 0..<count {
            guard let pointCount = reader.read(UInt32.self), pointCount > 0, pointCount <= 1_000_000, Int(pointCount) <= (data.count - reader.offset) / 10 else { return [] }
            var points: [[Double]] = [], pressures: [Double] = [], x: Int64 = 0, y: Int64 = 0
            for i in 0..<pointCount {
                guard let dx = reader.read(Int32.self), let dy = reader.read(Int32.self), let p = reader.read(UInt16.self) else { return [] }
                x = i == 0 ? Int64(dx) : x + Int64(dx); y = i == 0 ? Int64(dy) : y + Int64(dy)
                points.append([Double(x) / 100, Double(y) / 100]); pressures.append(Double(p) / 65535)
            }
            result.append(Stroke(points: points, pressures: pressures))
        }
        return strokes(result, width: Double(Float32(bitPattern: width)), rgba: rgba, fallback: fallback, page: page)
    }
}
