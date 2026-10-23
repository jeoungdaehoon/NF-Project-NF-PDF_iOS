import AppKit
import PDFKit
import WebKit

@MainActor private final class PDFShareFixture: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var finished = false
    var failure: String?
    var checks = 0
    var source: WKWebView!
    var popup: WKWebView?
    var windows: [NSWindow] = []
    let fixture: [String: Any]
    let directory: URL

    init(fixture: [String: Any], bootstrap: String, directory: URL) {
        self.fixture = fixture; self.directory = directory
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        source = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 720), configuration: configuration)
        source.uiDelegate = self; source.navigationDelegate = self
        attach(source)
        source.loadHTMLString(fixture["html"] as! String, baseURL: nil)
    }

    func attach(_ view: WKWebView) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.setFrameOrigin(CGPoint(x: -10000, y: -10000)); window.contentView = view; window.orderFront(nil); windows.append(window)
    }

    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "PDFShareRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === source else { return }
        webView.evaluateJavaScript(fixture["script"] as! String) { [weak self] _, error in
            if let error { self?.finish(error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        do {
            let originalController = source.configuration.userContentController
            MacPortalPDFSharing.preparePopup(configuration: configuration, handler: self)
            try check(source.configuration.userContentController === originalController, "popup replaced source pane's controller")
            try check(!originalController.userScripts.isEmpty, "source pane lost portal bootstrap")
            try check(configuration.userContentController !== originalController, "popup still shares source controller")
            try check(configuration.userContentController.userScripts.count == 1, "popup inherited portal scripts")
            try check(configuration.websiteDataStore === source.configuration.websiteDataStore, "popup lost source data store")
            let child = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 720), configuration: configuration)
            child.uiDelegate = self; popup = child; attach(child); return child
        } catch { finish(error.localizedDescription); return nil }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let popup, message.name == "NFPortalMacPDFShare" else { finish("share bridge did not target popup"); return }
        popup.evaluateJavaScript("""
        (()=>{const title=document.querySelector('[data-table-title]'),r=title.getBoundingClientRect();return {chrome:!!document.getElementById('__nfMacBreadcrumbBar'),titleHeight:r.height,titleTop:r.top,titleText:title.textContent}})()
        """) { [weak self, weak popup] value, error in
            guard let self, let popup else { return }
            do {
                if let error { throw error }
                let state = value as? [String: Any] ?? [:]
                try check(state["chrome"] as? Bool == false, "NF Portal breadcrumb was inserted into export")
                let visible = fixture["showTitle"] as? Bool ?? true
                let height = (state["titleHeight"] as? NSNumber)?.doubleValue ?? 0
                try check(visible ? height > 10 : height == 0, "title visibility was changed")
                if visible { try check(((state["titleTop"] as? NSNumber)?.doubleValue ?? -1) >= 0, "title is above capture origin") }
                capture(popup)
            } catch { finish(error.localizedDescription) }
        }
    }

    func capture(_ popup: WKWebView) {
        popup.evaluateJavaScript(MacPortalPDFSharing.measurementScript) { [weak self, weak popup] value, error in
            guard let self, let popup else { return }
            if let error { finish(error.localizedDescription); return }
            let metrics = value as? [String: Any] ?? [:]
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: (metrics["width"] as? NSNumber)?.doubleValue ?? 900, height: (metrics["height"] as? NSNumber)?.doubleValue ?? 720)
            popup.createPDF(configuration: configuration) { [weak self] result in
                guard let self else { return }
                do {
                    let data = try result.get()
                    guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else { throw CocoaError(.fileReadCorruptFile) }
                    let text = page.string ?? "", title = fixture["title"] as! String
                    let name = fixture["name"] as! String
                    try data.write(to: directory.appendingPathComponent(name + ".pdf"))
                    let image = page.thumbnail(of: NSSize(width: 1800, height: 1800), for: .mediaBox)
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent(name + ".png")) }
                    try check(!text.contains("NF Portal"), "app navigation leaked into PDF")
                    try check(text.components(separatedBy: .whitespacesAndNewlines).joined().contains("EXPORTLASTBODYROW"), "last body row was clipped: \(text)")
                    if fixture["showTitle"] as? Bool == true {
                        let normalized = text.components(separatedBy: .whitespacesAndNewlines).joined()
                        try check(normalized.contains(title.components(separatedBy: .whitespacesAndNewlines).joined()), "PDF lost document title")
                        let match = (text as NSString).range(of: "운영 체크사항")
                        if match.location != NSNotFound, let selection = page.selection(for: match) {
                            let bounds = selection.bounds(for: page), media = page.bounds(for: .mediaBox)
                            try check(bounds.minY >= media.minY && bounds.maxY <= media.maxY, "PDF title is outside page bounds")
                        }
                    } else { try check(!text.contains(title), "hidden title was forced into PDF") }
                    try check(abs(page.bounds(for: .mediaBox).width - (configuration.rect?.width ?? 0)) < 1, "PDF width differs from document")
                    source.evaluateJavaScript("!!document.getElementById('__nfMacBreadcrumbBar') && document.documentElement.dataset.nfMacSidebarCollapsed === 'true'") { [weak self] value, error in
                        guard let self else { return }
                        do { try check(error == nil && value as? Bool == true, "export changed source pane navigation"); finish(nil) }
                        catch { finish(error.localizedDescription) }
                    }
                } catch { finish(error.localizedDescription) }
            }
        }
    }

    func finish(_ error: String?) { failure = error; finished = true }
    func close() { windows.forEach { $0.close() }; windows.removeAll(); popup = nil; source = nil }
}

@main struct PDFShareRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let directory = URL(fileURLWithPath: payload["directory"] as! String)
        var checks = 0
        for fixture in payload["fixtures"] as! [[String: Any]] {
            let test = PDFShareFixture(fixture: fixture, bootstrap: payload["bootstrap"] as! String, directory: directory)
            let deadline = Date().addingTimeInterval(10)
            while !test.finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            guard test.finished, test.failure == nil else { print("FAIL \(fixture["name"]!): \(test.failure ?? "Timed out")"); test.close(); exit(1) }
            checks += test.checks; print("PASS \(fixture["name"]!): \(test.checks)"); test.close()
        }
        print("PDF sharing: \(checks) checks passed")
    }
}
