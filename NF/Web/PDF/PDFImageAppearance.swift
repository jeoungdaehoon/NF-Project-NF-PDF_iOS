import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
typealias PDFImagePlatformColor = NSColor
private typealias PDFImagePlatformFont = NSFont
#else
import UIKit
typealias PDFImagePlatformColor = UIColor
private typealias PDFImagePlatformFont = UIFont
#endif

struct PDFImageRGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ color: PDFImagePlatformColor) {
        #if os(macOS)
        let rgba = color.usingColorSpace(.deviceRGB) ?? .black
        r = rgba.redComponent; g = rgba.greenComponent; b = rgba.blueComponent; a = rgba.alphaComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        r = red; g = green; b = blue; a = alpha
        #endif
    }

    var color: PDFImagePlatformColor { .init(red: r, green: g, blue: b, alpha: a) }
}

struct PDFImageAppearance: Codable, Equatable {
    enum Border: String, Codable, CaseIterable {
        case none, line, frame
        var title: String {
            switch self { case .none: "테두리 없음"; case .line: "선"; case .frame: "액자" }
        }
    }

    enum Line: String, Codable, CaseIterable {
        case solid, shortDash, dash, longDash, dot, pencil, marker, beveled, dryBrush, wavy

        var title: String {
            switch self {
            case .solid: "실선"
            case .shortDash: "짧은 점선"
            case .dash: "점선"
            case .longDash: "긴 점선"
            case .dot: "둥근 점선"
            case .pencil: "연필"
            case .marker: "마커"
            case .beveled: "사선 끝"
            case .dryBrush: "마른 붓"
            case .wavy: "물결"
            }
        }

