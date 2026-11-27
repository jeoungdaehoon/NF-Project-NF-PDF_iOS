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
        let objectRect = CGRect(x: 20, y: 200, width: 200, height: 100)
        let viewport = CGSize(width: 600, height: 500)
        let menu = MacPDFMenuLayout.frame(object: objectRect, viewport: viewport, preferredWidth: 240)
        let actions = MacPDFMenuLayout.cornerControls(object: objectRect, viewport: viewport)!
        try check(menu.height == 34, "object popup fits smaller icons and labels in 34 points")
        try check(actions.delete.midX < objectRect.minX && actions.rotate.midX > objectRect.maxX
                  && actions.delete.midY == actions.rotate.midY, "delete and rotate align at the upper corners")
        try check(menu.maxY + 6 < actions.delete.minY, "popup and its pointer clear both corner controls")
        let topEdge = CGRect(x: 590, y: 2, width: 100, height: 60)
        let edgeActions = MacPDFMenuLayout.cornerControls(object: topEdge, viewport: viewport)!
        let edgeMenu = MacPDFMenuLayout.frame(object: topEdge, viewport: viewport, preferredWidth: 240)
        try check(CGRect(origin: .zero, size: viewport).contains(edgeActions.rotate) && !edgeActions.delete.intersects(edgeActions.rotate)
                  && edgeMenu.minY > edgeActions.rotate.maxY, "controls stay visible and the popup moves below near viewport edges")
        let overlay = canvas.subviews.compactMap { $0 as? MacPDFDrawingOverlay }.first!
        let cornerIcons = overlay.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden }
        try check(cornerIcons.count == 2 && cornerIcons.allSatisfy { $0.image != nil && $0.contentTintColor == .secondaryLabelColor },
                  "both corner controls display neutral system symbols")
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
        let rotateFrame = canvas.selectionActionFrames!.rotate
        let rotate = canvas.convert(CGPoint(x: rotateFrame.midX, y: rotateFrame.midY), to: page)
        let oldRotation = state.objects.first { $0.id == target.id }!.rotation
        let rotateEnd = CGPoint(x: rotate.x - 25, y: rotate.y + 25)
        mouse(.leftMouseDown, at: rotate)
        mouse(.leftMouseDragged, at: rotateEnd)
        mouse(.leftMouseUp, at: rotateEnd)
        try check(state.objects.first { $0.id == target.id }!.rotation != oldRotation, "right-end rotation handle rotates the selected text")
        state.undo()
        state.selectObjects([target.id], showMenu: false); pump()
        let deleteFrame = canvas.selectionActionFrames!.delete
        let delete = canvas.convert(CGPoint(x: deleteFrame.midX, y: deleteFrame.midY), to: page)
        mouse(.leftMouseDown, at: delete)
        mouse(.leftMouseUp, at: delete)
        try check(!state.objects.contains { $0.id == target.id }, "left trash handle deletes the selected text")
        state.undo()
        let imageData = NSImage(size: CGSize(width: 160, height: 80), flipped: false) { rect in
            NSColor.systemGray.setFill()
            rect.fill()
            return true
        }.tiffRepresentation!
        let image = MacPDFObject(page: 0, kind: .image, bounds: CGRect(x: 315, y: 190, width: 160, height: 80), imageData: imageData)
        state.add(image)
        state.selectObjects([image.id], showMenu: false); pump()
        let imageIndex = state.objects.firstIndex { $0.id == image.id }!
        func imageAnchor(_ object: MacPDFObject, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
            MacPDFObjectRenderer.anchor(object, MacPDFPoint(CGPoint(x: x, y: y)))
        }
        func resizeImage(_ x: CGFloat, _ y: CGFloat, by translation: CGPoint) -> MacPDFObject {
            let object = state.objects[imageIndex]
            let start = imageAnchor(object, x, y)
            let delta = translation.applying(CGAffineTransform(rotationAngle: object.rotation))
            let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
            mouse(.leftMouseDown, at: start)
            mouse(.leftMouseDragged, at: end)
            mouse(.leftMouseUp, at: end)
            return state.objects[imageIndex]
        }
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.02 }
        let stretched = resizeImage(1, 0.5, by: CGPoint(x: 40, y: 20))
        try check(abs(stretched.bounds.width - 200) < 0.02 && abs(stretched.bounds.height - 80) < 0.02,
                  "image side changes width only")
        let cornerScaled = resizeImage(1, 1, by: CGPoint(x: 60, y: 12))
        try check(cornerScaled.bounds.width > stretched.bounds.width
                  && abs(cornerScaled.bounds.width / cornerScaled.bounds.height - 2.5) < 0.001
                  && close(imageAnchor(cornerScaled, 0, 0), imageAnchor(stretched, 0, 0)),
                  "image corner preserves its current stretched ratio and fixes the opposite corner")
        state.objects[imageIndex].rotation = .pi / 6
        canvas.refreshAnnotations(); pump()
        let tilted = state.objects[imageIndex]
        let taller = resizeImage(0.5, 1, by: CGPoint(x: 15, y: 30))
        try check(abs(taller.bounds.width - tilted.bounds.width) < 0.02
                  && abs(taller.bounds.height - tilted.bounds.height - 30) < 0.02
                  && close(imageAnchor(taller, 0.5, 0), imageAnchor(tilted, 0.5, 0)),
                  "rotated image side follows its own axis and fixes the opposite edge")
        let tiltedCorner = resizeImage(1, 1, by: CGPoint(x: 40, y: -10))
        try check(tiltedCorner.bounds.width > taller.bounds.width
                  && abs(tiltedCorner.bounds.width / tiltedCorner.bounds.height - taller.bounds.width / taller.bounds.height) < 0.001
                  && close(imageAnchor(tiltedCorner, 0, 0), imageAnchor(taller, 0, 0)),
                  "rotated image corner preserves its ratio")
        for (initial, requested, expected) in [(12.0, 2.0, 0.0), (65, 88, 90), (160, 177, 180), (345, 358, 360), (70, 79, 79), (248, 268, 268)] {
            state.objects[imageIndex].rotation = initial * .pi / 180
            canvas.refreshAnnotations(); pump()
            let original = state.objects[imageIndex]
            let pivot = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
            let frame = canvas.selectionActionFrames!.rotate
            let start = canvas.convert(CGPoint(x: frame.midX, y: frame.midY), to: page)
            let vector = CGPoint(x: start.x - pivot.x, y: start.y - pivot.y)
                .applying(CGAffineTransform(rotationAngle: (requested - initial) * .pi / 180))
            let end = CGPoint(x: pivot.x + vector.x, y: pivot.y + vector.y)
            mouse(.leftMouseDown, at: start)
            mouse(.leftMouseDragged, at: end)
            let previewAngle = canvas.renderingObjects[imageIndex].rotation * 180 / .pi
            try check(abs(previewAngle - expected) < 0.2 && state.objects[imageIndex] == original,
                      "rotation previews \(expected) degrees for a pointer angle of \(requested)")
            mouse(.leftMouseUp, at: end)
            try check(abs(state.objects[imageIndex].rotation * 180 / .pi - expected) < 0.2,
                      "rotation commits the previewed angle")
        }
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
