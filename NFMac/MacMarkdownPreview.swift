import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class MacMarkdownPreviewController: ObservableObject {
    @Published var isReady = false
    @Published var isSharing = false
    weak var webView: WKWebView?
    private var sharingPicker: NSSharingServicePicker?

    func sharePDF(fileName: String) {
        guard isReady, !isSharing, let webView else { return }
        isSharing = true
        webView.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)") { [weak self, weak webView] value, error in
            guard let self, let webView else { return }
            if let error {
                self.showShareError(error)
                return
            }
            let pageHeight = max((value as? NSNumber)?.doubleValue ?? 0, webView.bounds.height)
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: max(webView.bounds.width, 1), height: pageHeight)
            webView.createPDF(configuration: configuration) { [weak self, weak webView] result in
                guard let self, let webView else { return }
                do {
                    let data = try result.get()
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NF-Markdown-PDF-Share", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = (fileName as NSString).deletingPathExtension
                        .components(separatedBy: CharacterSet(charactersIn: "/:\0"))
                        .joined(separator: "-")
                    let url = directory.appendingPathComponent(name.isEmpty ? "문서.pdf" : "\(name).pdf")
                    try data.write(to: url, options: .atomic)
                    let picker = NSSharingServicePicker(items: [url])
                    self.sharingPicker = picker
                    let topY = webView.isFlipped ? webView.bounds.minY + 20 : webView.bounds.maxY - 20
                    picker.show(relativeTo: NSRect(x: webView.bounds.maxX - 20, y: topY, width: 1, height: 1), of: webView, preferredEdge: .minY)
                    self.isSharing = false
                } catch {
                    self.showShareError(error)
                }
            }
        }
    }

    private func showShareError(_ error: Error) {
        isSharing = false
        let alert = NSAlert()
        alert.messageText = "PDF 공유 파일을 만들지 못했습니다."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

struct MacMarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    @ObservedObject var controller: MacMarkdownPreviewController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        controller.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedMarkdown != markdown else { return }
        context.coordinator.loadedMarkdown = markdown
        controller.isReady = false

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
        let controller: MacMarkdownPreviewController
        var loadedMarkdown: String?

        init(controller: MacMarkdownPreviewController) { self.controller = controller }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.isReady = true
        }

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
