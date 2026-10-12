import AppKit
import PDFKit
import SwiftUI

/// Isolated native SwiftUI/PDFKit layout smoke test; no real app data/network.
@main
struct PDFEditorLayoutProof {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let native = ProcessInfo.processInfo.environment["NF_TEST_NATIVE_FULLSCREEN"] == "1"
        app.setActivationPolicy(native ? .regular : .prohibited)
        if native { app.finishLaunching(); app.activate(ignoringOtherApps: true) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pdf = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "ui-fixture", fileName: "편집 예시.pdf", directory: temporary)
        state.add(MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 70, y: 520, width: 150, height: 80), shape: .roundedRectangle))
        state.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 330, y: 520, width: 200, height: 90), text: "화면 흐름 설명"))
        let ids = state.objects.map(\.id)
        state.add(MacPDFObject(page: 0, kind: .connector, bounds: page.bounds(for: .mediaBox), sourceID: ids[0], targetID: ids[1]))
        state.selection = []; state.tool = .shape
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacPDFEditorView(state: state)); window.contentView = host; window.orderFront(nil)
        for (width, name) in [(1100.0, "wide"), (550.0, "narrow"), (550.0, "baked")] {
            if name == "baked", let data = state.exportPDF(), let baked = PDFDocument(data: data) { state.document = baked; state.objects = []; state.canvas?.document = baked }
            window.setContentSize(CGSize(width: width, height: 760)); host.frame = CGRect(x: 0, y: 0, width: width, height: 760)
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let canvas = state.canvas, canvas.bounds.width >= width - 2, canvas.bounds.height > 500, canvas.scaleFactor > 0.5 else { throw NSError(domain: "PDFUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF viewport/initial fit is incorrect: \(String(describing: state.canvas?.frame)) scale=\(state.canvas?.scaleFactor ?? 0), fit=\(state.canvas?.scaleFactorForSizeToFit ?? 0), crop=\(page.bounds(for: .cropBox)), media=\(page.bounds(for: .mediaBox)), docView=\(String(describing: state.canvas?.documentView?.frame))"]) }
            print("PDF viewport \(canvas.bounds.size), scale \(canvas.scaleFactor)")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-macos-pdf-editor-\(name).png"))
        }
        // Normal slide still reserves only the portal tabbar; fullscreen uses NSWindow.
        let size = CGSize(width: 1300, height: 850)
        let normal = MacPDFSlidePanelLayout.frame(preferredWidth: 540, availableSize: size)
        guard normal.width == 540, normal.minY == 32, normal.maxY == size.height else { throw NSError(domain: "PDFUI", code: 2) }
        let controller = MacPDFViewerWindowState()
        let viewerWindow = MacPDFViewerWindowState.makeWindow(title: "PDF 창 검증")
        guard viewerWindow.sheetParent == nil, viewerWindow.styleMask.contains(.resizable),
              viewerWindow.collectionBehavior.contains(.fullScreenPrimary) else { throw NSError(domain: "PDFUI", code: 3) }
        // Local library popup: enlarge BOTH axes and shrink again, without a sheet's fixed size.
        window.contentView = NSView()
        viewerWindow.contentView = host
        viewerWindow.makeKeyAndOrderFront(nil)
        controller.observe(viewerWindow)
        for size in [CGSize(width: 1200, height: 850), CGSize(width: 680, height: 510)] {
            viewerWindow.setContentSize(size); host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard abs(host.bounds.width - size.width) < 2, abs(host.bounds.height - size.height) < 2,
                  (state.canvas?.bounds.height ?? 0) > 300 else { throw NSError(domain: "PDFUI", code: 4) }
        }
        let canvasID = state.canvas.map(ObjectIdentifier.init)
        state.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 60, y: 400, width: 180, height: 60), text: "전체화면 편집 검증"))
        let objectIDs = state.objects.map(\.id), undoCount = state.undoCount
        if native {
            let original = viewerWindow.frame
            controller.toggle()
            try waitFor { controller.isFullscreen && !controller.isTransitioning }
            guard viewerWindow.styleMask.contains(.fullScreen), let screen = viewerWindow.screen,
                  abs(viewerWindow.frame.width - screen.frame.width) < 2,
                  abs(viewerWindow.frame.height - screen.frame.height) < 2 else { throw NSError(domain: "PDFUI", code: 5) }
            print("PASS: actual native fullscreen \(viewerWindow.frame), monitor \(screen.frame)")
            controller.exit()
            try waitFor { !controller.isFullscreen && !controller.isTransitioning }
            guard abs(viewerWindow.frame.width - original.width) < 2, abs(viewerWindow.frame.height - original.height) < 2 else { throw NSError(domain: "PDFUI", code: 6) }
        } else {
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: viewerWindow)
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: viewerWindow)
            guard controller.isFullscreen, !controller.isTransitioning else { throw NSError(domain: "PDFUI", code: 5) }
            NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: viewerWindow)
            NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: viewerWindow)
            guard !controller.isFullscreen else { throw NSError(domain: "PDFUI", code: 6) }
        }
        guard state.canvas.map(ObjectIdentifier.init) == canvasID, state.objects.map(\.id) == objectIDs,
              state.undoCount == undoCount else { throw NSError(domain: "PDFUI", code: 7) }
        // Remote slide: move the existing editor to a native window and return it.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let remote = MacPDFViewerWindowState()
        remote.attach(host, to: container)
        viewerWindow.contentView = container
        if native {
            remote.enterEmbeddedFullscreen(title: "오른쪽 슬라이드 전체화면 검증")
            try waitFor { remote.isFullscreen && !remote.isTransitioning }
            guard remote.window?.sheetParent == nil, remote.window?.styleMask.contains(.fullScreen) == true,
                  host.window === remote.window, state.canvas.map(ObjectIdentifier.init) == canvasID else { throw NSError(domain: "PDFUI", code: 8) }
            remote.exit()
            try waitFor { !remote.isFullscreen && !remote.isTransitioning && host.superview === container }
        }
        guard state.canvas.map(ObjectIdentifier.init) == canvasID, state.objects.map(\.id) == objectIDs,
              state.undoCount == undoCount else { throw NSError(domain: "PDFUI", code: 9) }
        state.add(MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 250, y: 400, width: 80, height: 60)))
        state.undo(); state.redo()
        guard state.exportPDF() != nil, state.objects.count == objectIDs.count+1 else { throw NSError(domain: "PDFUI", code: 7) }
        remote.dispose(); controller.dispose(); viewerWindow.close(); window.close()
        // Exercise the exact file-list presenter without touching the user's PDF cache.
        // Missing-file fixtures intentionally avoid creating a persistent real editor.
        let selected = MacLocalPDFDocument(id: "missing-fixture", fileName: "팝업 크기 검증.pdf",
            localFileURL: temporary.appendingPathComponent("missing.pdf"), modifiedAt: Date(), fileSize: 0, isFavorite: false, deletedAt: nil)
        let coordinator = MacPDFDocumentWindowController()
        coordinator.open(selected, repository: MacPDFLocalStorageRepository(directoryURL: temporary.appendingPathComponent("cache")))
        guard let popup = coordinator.window, let popupHost = coordinator.host,
              popup.sheetParent == nil, popup.styleMask.contains(.resizable) else { throw NSError(domain: "PDFUI", code: 11) }
        popup.setContentSize(CGSize(width: 1250, height: 880))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard popupHost.bounds.width == 1250, popupHost.bounds.height == 880 else { throw NSError(domain: "PDFUI", code: 12) }
        if native {
            coordinator.presentation.toggle()
            try waitFor { coordinator.presentation.isFullscreen && !coordinator.presentation.isTransitioning }
            popupHost.layoutSubtreeIfNeeded()
            if let bitmap = popupHost.bitmapImageRepForCachingDisplay(in: popupHost.bounds) {
                popupHost.cacheDisplay(in: popupHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-native-fullscreen-title.png"))
            }
            coordinator.presentation.exit()
            try waitFor { !coordinator.presentation.isFullscreen && !coordinator.presentation.isTransitioning }
        }
        popup.performClose(nil)
        guard coordinator.window == nil else { throw NSError(domain: "PDFUI", code: 13) }
        print("PASS: native PDF editor, resizable viewer window, fullscreen notifications, state preservation and editing")
    }

    @MainActor static func waitFor(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard condition() else { throw NSError(domain: "PDFUI", code: 10, userInfo: [NSLocalizedDescriptionKey: "Native fullscreen transition timed out"]) }
    }
}