        func stroke(_ points: [CGPoint], closed: Bool = false, width: CGFloat, color: PDFImagePlatformColor, in context: CGContext) {
            guard points.count > 1 else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.setStrokeColor(color.cgColor)
            context.setLineCap(.butt)
            context.setLineJoin(.round)
            context.setLineWidth(width)
            context.setLineDash(phase: 0, lengths: [])

            func drawPath(_ path: [CGPoint], closed: Bool) {
                context.beginPath()
                context.addLines(between: path)
                if closed { context.closePath() }
                context.strokePath()
            }

            switch self {
            case .shortDash: context.setLineDash(phase: 0, lengths: [width, width])
            case .dash: context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
            case .longDash: context.setLineDash(phase: 0, lengths: [width * 7, width * 3])
            case .dot:
                context.setLineCap(.round)
                context.setLineDash(phase: 0, lengths: [0, width * 2.8])
            case .marker:
                context.setLineCap(.round)
                context.setLineWidth(width * 1.5)
                context.setStrokeColor(color.withAlphaComponent(color.cgColor.alpha * 0.75).cgColor)
            case .pencil, .dryBrush:
                let dry = self == .dryBrush
                context.setLineWidth(width * 0.42)
                context.setStrokeColor(color.withAlphaComponent(color.cgColor.alpha * 0.8).cgColor)
                for (index, offset) in [-0.32, 0, 0.32].enumerated() {
                    context.setLineDash(phase: CGFloat(index) * width, lengths: dry
                        ? [width * 3, width * 0.8, width * 1.2, width * 0.5]
                        : [width * 0.8, width * 0.25, width * 1.5, width * 0.3])
                    drawPath(points.map { CGPoint(x: $0.x + offset * width, y: $0.y + offset * width) }, closed: closed)
                }
                return
            case .beveled, .wavy:
                let ends = closed ? points + [points[0]] : points
                for (start, end) in zip(ends, ends.dropFirst()) {
                    let dx = end.x - start.x, dy = end.y - start.y
                    let length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    let ux = dx / length, uy = dy / length
                    func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                        CGPoint(x: start.x + ux * along - uy * across, y: start.y + uy * along + ux * across)
                    }
                    if self == .beveled {
                        let slope = min(width, length / 3)
                        context.setFillColor(color.cgColor)
                        context.beginPath()
                        context.addLines(between: [point(0, -width / 2), point(slope, width / 2),
                                                   point(length, width / 2), point(length - slope, -width / 2)])
                        context.closePath()
                        context.fillPath()
                    } else {
                        let steps = Int(min(512, max(2, ceil(length / max(1, width)))))
                        let waves = max(1, (length / max(6, 6 * width)).rounded())
                        let path = (0...steps).map { index -> CGPoint in
                            let fraction = CGFloat(index) / CGFloat(steps)
                            return point(fraction * length, sin(fraction * waves * 2 * .pi) * width * 0.35)
                        }
                        drawPath(path, closed: false)
                    }
                }
                return
            case .solid: break
            }
            drawPath(points, closed: closed)
        }
    }

    enum Shadow: String, Codable, CaseIterable {
        case none, drop, contact, raised
        var title: String {
            switch self { case .none: "그림자 없음"; case .drop: "기본 그림자"; case .contact: "바닥 그림자"; case .raised: "띄운 그림자" }
        }

        func apply(in context: CGContext) {
            let offset: CGSize, blur: CGFloat
            switch self {
            case .none: return
            case .drop: offset = CGSize(width: 4, height: -5); blur = 6
            case .contact: offset = CGSize(width: 0, height: -2); blur = 3
            case .raised: offset = CGSize(width: 0, height: -9); blur = 12
            }
            context.setShadow(offset: offset, blur: blur, color: PDFImagePlatformColor.black.withAlphaComponent(0.42).cgColor)
        }
    }

    enum TitlePosition: String, Codable, CaseIterable {
        case top, bottom
        var title: String { self == .top ? "상단" : "하단" }
    }

    struct BackgroundRemoval: Codable, Equatable {
        var tolerance: Double = 20
        var strength: Double = 100
    }

    var border = Border.none
    var line = Line.solid
    var borderColor = PDFImageRGBA(.black)
    var borderWidth: Double = 1
    var shadow = Shadow.none
    var reflection = false
    var opacity: Double = 100
    var showsTitle = false
    var title = ""
    var titlePosition = TitlePosition.top
    var backgroundRemoval: BackgroundRemoval?

    func extendedBounds(_ bounds: CGRect) -> CGRect {
        let width = border == .none ? 0 : max(0.25, min(24, borderWidth))
        let edge = border == .frame ? width * 2.8 : width
        let shadowMargin: CGFloat = shadow == .none ? 0 : 38
        let hasTitle = showsTitle && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let reflectionMargin = reflection ? 3 + min(80, bounds.height * 0.28) : 0
        return bounds.insetBy(dx: -max(edge, shadowMargin),
                              dy: -max(shadowMargin, edge + reflectionMargin + (hasTitle ? 21 : 0)))
    }

    func raster(_ image: CGImage, in bounds: CGRect, flipped: Bool, limit: CGFloat = 2048) -> CGImage? {
        let frame = extendedBounds(bounds)
        guard frame.width.isFinite, frame.height.isFinite, !frame.isEmpty else { return nil }
        let scale = min(max(2, CGFloat(image.width) / max(1, bounds.width)), limit / max(frame.width, frame.height))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: Int(ceil(frame.width * scale)), height: Int(ceil(frame.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        let source = backgroundRemoval.map { PDFImageBackgroundRemoval.apply($0, to: image) } ?? image
        draw(source, in: bounds, flipped: flipped, attachmentName: nil, context: context)
        return context.makeImage()
    }

    static func snappedRotation(_ angle: Double) -> Double {
        let revolution = 2 * Double.pi
        let base = floor(angle / revolution) * revolution
        return [base, base + .pi / 2, base + .pi, base + revolution]
            .first { abs(angle - $0) <= .pi / 36 } ?? angle
    }

    private static let reflectionMask: CGImage? = {
        // Quartz image masks sample black as opaque. Fade from top to bottom.
        let fade = Data((0..<64).map { UInt8($0 * 255 / 63) })
        guard let provider = CGDataProvider(data: fade as CFData) else { return nil }
        return CGImage(maskWidth: 1, height: 64, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: 1, provider: provider, decode: nil, shouldInterpolate: true)
    }()

    func draw(_ image: CGImage, in bounds: CGRect, flipped: Bool, attachmentName: String?, context: CGContext) {
        let alpha = min(1, max(0, opacity / 100))
        guard alpha > 0, !bounds.isEmpty else { return }
        context.saveGState()
        if alpha < 1 {
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if alpha < 1 { context.endTransparencyLayer() }
            context.restoreGState()
        }
        let captionHeight: CGFloat = attachmentName == nil ? 0 : min(24, max(0, bounds.height - 1))
        let imageBounds = CGRect(x: bounds.minX, y: bounds.minY + captionHeight,
                                 width: bounds.width, height: bounds.height - captionHeight)
        let titleText = showsTitle ? title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let width = border == .none ? 0 : max(0.25, min(24, borderWidth))
        let expansion = border == .frame ? width * 2 : width / 2

        func drawImage(in rect: CGRect) {
            context.saveGState()
            if flipped {
                context.translateBy(x: rect.midX * 2, y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            context.draw(image, in: rect)
            context.restoreGState()
        }

        if reflection, let mask = Self.reflectionMask {
            let titleGap: CGFloat = !titleText.isEmpty && titlePosition == .bottom ? 18 : 0
            let top = bounds.minY - 3 - expansion - titleGap
            let height = min(80, imageBounds.height * 0.28)
            context.saveGState()
            context.clip(to: CGRect(x: imageBounds.minX, y: top - height, width: imageBounds.width, height: height), mask: mask)
            context.setAlpha(0.36)
            context.translateBy(x: 0, y: top * 2)
            context.scaleBy(x: 1, y: -1)
            drawImage(in: CGRect(x: imageBounds.minX, y: top, width: imageBounds.width, height: imageBounds.height))
            context.restoreGState()
        }
        if border == .frame {
            let mat = CGMutablePath()
            mat.addRect(bounds.insetBy(dx: -expansion, dy: -expansion))
            mat.addRect(bounds)
            context.setFillColor(PDFImagePlatformColor(white: 0.96, alpha: 1).cgColor)
            context.addPath(mat)
            context.fillPath(using: .evenOdd)
        }
        context.saveGState()
        shadow.apply(in: context)
        drawImage(in: imageBounds)
        context.restoreGState()
        if let attachmentName, captionHeight > 0 {
            context.saveGState()
            if flipped {
                context.translateBy(x: bounds.midX * 2, y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            context.setFillColor(PDFImagePlatformColor.white.cgColor)
            context.fill(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: captionHeight))
            let text = NSAttributedString(string: attachmentName,
                                          attributes: [.font: PDFImagePlatformFont.systemFont(ofSize: 12), .foregroundColor: PDFImagePlatformColor.black])
            let path = CGPath(rect: CGRect(x: bounds.minX + 4, y: bounds.minY + 2,
                                           width: max(0, bounds.width - 8), height: max(0, captionHeight - 4)), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                                                 CFRange(location: 0, length: 0), path, nil), context)
            context.restoreGState()
        }
        if border != .none {
            let rect = border == .frame ? bounds.insetBy(dx: -expansion, dy: -expansion) : bounds
            line.stroke([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)], closed: true, width: width, color: borderColor.color, in: context)
        }
        if !titleText.isEmpty {
            let y = titlePosition == .top ? bounds.maxY + expansion + 5 : bounds.minY - expansion - 15
            drawTitle(titleText, at: y, bounds: bounds, context: context)
        }
    }

    private func drawTitle(_ value: String, at y: CGFloat, bounds: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: PDFImagePlatformFont.systemFont(ofSize: 11), .foregroundColor: PDFImagePlatformColor.black]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let width = max(1, bounds.width - 8)
        let truncated = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
        let lineWidth = CTLineGetTypographicBounds(truncated, nil, nil, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: bounds.minX, y: y - 3, width: bounds.width, height: 16))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: max(bounds.minX + 4, bounds.midX - lineWidth / 2), y: y)
        CTLineDraw(truncated, context)
    }
}
