import AppKit
import PDFKit

/// PDFKit renders the original document. This transparent AppKit view renders
/// editable objects without mutating PDFKit annotation caches on every drag.
final class MacPDFDrawingOverlay: NSView {
    weak var canvas: MacPDFEditingView?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { canvas?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let editor = canvas.editor, let document = canvas.document, let context = NSGraphicsContext.current?.cgContext else { return }
        // AppKit clears the transparent backing surface. Clearing this context
        // ourselves also erases the underlying PDF during view-tree snapshots.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), canvas.convert(page.bounds(for: .cropBox), from: page).intersects(canvas.bounds) else { continue }
            let origin = canvas.convert(CGPoint.zero, from: page), x = canvas.convert(CGPoint(x: 1, y: 0), from: page), y = canvas.convert(CGPoint(x: 0, y: 1), from: page)
            context.saveGState()
            context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y))
            context.clip(to: page.bounds(for: .cropBox))
            for object in editor.pageObjects(index) where object.id != canvas.editingObjectID { MacPDFObjectRenderer.draw(object, objects: editor.objects, context: context) }
            if let draft = canvas.drawingDraft, draft.page == index { MacPDFObjectRenderer.draw(draft, objects: editor.objects, context: context) }
            context.restoreGState()
        }
        canvas.drawConnectionOverlay(in: context)
    }
}
