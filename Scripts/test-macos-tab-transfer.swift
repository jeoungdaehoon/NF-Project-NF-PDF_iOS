import AppKit
import SwiftUI
import WebKit

struct TabTransferFixturePanes: View {
    @ObservedObject var transfer: MacPortalTabTransfer
    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: .windowBackgroundColor).frame(width: 750)
                .background(MacPortalTabDropRegion(transfer: transfer, pane: "primary"))
                .overlay { if transfer.targetPane == "primary" { MacPortalTabDropHighlight() } }
            Color(nsColor: .windowBackgroundColor).frame(width: 750)
                .background(MacPortalTabDropRegion(transfer: transfer, pane: "secondary"))
                .overlay { if transfer.targetPane == "secondary" { MacPortalTabDropHighlight() } }
        }.ignoresSafeArea()
    }
}

/// Real NSWindow events against the production toolbar in a native titlebar.
/// Uses isolated tab preferences, nil web views, and no network/user documents.
@main struct TabTransferRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let suite = "nf.tab-transfer-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "TabTransfer", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func pageURL(_ path: String) -> URL { URL(string: "\(MacPortalConfig.origin)/\(path)")! }
        let primary = MacPortalBrowserModel(identifier: "primary", defaults: defaults)
        let secondary = MacPortalBrowserModel(identifier: "secondary", defaults: defaults)
        primary.record(url: pageURL("projects/a?view=period#details"), title: "프로젝트 A")
        primary.record(url: pageURL("daily-reports"), title: "일일보고")
        primary.record(url: pageURL("projects/b"), title: "프로젝트 B")
        secondary.record(url: pageURL("projects/b"), title: "프로젝트 B 중복")
        secondary.record(url: pageURL("weekly-reports"), title: "주간보고")
        let transfer = MacPortalTabTransfer(); transfer.configure(primary: primary, secondary: secondary)
        let preferences = MacPortalPreferences(defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 1500, height: 700),
            styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        let content = NSHostingView(rootView: TabTransferFixturePanes(transfer: transfer))
        content.sizingOptions = []; window.contentView = content
        let bars = HStack(spacing: 0) {
            MacPortalToolbar(model: primary, tabTransfer: transfer, preferences: preferences, isSplit: true,
                sidebarHidden: false, showsSidebarButton: true, showsTrailingControls: false,
                onToggleSidebar: {}, onToggleSplit: {}, onActivate: {}).frame(width: 690)
            MacPortalToolbar(model: secondary, tabTransfer: transfer, preferences: preferences, isSplit: true,
                sidebarHidden: false, showsSidebarButton: false, showsTrailingControls: true,
                onToggleSidebar: {}, onToggleSplit: {}, onActivate: {}).frame(width: 710)
        }
        let host = NSHostingView(rootView: bars); host.frame = CGRect(x: 0, y: 0, width: 1400, height: 32)
        let accessory = NSTitlebarAccessoryViewController(); accessory.view = host; accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(0.3)
        let destination = CGPoint(x: 1050, y: 350)
        let aID = MacPortalConfig.tabIdentity(for: pageURL("projects/a"))
        let bID = MacPortalConfig.tabIdentity(for: pageURL("projects/b"))
        func label(_ pane: String, _ id: String) throws -> MacPortalTabPressLabel.PressView {
            guard let view = descendants(host).compactMap({ $0 as? MacPortalTabPressLabel.PressView }).first(where: { $0.pane == pane && $0.page?.id == id }) else {
                throw NSError(domain: "TabTransfer", code: 100, userInfo: [NSLocalizedDescriptionKey: "Missing production tab label \(pane) \(id)"])
            }
            return view
        }
        func center(_ view: NSView) -> CGPoint { view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        func event(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5)!
            app.postEvent(event, atStart: false); pump(0.02)
        }

        let a = try label("primary", aID), clickPoint = center(a)
        event(.leftMouseDown, at: clickPoint); pump(0.05); event(.leftMouseUp, at: clickPoint); pump(0.3)
        try check(primary.activePageID == aID && transfer.pageID == nil, "short click still selects the page without starting drag")
        let start = center(try label("primary", aID))
        event(.leftMouseDown, at: start); pump(0.45)
        try check(transfer.pageID == aID && transfer.previewFrame != nil, "0.4 second real titlebar press activates floating tab preview")
        let preview = app.windows.first { $0.ignoresMouseEvents && $0.frame == transfer.previewFrame }
        try check(preview?.alphaValue == 0.85, "floating tab uses 85 percent opacity")
        if let view = preview?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-tab-transfer-neutral-preview.png"))
        }
        let sourcePages = primary.pages, targetPages = secondary.pages
        event(.leftMouseDragged, at: destination)
        try check(transfer.targetPane == "secondary", "drag into opposite CONTENT pane activates drop target")
        try check(primary.pages == sourcePages && secondary.pages == targetPages, "hover does not switch pages or mutate tab lists")
        pump(0.18); host.layoutSubtreeIfNeeded(); content.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-tab-transfer-active-titlebar.png"))
        }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-tab-transfer-drop-highlight.png"))
        }
        event(.leftMouseUp, at: destination)
        try check(transfer.isFinishing, "drop starts settlement animation")
        pump(0.3)
        try check(!primary.pages.contains(where: { $0.id == aID }) && secondary.activePageID == aID, "confirmed drop removes source tab and activates destination")
        try check(secondary.currentPage?.url.absoluteString.hasSuffix("?view=period#details") == true, "full URL query and fragment survive transfer")
        try check(transfer.pageID == nil && transfer.previewFrame == nil, "settlement clears preview and drag state")

        // Reverse direction uses exactly the same native titlebar label and events.
        let reverse = center(try label("secondary", aID))
        event(.leftMouseDown, at: reverse); pump(0.45)
        event(.leftMouseDragged, at: CGPoint(x: 350, y: 350)); event(.leftMouseUp, at: CGPoint(x: 350, y: 350)); pump(0.3)
        try check(primary.activePageID == aID && !secondary.pages.contains(where: { $0.id == aID }), "right-to-left drag also transfers the tab")

        // Existing route in destination must not be duplicated.
        let duplicate = center(try label("primary", bID)), count = secondary.pages.count
        event(.leftMouseDown, at: duplicate); pump(0.45); event(.leftMouseDragged, at: destination); event(.leftMouseUp, at: destination); pump(0.3)
        try check(secondary.pages.count == count && secondary.pages.filter({ $0.id == bID }).count == 1, "existing destination route is selected without duplicate tabs")

        let cancelStart = center(try label("primary", aID)), beforeCancel = primary.pages
        event(.leftMouseDown, at: cancelStart); pump(0.45); event(.leftMouseDragged, at: CGPoint(x: -100, y: -100))
        event(.leftMouseUp, at: CGPoint(x: -100, y: -100)); pump(0.3)
        try check(primary.pages == beforeCancel && transfer.pageID == nil, "outside drop cancels with no tab loss")
        event(.leftMouseDown, at: cancelStart); pump(0.45)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        try check(window.firstResponder is MacPortalTabPressLabel.PressView, "dragging tab receives keyboard focus for Escape")
        window.sendEvent(escape); pump(0.3); event(.leftMouseUp, at: cancelStart); pump(0.3)
        try check(primary.pages == beforeCancel && transfer.pageID == nil, "Escape cancels and mouse release does not select or move (phase=\(String(describing: transfer.pageID)), pagesEqual=\(primary.pages == beforeCancel))")
        event(.leftMouseDown, at: cancelStart); event(.leftMouseDragged, at: CGPoint(x: cancelStart.x + 20, y: cancelStart.y)); pump(0.45)
        event(.leftMouseUp, at: CGPoint(x: cancelStart.x + 20, y: cancelStart.y))
        try check(transfer.pageID == nil, "moving before hold threshold never starts a drag")

        let last = MacPortalBrowserModel(identifier: "last", defaults: defaults)
        last.record(url: pageURL("projects/last"), title: "마지막 탭")
        try check(last.transferPage(id: last.pages[0].id, to: secondary) && last.pages.count == 1 && last.currentPage?.url == MacPortalConfig.dashboardURL,
            "moving the final source tab leaves a dashboard rather than a blank pane")
        let restored = MacPortalBrowserModel(identifier: "secondary", defaults: defaults)
        try check(restored.pages.map(\.id) == secondary.pages.map(\.id), "destination tab list persists and restores")
        let full = MacPortalBrowserModel(identifier: "full", defaults: defaults)
        for index in 0..<14 { full.record(url: pageURL("projects/full-\(index)"), title: "\(index)") }
        let snapshot = primary.pages
        try check(!primary.transferPage(id: aID, to: full) && primary.pages == snapshot && full.pages.count == 14,
            "full destination refuses transfer without silently deleting another tab")
        transfer.cancel(animated: false); window.close(); pump(0.1)
        print("PASS: \(checks) model and actual native titlebar interaction checks")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool {
                while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        } while Date() < deadline
    }
}
