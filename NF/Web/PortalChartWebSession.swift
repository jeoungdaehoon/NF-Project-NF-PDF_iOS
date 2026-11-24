import Combine
import Foundation
import WebKit

/// Own the chart editor across attachment viewer layout and fullscreen changes.
@MainActor
final class PortalChartWebSession: ObservableObject {
    private(set) var webView: WKWebView?
    private var requestedURL: URL?

    func view(for url: URL) -> WKWebView {
        if let webView, requestedURL == url { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        requestedURL = url
        webView = view
        view.load(URLRequest(url: url))
        return view
    }

    func export(_ format: String, from url: URL) async throws -> (name: String, data: Data) {
        guard let webView, requestedURL == url else { throw Self.failure("NF 차트 연결이 닫혔습니다. 차트를 다시 열어 주세요.") }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        repeat {
            try Task.checkCancellation()
            guard self.webView === webView, requestedURL == url else {
                throw Self.failure("내보내는 중에 차트가 바뀌었습니다.")
            }
            if Self.matches(webView.url, chart: url) {
                let response = try await webView.callAsyncJavaScript(
                    """
                    const chart = document.querySelector('main[data-nf-chart-file]');
                    if (!chart || chart.dataset.nfChartFile !== sourceId || typeof window.__nfChartExport !== 'function') {
                        return {pending: true};
                    }
                    return await window.__nfChartExport(format, sourceId);
                    """,
                    arguments: ["format": format, "sourceId": url.lastPathComponent], in: nil, contentWorld: .page
                )
                try Task.checkCancellation()
                guard self.webView === webView, Self.matches(webView.url, chart: url),
                      let result = response as? [String: Any] else {
                    throw Self.failure("차트 내보내기 응답을 읽지 못했습니다.")
                }
                if result["pending"] as? Bool != true {
                    if let error = result["error"] as? String { throw Self.failure(error) }
                    guard let name = result["filename"] as? String, (name as NSString).pathExtension.lowercased() == format,
                          let base64 = result["base64"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty else {
                        throw Self.failure("내보낼 파일을 생성하지 못했습니다.")
                    }
                    return (name, data)
                }
            } else if webView.url != nil && !webView.isLoading {
                throw Self.failure("이 창에서 내보낼 NF 차트를 확인하지 못했습니다. 차트를 다시 열어 주세요.")
            }
            try await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline
        throw Self.failure("차트 내보내기를 준비하지 못했습니다. 차트를 새로 열어 다시 시도해 주세요.")
    }

    func save(from url: URL) async -> Bool {
        guard let webView, requestedURL == url, Self.matches(webView.url, chart: url) else { return true }
        return (try? await webView.callAsyncJavaScript(
            "return typeof window.__nfChartSave !== 'function' || await window.__nfChartSave();",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool) == true
    }

    private static func matches(_ loaded: URL?, chart: URL) -> Bool {
        guard let loaded, let actual = URLComponents(url: loaded, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: chart, resolvingAgainstBaseURL: false) else { return false }
        return actual.scheme == "https" && expected.scheme == actual.scheme && actual.host == expected.host
            && (actual.port ?? 443) == (expected.port ?? 443) && actual.user == nil && actual.password == nil
            && actual.percentEncodedPath == expected.percentEncodedPath
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NF.ChartWebSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
