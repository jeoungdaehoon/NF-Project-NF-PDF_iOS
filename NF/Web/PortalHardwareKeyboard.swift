#if os(iOS) && !targetEnvironment(macCatalyst)
import GameController
import WebKit

@MainActor
final class PortalHardwareKeyboard: NSObject {
    static let shared = PortalHardwareKeyboard()
    private let views = NSHashTable<WKWebView>.weakObjects()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(connectionChanged(_:)), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectionChanged(_:)), name: .GCKeyboardDidDisconnect, object: nil)
    }

    func attach(_ view: WKWebView) {
        views.add(view)
        publish(to: view)
    }

    @objc private nonisolated func connectionChanged(_ notification: Notification) {
        Task { @MainActor in views.allObjects.forEach(publish(to:)) }
    }

    private func publish(to view: WKWebView) {
        guard let url = view.url, url.scheme == "https", PortalConfig.isPortalURL(url) else { return }
        let connected = GCKeyboard.coalesced != nil
        view.evaluateJavaScript("""
            window.__NF_PORTAL_HARDWARE_KEYBOARD_NATIVE__ = true;
            window.__NF_PORTAL_HARDWARE_KEYBOARD_CONNECTED__ = \(connected);
            window.dispatchEvent(new CustomEvent('nf-hardware-keyboard-change', {detail:{connected:\(connected)}}));
            """, completionHandler: nil)
    }
}
#endif
