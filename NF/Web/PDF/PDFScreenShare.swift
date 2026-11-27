import SwiftUI

#if os(macOS)
import AppKit

@MainActor final class PDFScreenShare {
    weak var anchor: NSView?
    private var picker: NSSharingServicePicker?

    func capture() -> NSImage? {
        guard let anchor, let content = anchor.window?.contentView else { return nil }
        let rect = anchor.convert(anchor.bounds, to: content).intersection(content.bounds)
        guard !rect.isEmpty, let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    func present() -> Bool {
        guard let anchor, let image = capture() else { return false }
        let picker = NSSharingServicePicker(items: [image])
        self.picker = picker
        let point = anchor.convert(anchor.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let location = anchor.bounds.contains(point) ? point : CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        picker.show(relativeTo: CGRect(origin: location, size: CGSize(width: 1, height: 1)), of: anchor, preferredEdge: .minY)
        return true
    }
}

struct PDFScreenShareAnchor: NSViewRepresentable {
    let controller: PDFScreenShare
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
#else
import UIKit

@MainActor final class PDFScreenShare {
    weak var anchor: UIView?

    func capture() -> UIImage? {
        guard let anchor, let window = anchor.window else { return nil }
        let rect = anchor.convert(anchor.bounds, to: window).intersection(window.bounds)
        guard !rect.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        var captured = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return captured ? image : nil
    }

    func present() -> Bool {
        guard let anchor, let window = anchor.window, var host = window.rootViewController, let image = capture() else { return false }
        while let presented = host.presentedViewController { host = presented }
        guard !(host is UIActivityViewController) else { return false }
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = host.view
            let rect = host.view.convert(anchor.bounds, from: anchor)
            popover.sourceRect = CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1)
        }
        host.present(activity, animated: true)
        return true
    }
}

struct PDFScreenShareAnchor: UIViewRepresentable {
    let controller: PDFScreenShare
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        controller.anchor = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
