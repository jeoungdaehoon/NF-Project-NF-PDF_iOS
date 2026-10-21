import AppKit
import WebKit

@MainActor private final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let pane: String
    let router: MacPortalSlideRouter
    var loaded = false
    var opens: [String] = []
    init(pane: String, router: MacPortalSlideRouter) { self.pane = pane; self.router = router }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let record = message.body as? [String: Any] {
            if record["action"] as? String == "open", let id = record["id"] as? String { opens.append(id) }
            router.receive(record, from: pane)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}

/// Actual production router + source/session/receiver JavaScript in two isolated WKWebViews.
/// Document controls and server saves are mocks. No network, real account or user document is used.
@main struct MacSlideRoutingRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        let suite = "nf.slide-routing-test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = MacPortalBrowserModel(identifier: "primary", defaults: defaults)
        let secondary = MacPortalBrowserModel(identifier: "secondary", defaults: defaults)
        let router = MacPortalSlideRouter()
        let bundle = try String(contentsOfFile: CommandLine.arguments.dropFirst().first ?? "/private/tmp/nf-mac-slide-fixture.js", encoding: .utf8)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw NSError(domain: "SlideRouting", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1500, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.frame); window.contentView = content
        let bridges = [Bridge(pane: "primary", router: router), Bridge(pane: "secondary", router: router)]
        let webViews = bridges.enumerated().map { index, bridge -> WKWebView in
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(bridge, name: "NFPortalMacSlideRouting")
            let web = WKWebView(frame: CGRect(x: index * 750, y: 0, width: 750, height: 800), configuration: configuration)
            web.navigationDelegate = bridge; content.addSubview(web)
            let html = "<html><meta charset=utf-8><style>body{margin:0;background:#171717;color:white}input,textarea{display:block;width:95%;margin-bottom:10px}textarea{height:150px}button{padding:8px}#page{height:35px}</style><div id=page>\(bridge.pane) 기존 페이지 유지</div><div id=app></div><script>\(bundle.replacingOccurrences(of: "</script", with: "<\\/script"))</script></html>"
            web.loadHTMLString(html, baseURL: URL(string: MacPortalConfig.origin))
            return web
        }
        defer { window.close() }
        primary.webView = webViews[0]; secondary.webView = webViews[1]
        try wait { bridges.allSatisfy(\.loaded) }
        func js(_ index: Int, _ script: String) throws -> Any? {
            var result: Result<Any?, Error>?
            webViews[index].evaluateJavaScript(script) { value, error in result = error.map { .failure($0) } ?? .success(value) }
            try wait { result != nil }; return try result!.get()
        }
        func configure(_ destination: MacPortalSlideDestination, split: Bool = true) throws {
            router.configure(primary: primary, secondary: secondary, destination: destination, isSplit: split)
            for index in 0...1 {
                let model = index == 0 ? primary : secondary
                _ = try js(index, MacPortalWebView.slideConfigurationScript(model.slideRoutingConfiguration))
            }
        }
        for split in [false, true] { for source in [MacPortalPaneSelection.primary, .secondary] { for destination in MacPortalSlideDestination.allCases {
            let expected: MacPortalPaneSelection = !split ? .primary : destination == .current ? source : destination == .right ? .secondary : .primary
            try check(destination.pane(source: source, isSplit: split) == expected, "destination mapping \(destination.rawValue) / \(source.rawValue) / split=\(split)")
        } } }
        let preferences = MacPortalPreferences(defaults: defaults); preferences.slideDestination = .left
        try check(MacPortalPreferences(defaults: defaults).slideDestination == .left, "chosen slide destination survives preferences reload")
        let pagesBefore = [primary.pages, secondary.pages], idsBefore = [primary.activePageID, secondary.activePageID]
        try configure(.right)
        _ = try js(1, "fixture.target()")
        _ = try js(0, "fixture.source()")
        try wait { (try? js(1, "!!document.getElementById('remote-content')")) as? Bool == true }
        try check(try js(0, "!document.getElementById('local-slide')") as? Bool == true, "left click opens no duplicate source slide")
        try check(try js(1, "document.getElementById('remote-content').value") as? String == "원래 내용", "right pane receives original content without navigating")
        _ = try js(1, "fixture.edit('content','오른쪽에서 입력한 한글');fixture.edit('title','변경된 제목')")
        try wait { (try? js(0, "fixture.saved === '오른쪽에서 입력한 한글' && fixture.savedTitle === '변경된 제목'")) as? Bool == true }
        try check(try js(0, "document.getElementById('chart-content').textContent") as? String == "오른쪽에서 입력한 한글", "remote edit updates the original live chart and its existing autosave")
        try check(try js(0, "document.getElementById('unrelated-cell').textContent") as? String == "보존", "unrelated original chart cells remain intact")
        _ = try js(1, "fixture.click('추가 기능')")
        try wait { (try? js(0, "document.getElementById('chart-title').textContent === '헤더 편집 성공'")) as? Bool == true }
        try check(true, "header action invokes the original callback rather than a copied DOM handler")
        _ = try js(0, "fixture.fail=true")
        _ = try js(1, "fixture.edit('content','저장 실패 시 보존할 내용')")
        try wait { (try? js(1, "!!document.querySelector('[data-mac-slide-save-error]')")) as? Bool == true }
        _ = try js(1, "fixture.click('문서 닫기')"); pump(0.3)
        try check(try js(1, "document.getElementById('remote-content').value") as? String == "저장 실패 시 보존할 내용", "save failure retains the draft and blocks close")
        _ = try js(0, "fixture.fail=false")
        _ = try js(1, "fixture.click('다시 저장')")
        try wait { (try? js(0, "fixture.saved === '저장 실패 시 보존할 내용'")) as? Bool == true }
        _ = try js(1, "fixture.click('문서 닫기')")
        try wait { !router.hasOpenSlides }
        try check(try js(1, "!document.getElementById('remote-content')") as? Bool == true, "close clears the receiver after original autosave acknowledgement")
        try check(try js(0, "fixture.closeCount") as? Int == 1, "source close callback runs once")
        try check([primary.pages, secondary.pages] == pagesBefore && [primary.activePageID, secondary.activePageID] == idsBefore, "both tab lists and selected pages stay unchanged")
        try check(try js(0, "document.getElementById('page').textContent") as? String == "primary 기존 페이지 유지", "left underlying page remains present")
        try check(try js(1, "document.getElementById('page').textContent") as? String == "secondary 기존 페이지 유지", "right underlying page remains present")
        try configure(.left)
        _ = try js(0, "fixture.target()")
        _ = try js(1, "fixture.source()")
        try wait { (try? js(0, "!!document.getElementById('remote-content')")) as? Bool == true }
        _ = try js(0, "fixture.edit('content','왼쪽 고정도 동일하게 저장')")
        try wait { (try? js(1, "fixture.saved === '왼쪽 고정도 동일하게 저장'")) as? Bool == true }
        try check(true, "right-to-left routing uses the same source-owned save path")
        _ = try js(1, "fixture.unmount()")
        try wait { (try? js(0, "document.getElementById('remote-content').readOnly")) as? Bool == true }
        try check(try js(0, "document.getElementById('remote-content').value") as? String == "왼쪽 고정도 동일하게 저장", "closing original page retains a copyable read-only receiver draft")
        _ = try js(0, "fixture.click('문서 닫기')")
        try wait { !router.hasOpenSlides }
        try configure(.current)
        _ = try js(0, "fixture.source()")
        try wait { (try? js(0, "!!document.getElementById('local-slide')")) as? Bool == true }
        try check(!router.hasRoutedSlides && router.hasOpenSlides, "current-page mode uses a local slide and protects it from split teardown")
        _ = try js(0, "fixture.unmount()")
        try wait { !router.hasOpenSlides }
        try configure(.right)
        _ = try js(1, "fixture.target()")
        secondary.webView = nil
        _ = try js(0, "fixture.source()")
        pump(0.4)
        try check(router.hasRoutedSlides, "open request queues while the selected WebView is unavailable")
        secondary.webView = webViews[1]
        router.receive(["action": "ready"], from: "secondary")
        try wait { (try? js(1, "!!document.getElementById('remote-content')")) as? Bool == true }
        try check(true, "queued request opens when selected pane becomes ready")
        let id = bridges[0].opens.last!
        router.receive(["action": "invoke", "id": id, "token": UUID().uuidString, "operation": "content", "args": ["잘못된 발신자"]], from: "primary")
        pump(0.1)
        try check(try js(0, "document.getElementById('chart-content').textContent") as? String == "원래 내용", "mutation from the source rather than the designated receiver is rejected")
        _ = try js(1, "fixture.click('문서 닫기')")
        try wait { !router.hasOpenSlides }
        var failures = 0; router.onFailure = { _ in failures += 1 }
        _ = try js(1, "window.__nfMacReceiveSlide=()=>false;true")
        _ = try js(0, "fixture.unmount();fixture.source()")
        try wait(timeout: 14) { failures == 1 }
        try check(!router.hasOpenSlides, "unsupported receiver times out explicitly without displaying the slide in a wrong pane")
        print("PASS \(checks) slide routing checks across two actual WKWebViews")
    }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    @MainActor static func wait(timeout: TimeInterval = 15, _ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try condition() { return }; pump(0.02) }
        throw NSError(domain: "SlideRouting", code: 999, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fixture state"])
    }
}
