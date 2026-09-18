import AppKit
import SwiftUI
import WebKit

struct MacMarkdownPreviewView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedMarkdown != markdown else { return }
        context.coordinator.loadedMarkdown = markdown

        guard let templateURL = Bundle.main.url(forResource: "MacMarkdownPreview", withExtension: "html"),
              let parserURL = Bundle.main.url(forResource: "MacMarkdownMarked", withExtension: "js"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8),
              let parser = try? String(contentsOf: parserURL, encoding: .utf8) else {
            webView.loadHTMLString("<body style='background:#1b252f;color:white;font:16px system-ui;padding:24px'>Markdown 미리보기를 불러오지 못했습니다.</body>", baseURL: nil)
            return
        }

        let html = template
            .replacingOccurrences(of: "<!-- MARKED_LIBRARY -->", with: "<script>\(parser)</script>")
            .replacingOccurrences(of: "MARKDOWN_BASE64_PLACEHOLDER", with: Data(markdown.utf8).base64EncodedString())
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedMarkdown: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
