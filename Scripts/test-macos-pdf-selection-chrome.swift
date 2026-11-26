import AppKit
import Combine
import PDFKit
import SwiftUI
@testable import NF_macOS

/// Isolated real PDFKit gesture/layout regression; no user PDFs or network.
@main struct PDFSelectionChromeRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-selection-chrome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 800, height: 900), for: .mediaBox); document.insert(page, at: 0)
        let state = MacPDFEditorState(document: document, identifier: "selection-chrome", fileName: "fixture.pdf", directory: directory)
        let canvas = MacPDFEditingView(frame: CGRect(x: 0, y: 0, width: 1000, height: 900))
        canvas.editor = state; state.canvas = canvas; canvas.document = document
        canvas.displayMode = .singlePage; canvas.autoScales = false; canvas.scaleFactor = 1
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1000, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.orderFront(nil); canvas.installObservers()
        defer { canvas.removeObservers(); window.close() }
        func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
        pump()
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PDFSelectionChrome", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        try check(MacPDFStyle.shapeDefault.width == 0.75 && MacPDFStyle.shapeDefault.stroke.r == MacPDFStyle.shapeDefault.stroke.g, "new shapes use a thin neutral border")
        try check(MacPDFStyle.shapeDefault.fill.a > 0 && MacPDFStyle.shapeDefault.fill.a < 0.15, "new shape fill is lightly translucent gray")
        try check(MacPDFStyle.textDefault.width == 0.5 && MacPDFStyle.textDefault.dashed && MacPDFStyle.textDefault.textBorder != nil, "new text boxes have thin gray dashed borders")
        let source = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 100, y: 300, width: 150, height: 100), style: .shapeDefault)
        let target = MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 440, y: 300, width: 180, height: 90), style: .textDefault, text: "연결 대상")
        state.add(source); state.add(target)
        let connector = MacPDFObject(page: 0, kind: .connector, bounds: .zero, style: .connectorDefault, sourceID: source.id, targetID: target.id)
        state.add(connector); state.selectObjects([source.id], showMenu: true); state.connectorEnabled = true; pump()
        let borders = canvas.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
        try check(borders.contains { $0.lineDashPattern == [3, 3] && $0.lineWidth == 0.75 }, "selection border is thin and dashed at view scale")
        try check(borders.contains { ($0.fillColor?.alpha ?? 0) > 0.9 && $0.lineWidth == 0.75 }, "small handles have their own solid background")
        try check(canvas.connectionHandles.count == 4, "four directional connector grips remain available")
        let menu = MacPDFMenuLayout.frame(object: CGRect(x: 20, y: 200, width: 200, height: 100), viewport: CGSize(width: 600, height: 500), preferredWidth: 390)
        try check(menu.height == 38, "object popup fits compact icons and labels in 38 points")
        let before = state.objects, undo = state.undoCount
        var publications = 0
        let observation = state.$objects.dropFirst().sink { _ in publications += 1 }
        func mouse(_ type: NSEvent.EventType, at pdfPoint: CGPoint) {
            let location = canvas.convert(canvas.convert(pdfPoint, from: page), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5)!
            window.sendEvent(event); pump()
        }
        let origin = CGPoint(x: 175, y: 350)
        mouse(.leftMouseDown, at: origin)
        for step in 1...8 {
            mouse(.leftMouseDragged, at: CGPoint(x: origin.x + CGFloat(step) * 5, y: origin.y + CGFloat(step) * 3))
            let live = canvas.renderingObjects.first { $0.id == source.id }!
            try check(abs(live.bounds.minX - source.bounds.minX - CGFloat(step) * 5) < 0.01, "drag \(step) follows the pointer immediately")
            try check(state.objects == before && publications == 0 && state.undoCount == undo, "drag \(step) does not publish or persist intermediate document states")
            let ends = MacPDFObjectRenderer.endpoints(connector, objects: canvas.renderingObjects)!
            try check(abs(ends.0.x - live.bounds.maxX) < 0.01, "drag \(step) keeps the connector attached to the live object")
        }
        mouse(.leftMouseUp, at: CGPoint(x: origin.x + 40, y: origin.y + 24))
        try check(publications == 1 && state.undoCount == undo + 1, "mouse-up publishes exactly one undoable document edit")
        try check(state.objects.first { $0.id == source.id }!.bounds.minX == source.bounds.minX + 40, "committed bounds match the final pointer")
        state.undo(); try check(state.objects == before, "one undo restores the complete move")
        state.redo(); try check(state.objects.first { $0.id == source.id }!.bounds.minX == source.bounds.minX + 40, "one redo restores the complete move")
        observation.cancel()
        state.selectObjects([source.id], showMenu: false); pump()
        let moved = state.objects
        mouse(.leftMouseDown, at: CGPoint(x: 215, y: 374))
        mouse(.leftMouseDragged, at: CGPoint(x: 245, y: 404))
        canvas.cancelGesture(); pump()
        try check(state.objects == moved && canvas.renderingObjects == moved, "cancel discards the preview without modifying the document")
        state.selectObjects([connector.id], showMenu: false); pump()
        let routeBefore = state.objects, routeUndo = state.undoCount
        let grip = canvas.convert(canvas.connectorRouteHandle!, to: page)
        var routePublications = 0
        let routeObservation = state.$objects.dropFirst().sink { _ in routePublications += 1 }
        mouse(.leftMouseDown, at: grip)
        mouse(.leftMouseDragged, at: CGPoint(x: grip.x + 35, y: grip.y + 20))
        try check(state.objects == routeBefore && routePublications == 0, "connector route drag also keeps document publications out of the live gesture")
        try check(canvas.renderingObjects.first { $0.id == connector.id }!.connectorOffset != nil, "connector route has an immediate native preview")
        mouse(.leftMouseUp, at: CGPoint(x: grip.x + 35, y: grip.y + 20))
        try check(routePublications == 1 && state.undoCount == routeUndo + 1, "connector route commits once on mouse-up")
        routeObservation.cancel(); state.undo()
        try check(state.objects == routeBefore, "connector route undo restores its original route")
        state.connectorEnabled = false
        state.selectObjects([target.id], showMenu: false); pump()
        let textBounds = canvas.selectionBounds()!
        let rotate = CGPoint(x: textBounds.maxX, y: textBounds.maxY + 24 / canvas.scaleFactor)
        let oldRotation = state.objects.first { $0.id == target.id }!.rotation
        let rotateEnd = CGPoint(x: rotate.x - 25, y: rotate.y + 25)
        mouse(.leftMouseDown, at: rotate)
        mouse(.leftMouseDragged, at: rotateEnd)
        mouse(.leftMouseUp, at: rotateEnd)
        try check(state.objects.first { $0.id == target.id }!.rotation != oldRotation, "right-end rotation handle rotates the selected text")
        state.undo()
        state.selectObjects([target.id], showMenu: false); pump()
        let delete = CGPoint(x: textBounds.minX - 18 / canvas.scaleFactor, y: textBounds.maxY + 18 / canvas.scaleFactor)
        mouse(.leftMouseDown, at: delete)
        mouse(.leftMouseUp, at: delete)
        try check(!state.objects.contains { $0.id == target.id }, "left trash handle deletes the selected text")
        state.undo()
        let menuState = MacPDFEditorState(document: document, identifier: "menu-proof", fileName: "fixture.pdf", directory: directory.appendingPathComponent("menu"))
        menuState.objects = [source]; menuState.selection = [source.id]; menuState.menuVisible = true
        menuState.selectionViewRect = CGRect(x: 200, y: 160, width: 160, height: 110)
        let proof = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 650, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        proof.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [.white, .gray.opacity(0.3)], startPoint: .top, endPoint: .bottom)
            Text("PDF 원본 내용 · 반투명 메뉴 확인").foregroundStyle(.secondary).position(x: 325, y: 112)
            MacPDFObjectMenu(state: menuState, canvasSize: CGSize(width: 650, height: 430), onImageAction: { _ in })
        })
        proof.contentView = host; proof.orderFront(nil); pump()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-ui-tests/object-menu.png"))
        }
        proof.close()
        print("PASS: \(checks) PDF selection chrome and drag checks")
    }
}
