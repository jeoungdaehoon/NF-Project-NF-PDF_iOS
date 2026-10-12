import AppKit
import Combine
import SwiftUI

/// A document window, not a pane-sized sheet. AppKit owns the fullscreen Space.
@MainActor
final class MacPDFViewerWindowState: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isFullscreen = false
    @Published private(set) var isTransitioning = false
    weak var window: NSWindow?
    var onClose: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var fullscreenWindow: NSWindow?
    private weak var embeddedContainer: NSView?
    private weak var hostedView: NSView?

    static func makeWindow(title: String, screen: NSScreen? = nil) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = CGSize(width: 620, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let size = CGSize(width: min(1100, visible.width), height: min(780, visible.height))
        window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
        return window
    }

    func observe(_ window: NSWindow) {
        guard self.window !== window else { return }
        stopObserving()
        self.window = window
        window.delegate = self
        isFullscreen = window.styleMask.contains(.fullScreen)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.handle(notification.name) }
            })
        }
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWindow.willEnterFullScreenNotification: isTransitioning = true; isFullscreen = true
        case NSWindow.didEnterFullScreenNotification: isTransitioning = false; isFullscreen = true
        case NSWindow.willExitFullScreenNotification: isTransitioning = true
        case NSWindow.didExitFullScreenNotification:
            isTransitioning = false; isFullscreen = false
            restoreEmbeddedView()
        default: break
        }
    }

    func toggle() {
        guard !isTransitioning, let window else { return }
        isTransitioning = true
        window.toggleFullScreen(nil)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isTransitioning = false; isFullscreen = false
        restoreEmbeddedView()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { isTransitioning = false; isFullscreen = true }

    func exit() { if isFullscreen && !isTransitioning { toggle() } }

    func attach(_ host: NSView, to container: NSView) {
        hostedView = host; embeddedContainer = container
        if fullscreenWindow == nil { install(host, in: container) }
    }

    func enterEmbeddedFullscreen(title: String) {
        guard fullscreenWindow == nil, let host = hostedView, let container = embeddedContainer else { return }
        let nativeWindow = Self.makeWindow(title: title, screen: container.window?.screen)
        fullscreenWindow = nativeWindow
        host.removeFromSuperview()
        let content = NSView(frame: CGRect(origin: .zero, size: nativeWindow.frame.size))
        nativeWindow.contentView = content
        install(host, in: content)
        observe(nativeWindow)
        nativeWindow.makeKeyAndOrderFront(nil)
        toggle()
    }

    private func install(_ host: NSView, in container: NSView) {
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }

    private func restoreEmbeddedView() {
        guard let nativeWindow = fullscreenWindow else { return }
        if let host = hostedView, let container = embeddedContainer { install(host, in: container) }
        stopObserving()
        nativeWindow.delegate = nil
        nativeWindow.close()
        fullscreenWindow = nil
        window = nil
        embeddedContainer?.window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if fullscreenWindow != nil {
            if isFullscreen { exit() } else { restoreEmbeddedView() }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        stopObserving(); window = nil
        onClose?()
    }

    func dispose() {
        // Called only when the owning viewer itself is dismissed.
        stopObserving()
        fullscreenWindow?.delegate = nil
        fullscreenWindow?.close()
        fullscreenWindow = nil; hostedView = nil; embeddedContainer = nil; window = nil
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Reparent the SAME hosting view for fullscreen; do not reload the PDF/editor.
struct MacPDFMovableViewer<Content: View>: NSViewRepresentable {
    let presentation: MacPDFViewerWindowState
    let content: Content
    final class Coordinator {
        let host: NSHostingView<Content>
        let presentation: MacPDFViewerWindowState
        init(_ value: MacPDFMovableViewer) {
            host = NSHostingView(rootView: value.content); host.sizingOptions = []
            presentation = value.presentation
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        presentation.attach(context.coordinator.host, to: container)
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.host.rootView = content
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.presentation.dispose() }
}

/// Owned by the library's StateObject, not by a disposable background view.
/// Window teardown NEVER writes a library Binding or calls its reload closure.
@MainActor
final class MacPDFDocumentWindowController: ObservableObject {
    let presentation = MacPDFViewerWindowState()
    private(set) var window: NSWindow?
    private(set) var host: NSHostingView<MacPDFDocumentView>?
    private var documentID: String?

    func open(_ document: MacLocalPDFDocument, repository: MacPDFLocalStorageRepository, editorDirectory: URL? = nil, screen: NSScreen? = nil) {
        if documentID == document.id, let window { window.makeKeyAndOrderFront(nil); return }
        let content = MacPDFDocumentView(document: document,
            onOpen: { [weak self] in self?.open($0, repository: repository, editorDirectory: editorDirectory) },
            onClose: { [weak self] in self?.close() }, fullscreen: presentation,
            repository: repository, editorDirectory: editorDirectory)
        documentID = document.id
        if let host {
            host.rootView = content
            window?.title = document.fileName
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = MacPDFViewerWindowState.makeWindow(title: document.fileName, screen: screen ?? NSApp.keyWindow?.screen)
        let host = NSHostingView(rootView: content); host.sizingOptions = []
        window.contentView = host
        self.window = window; self.host = host
        presentation.onClose = { [weak self] in self?.releaseWindow() }
        presentation.observe(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func releaseWindow() {
        presentation.onClose = nil
        presentation.dispose()
        window?.delegate = nil
        window = nil; host = nil; documentID = nil
    }

    func close() {
        let closingWindow = window
        releaseWindow()
        closingWindow?.close()
    }
}
