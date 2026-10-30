import XCTest
import WebKit
@testable import NF

@MainActor
final class PortalWorkspaceViewportTests: XCTestCase {
    func testNativeResizeNotifiesAfterLayoutAndKeepsFixedContentFillingPane() async throws {
        let webView = PortalWorkspaceWebView(frame: CGRect(x: 0, y: 0, width: 680, height: 900))
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(webView)
        defer { webView.removeFromSuperview(); window.isHidden = true }
        webView.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:#171717}#calendar{position:fixed;left:0;top:0;width:var(--portal-viewport-width,100vw);height:var(--portal-viewport-height,100dvh);background:#222}</style>
        <input id="draft" value="수정 중인 문서"><div id="calendar"></div>
        <script>window.layoutEvents=0;addEventListener('nfPortalNativeViewportChange',()=>{window.layoutEvents++;const v=window.__nfNativeViewport;if(v){document.documentElement.style.setProperty('--portal-viewport-width',v.width+'px');document.documentElement.style.setProperty('--portal-viewport-height',v.height+'px')}});</script>
        """, baseURL: nil)
        for _ in 0..<200 {
            if (try? await webView.evaluateJavaScript("typeof window.layoutEvents === 'number'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let eventType = try await webView.evaluateJavaScript("typeof window.layoutEvents") as? String
        XCTAssertEqual(eventType, "number")
        for zoom in [0.8, 1.0, 1.35] {
            webView.pageZoom = zoom
            webView.invalidateWorkspaceViewport()
            for width in [400.0, 950.0, 500.0, 680.0] {
                let before = try await webView.evaluateJavaScript("window.layoutEvents") as! Int
                webView.frame.size = CGSize(width: width, height: 850)
                webView.setNeedsLayout()
                webView.layoutIfNeeded()
                var delivered = false
                for _ in 0..<100 {
                    if let events = try await webView.evaluateJavaScript("window.layoutEvents") as? Int, events > before { delivered = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertTrue(delivered, "resize notification missing at \(width), zoom \(zoom)")
                let rect = try await webView.evaluateJavaScript("(()=>{const r=document.getElementById('calendar').getBoundingClientRect();return {width:r.width,height:r.height,draft:document.getElementById('draft').value}})()") as! [String: Any]
                XCTAssertEqual((rect["width"] as! Double) * zoom, width, accuracy: 2)
                XCTAssertEqual((rect["height"] as! Double) * zoom, 850, accuracy: 2)
                XCTAssertEqual(rect["draft"] as? String, "수정 중인 문서")
            }
        }
    }
}
