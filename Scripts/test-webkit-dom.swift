import AppKit
import WebKit

// Isolated WKWebView DOM/layout tests. No application data or network access.
final class WebKitDOMTest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var finished = false
    var status: Int32 = 1
    let script: String
    var window: NSWindow!
    var webView: WKWebView!

    init(html: String, script: String) {
        self.script = script
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "testResult")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1500, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.contentView = webView
        window.orderFront(nil)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { _, error in
            if let error = error { self.finish(["error": error.localizedDescription], success: false) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        finish(message.body, success: true)
    }

    func finish(_ result: Any, success: Bool) {
        guard !finished else { return }
        if let text = result as? String { print(text) }
        else if let data = try? JSONSerialization.data(withJSONObject: result), let text = String(data: data, encoding: .utf8) { print(text) }
        status = success ? 0 : 1
        finished = true
        window.close()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: String]
let test = WebKitDOMTest(html: payload["html"]!, script: payload["script"]!)
let deadline = Date().addingTimeInterval(20)
while !test.finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
if !test.finished { print("{\"error\":\"WebKit DOM test timed out\"}") }
exit(test.status)
