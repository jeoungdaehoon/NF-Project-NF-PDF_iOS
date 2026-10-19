import AppKit
import CoreText

/// One PDF-coordinate layout for input, editable objects and flattened export.
enum MacPDFTextLayout {
    static func inset(_ style: MacPDFStyle) -> CGFloat {
        max(4, max(0, style.width) * 0.5 + 2, max(0, style.textCornerRadius ?? 0) * 0.3 + 2)
    }
    static func contentRect(_ bounds: CGRect, style: MacPDFStyle) -> CGRect {
        bounds.insetBy(dx: inset(style), dy: inset(style))
    }
    static func requiredHeight(_ text: NSAttributedString, width: CGFloat, style: MacPDFStyle) -> CGFloat {
        let padding = inset(style), innerWidth = max(1, width - padding * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let coreText = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: innerWidth, height: 1e7), nil)
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: innerWidth, height: 1e7)); container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        let nativeHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        return ceil(max(coreText.height, nativeHeight, text.length == 0 ? style.fontSize * 1.2 : 0)) + padding * 2 + 1
    }
    static func fittedBounds(_ text: NSAttributedString, minimum: CGRect, style: MacPDFStyle, page: CGRect) -> CGRect {
        var largestFont = text.length == 0 ? CGFloat(style.fontSize) : 1
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { largestFont = max(largestFont, font.pointSize) }
        }
        var width = min(page.width, max(minimum.width, largestFont * 1.25 + inset(style) * 2))
        var height = max(minimum.height, requiredHeight(text, width: width, style: style))
        // Usually preserve width and grow downward from the existing top edge.
        // Near a page boundary, widen before moving the box back inside the page.
        let availableHeight = max(minimum.height, minimum.maxY - page.minY)
        if height > availableHeight {
            let wider = max(width, page.maxX - max(page.minX, minimum.minX))
            if wider > width { width = wider; height = max(minimum.height, requiredHeight(text, width: width, style: style)) }
        }
        return MacPDFEditorState.clamped(CGRect(x: minimum.minX, y: minimum.maxY - height, width: width, height: height), to: page)
    }
    static func drawBox(in context: CGContext, bounds: CGRect, style: MacPDFStyle) {
        context.saveGState(); defer { context.restoreGState() }
        let radius = min(max(0, style.textCornerRadius ?? 0), min(bounds.width, bounds.height) * 0.5)
        context.setFillColor(style.fill.color.cgColor)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
        let width = max(0, style.width)
        guard width > 0, let border = style.textBorder, border.a > 0 else { return }
        context.setStrokeColor(border.color.cgColor); context.setLineWidth(width); context.setLineCap(.butt)
        context.setLineDash(phase: 0, lengths: style.dashed ? [width * 3, width * 2] : [])
        let rect = bounds.insetBy(dx: width * 0.5, dy: width * 0.5)
        guard rect.width > 0, rect.height > 0 else { return }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: max(0, radius - width * 0.5), cornerHeight: max(0, radius - width * 0.5), transform: nil)); context.strokePath()
    }
}

/// Native text entry keeps its normal selection/IME behavior; only the box
/// decoration is shared with the PDF renderer (CALayer borders cannot be dashed).
final class MacPDFTextInput: NSTextView {
    var boxStyle = MacPDFStyle()
    var pdfScale: CGFloat = 1
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.scaleBy(x: pdfScale, y: pdfScale)
            MacPDFTextLayout.drawBox(in: context, bounds: CGRect(x: 0, y: 0, width: bounds.width / pdfScale, height: bounds.height / pdfScale), style: boxStyle)
            context.restoreGState()
        }
        super.draw(dirtyRect)
    }
}
