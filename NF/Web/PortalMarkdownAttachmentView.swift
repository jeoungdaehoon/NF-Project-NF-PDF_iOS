import Combine
import SwiftUI
import UIKit
import WebKit

enum PortalMarkdownAttachment {
    static func isMarkdownFileName(_ name: String) -> Bool {
        ["md", "markdown", "mdown"].contains((name as NSString).pathExtension.lowercased())
    }

    static func isMarkdown(_ response: URLResponse) -> Bool {
        let mimeType = response.mimeType?.lowercased() ?? ""
        return ["text/markdown", "text/x-markdown"].contains(mimeType)
            || isMarkdownFileName(response.suggestedFilename ?? "")
    }

    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
}

@MainActor
final class PortalMarkdownPreviewController: ObservableObject {
    @Published var isReady = false
    weak var webView: WKWebView?
}

struct PortalMarkdownAttachmentView: View {
    let markdown: String
    let title: String
    let onClose: () -> Void
    @StateObject private var controller = PortalMarkdownPreviewController()
    @State private var pdfShareItem: PortalPDFShareItem?
    @State private var shareError: String?
    @State private var isSharing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 38, height: 42)
                }
                .accessibilityLabel("첨부 미리보기 닫기")
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: shareRenderedPDF) {
                    Group {
                        if isSharing { ProgressView().tint(.white) }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .frame(width: 38, height: 42)
                }
                .disabled(!controller.isReady || isSharing)
                .accessibilityLabel("PDF 외부 공유하기")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .background(Color(red: 0.11, green: 0.15, blue: 0.19))

            PortalMarkdownWebView(markdown: markdown, controller: controller)
        }
        .background(Color(red: 0.11, green: 0.15, blue: 0.19))
        .sheet(item: $pdfShareItem) { item in
            PortalPDFActivityView(fileURL: item.fileURL)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("PDF 공유 파일을 만들지 못했습니다.", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("확인", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "다시 시도해 주세요.")
        }
    }

    private func shareRenderedPDF() {
        guard controller.isReady, !isSharing, let webView = controller.webView else { return }
        isSharing = true
        let configuration = WKPDFConfiguration()
        let contentSize = webView.scrollView.contentSize
        configuration.rect = CGRect(
            x: 0, y: 0,
            width: max(max(contentSize.width, webView.bounds.width), 1),
            height: max(max(contentSize.height, webView.bounds.height), 1)
        )
        webView.createPDF(configuration: configuration) { result in
            DispatchQueue.main.async {
                do {
                    let data = try result.get()
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NF-Markdown-PDF-Share", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let baseName = (title as NSString).deletingPathExtension
                        .components(separatedBy: CharacterSet(charactersIn: "/:\0"))
                        .joined(separator: "-")
                    let url = directory.appendingPathComponent("\(baseName.isEmpty ? "문서" : baseName).pdf")
                    try data.write(to: url, options: .atomic)
                    pdfShareItem = PortalPDFShareItem(fileURL: url)
                } catch {
                    shareError = error.localizedDescription
                }
                isSharing = false
            }
        }
    }
}

private struct PortalMarkdownWebView: UIViewRepresentable {
    let markdown: String
    @ObservedObject var controller: PortalMarkdownPreviewController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.11, green: 0.15, blue: 0.19, alpha: 1)
        controller.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedMarkdown != markdown else { return }
        context.coordinator.loadedMarkdown = markdown
        controller.isReady = false

        guard let templateURL = Bundle.main.url(forResource: "PortalMarkdownPreview", withExtension: "html"),
              let parserURL = Bundle.main.url(forResource: "PortalMarkdownMarked", withExtension: "js"),
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
        let controller: PortalMarkdownPreviewController
        var loadedMarkdown: String?

        init(controller: PortalMarkdownPreviewController) { self.controller = controller }

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
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
