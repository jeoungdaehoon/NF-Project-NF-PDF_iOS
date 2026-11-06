import XCTest
import WebKit
@testable import NF

@MainActor
final class PortalNativeAIBridgeTests: XCTestCase {
    func testWKWebViewAdvertisesNewFeaturesAndReceivesModelStatus() async throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: PortalNativeFeatureScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.loadHTMLString("<script>window.bridgeReply=null;addEventListener('nf-meeting-result',event=>{window.bridgeReply=event.detail});window.fixtureReady=true;</script>", baseURL: PortalConfig.portalDashboardURL)
        for _ in 0..<200 {
            if (try? await webView.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(webView.url?.host, PortalConfig.portalHost)
        let advertised = try await webView.evaluateJavaScript("window.NFNativeCapabilities.projectSearch && window.NFNativeCapabilities.generatedReportFiles") as? Bool
        XCTAssertEqual(advertised, true)
        await PortalMeeting.shared.handle(["requestId": "synthetic-status", "operation": "projectSearchStatus"], webView: webView)
        let response = try await webView.evaluateJavaScript("window.bridgeReply") as? [String: Any]
        XCTAssertEqual(response?["requestId"] as? String, "synthetic-status")
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNotNil(result["answer"] as? Bool)
        XCTAssertEqual(result["downloadable"] as? Bool, false)
        if result["answer"] as? Bool == false { XCTAssertFalse((result["reason"] as? String ?? "").isEmpty) }
    }
}
