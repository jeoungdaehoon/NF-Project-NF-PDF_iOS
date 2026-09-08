import UIKit
import WebKit

/// CloudKit의 window.open / opener.postMessage / window.close 수명주기를 유지합니다.
final class PortalCloudAuthPopup: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?
    private var closing = false

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "iCloud 연결"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "취소", style: .plain, target: self, action: #selector(cancelAuthentication)
        )
    }

    static func allows(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["apple.com", "icloud.com", "apple-cloudkit.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, Self.allows(url) else {
            decisionHandler(.cancel)
            showError("허용되지 않은 인증 주소입니다. 취소 후 다시 연결해 주세요.")
            return
        }
        decisionHandler(.allow)
    }

    func webViewDidClose(_ webView: WKWebView) { closePopup() }

    @objc private func cancelAuthentication() {
        // 원본 웹 페이지의 popup.closed 감시도 취소를 감지하게 합니다.
        webView.evaluateJavaScript("window.close()") { [weak self] _, _ in self?.closePopup() }
    }

    func closePopup() {
        guard !closing else { return }
        closing = true
        webView.stopLoading()
        navigationController?.dismiss(animated: true)
        onClose?()
        onClose = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError("인증 페이지를 열지 못했습니다. 네트워크를 확인한 뒤 다시 연결해 주세요.") }
    }

    private func showError(_ message: String) {
        guard !closing, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "iCloud 연결", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default))
        present(alert, animated: true)
    }
}
