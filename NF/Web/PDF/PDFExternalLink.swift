import Combine
import SwiftUI
import WebKit

struct PDFExternalLinkPicker: View {
    let onSelect: (PDFExternalLink) -> Void
    let onClose: () -> Void
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let link = PDFExternalLink(address)
        VStack(alignment: .leading, spacing: 14) {
            Label("웹 URL 추가", systemImage: "link").font(.headline)
            TextField("웹 주소", text: $address, prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .accessibilityIdentifier("pdf.webLink.address")
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit { if let link { onSelect(link) } }
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link == nil {
                Text("유효한 HTTPS 주소를 입력해 주세요.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("링크 추가") { if let link { onSelect(link) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(link == nil)
                    .accessibilityIdentifier("pdf.webLink.add")
            }
        }
        .padding(20)
        .frame(idealWidth: 350, maxWidth: 420)
        .onAppear { addressFocused = true }
        #if os(iOS)
        .presentationDetents([.height(230), .medium])
        .presentationDragIndicator(.visible)
        #endif
    }
}

/// External markers use the same HTTPS address and classification as Android.
struct PDFExternalLink: Equatable {
    enum Kind: Equatable {
        case page
        case youtube(id: String, shorts: Bool)
        case video
    }

    let url: URL
    let kind: Kind

    init?(_ address: String?) {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty, address.utf16.count <= 4096,
              let url = URL(string: address, encodingInvalidCharacters: false),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        self.url = url
        let path = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let route = path.first
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com",
                            "youtube-nocookie.com", "www.youtube-nocookie.com"]
        var id: String?
        if host == "youtu.be", path.count == 1 {
            id = route
        } else if youtubeHosts.contains(host) {
            if route == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery?
                    .split(separator: "&").first(where: { $0.hasPrefix("v=") }).map { String($0.dropFirst(2)) }
            } else if let route, ["shorts", "embed", "live"].contains(route) {
                id = path.dropFirst().first
            }
        }
        if let id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            kind = .youtube(id: id, shorts: route == "shorts")
        } else {
            kind = ["mp4", "m4v", "webm", "m3u8"].contains(url.pathExtension.lowercased()) ? .video : .page
        }
    }

    var isVideo: Bool { kind != .page }
    var isYouTube: Bool { if case .youtube = kind { return true }; return false }
    var title: String {
        switch kind {
        case .page: url.host(percentEncoded: false) ?? url.absoluteString
        case .youtube: "YouTube 영상"
        case .video: "영상"
        }
    }
    var icon: String { isVideo ? "play.rectangle" : "link" }
    var openTitle: String { isYouTube ? "YouTube에서 열기" : "브라우저에서 열기" }

    func popupSize(width: CGFloat, height: CGFloat, header: CGFloat) -> CGSize {
        let aspect: CGFloat
        if case .youtube(_, true) = kind { aspect = 9 / 16 } else { aspect = 16 / 9 }
        let availableHeight = max(1, height - header)
        let availableWidth = min(520, width)
        let fittingWidth = min(availableWidth, availableHeight * aspect)
        let playerWidth = isYouTube ? max(fittingWidth, min(200, availableWidth)) : fittingWidth
        let playerHeight = min(availableHeight, isYouTube ? max(200, playerWidth / aspect) : playerWidth / aspect)
        return CGSize(width: playerWidth, height: min(height, header + playerHeight))
    }

    func playerHTML(origin: URL) -> String? {
        switch kind {
        case .page: return nil
        case .youtube(let id, _):
            var embed = URLComponents()
            embed.scheme = "https"
            embed.host = "www.youtube.com"
            embed.path = "/embed/" + id
            embed.queryItems = [.init(name: "enablejsapi", value: "1"), .init(name: "origin", value: origin.absoluteString),
                                .init(name: "playsinline", value: "1"), .init(name: "fs", value: "0"), .init(name: "autoplay", value: "0")]
            guard let playerURL = embed.url else { return nil }
            let address = escapeAttribute(playerURL.absoluteString)
            return """
            <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' https://www.youtube.com; frame-src https://www.youtube.com">
            <style>html,body{margin:0;background:#000;overflow:hidden} iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style>
            <iframe id="player" title="YouTube 영상" referrerpolicy="strict-origin-when-cross-origin"
             allow="autoplay; encrypted-media; picture-in-picture"
             src="\(address)"></iframe>
            <script>
            let player, visible = true, deadline;
            const title = status => { document.title = 'nf-pdf-video-' + status; };
            function fail() { clearTimeout(deadline); title('error'); }
            window.nfPDFSetVisible = value => { visible = value; if (!visible) { clearTimeout(deadline); player?.pauseVideo?.(); } };
            window.nfPDFToggle = () => {
                if (!visible || !player?.getPlayerState) return;
                if (player.getPlayerState() === 1) { player.pauseVideo(); return; }
                title('starting');
                clearTimeout(deadline);
                deadline = setTimeout(fail, 15000);
                player.playVideo();
            };
            function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {events:{
                    onReady: () => title('ready'),
                    onStateChange: ({data}) => {
                        if (!visible && (data === 1 || data === 3)) { player.pauseVideo(); return; }
                        if (data === 1) { clearTimeout(deadline); title('playing'); }
                        if (data === 0 || data === 2) { clearTimeout(deadline); title('ready'); }
                    },
                    onAutoplayBlocked: fail, onError: fail
                }});
            }
            </script>
            <script src="https://www.youtube.com/iframe_api" onerror="document.title='nf-pdf-video-error'"></script>
            """
        case .video:
            let address = escapeAttribute(url.absoluteString)
            return """
            <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https:; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
            <style>html,body{margin:0;background:#000;overflow:hidden} video{position:fixed;inset:0;width:100%;height:100%;object-fit:contain}</style>
            <video id="video" src="\(address)" playsinline controls preload="metadata"></video>
            <script>
            const video = document.getElementById('video');
            let visible = true;
            const title = status => { document.title = 'nf-pdf-video-' + status; };
            window.nfPDFSetVisible = value => { visible = value; if (!value) video.pause(); };
            window.nfPDFToggle = () => {
                if (!visible) return;
                if (video.paused) video.play().catch(() => title('error')); else video.pause();
            };
            video.oncanplay = () => { if (video.paused) title('ready'); };
            video.onplaying = () => { if (visible) title('playing'); else video.pause(); };
            video.onpause = video.onended = () => title('ready');
            video.onerror = () => title('error');
            </script>
            """
        }
    }

    private func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

@MainActor
final class PDFExternalLinkBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    enum Status: String { case loading, ready, starting, playing, error }

    @Published private(set) var status: Status = .loading
    private(set) var webView: WKWebView?
    private var link: PDFExternalLink?
    private var titleObservation: NSKeyValueObservation?
    private var visible = false
    private var firstPlayerNavigation = false

    func makeView(for link: PDFExternalLink, origin: URL) -> WKWebView {
        if let webView, self.link == link { return webView }
        self.link = link
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        if link.isVideo { configuration.mediaTypesRequiringUserActionForPlayback = [] }
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        if let html = link.playerHTML(origin: origin) {
            firstPlayerNavigation = true
            titleObservation = view.observe(\.title, options: [.new]) { [weak self] _, change in
                let owner = self
                let title = change.newValue ?? nil
                Task { @MainActor [weak owner] in owner?.playerStateChanged(title) }
            }
            view.loadHTMLString(html, baseURL: origin)
        } else {
            view.load(URLRequest(url: link.url))
        }
        Task { [weak self, weak view] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.webView === view, self.status == .loading else { return }
            self.status = .error
        }
        return view
    }

    func setVisible(_ value: Bool) {
        visible = value
        if link?.isVideo == true { webView?.evaluateJavaScript("window.nfPDFSetVisible?.(\(value))", completionHandler: nil) }
    }

    func togglePlayback() {
        webView?.evaluateJavaScript("window.nfPDFToggle?.()", completionHandler: nil)
    }

    private func playerStateChanged(_ title: String?) {
        let prefix = "nf-pdf-video-"
        guard let title, title.hasPrefix(prefix), let status = Status(rawValue: String(title.dropFirst(prefix.count))) else { return }
        self.status = status
        if !visible && (status == .ready || status == .playing) { setVisible(false) }
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if link?.isVideo == true {
            // WebKit loads local player HTML as about:blank. Block any later
            // top-level navigation from a video frame.
            if action.targetFrame?.isMainFrame != false {
                guard firstPlayerNavigation, action.navigationType == .other else { return .cancel }
                firstPlayerNavigation = false
                return .allow
            }
            return url.scheme?.lowercased() == "https" ? .allow : .cancel
        }
        guard PDFExternalLink(url.absoluteString) != nil else { return .cancel }
        if action.targetFrame == nil {
            view.load(action.request)
            return .cancel
        }
        return .allow
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame else { return .allow }
        let statusCode = (response.response as? HTTPURLResponse)?.statusCode ?? 200
        if statusCode >= 400 || !response.canShowMIMEType {
            status = .error
            return .cancel
        }
        return .allow
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        if link?.isVideo != true { status = .ready }
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showFailure(error) }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showFailure(error) }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) { status = .error }

    private func showFailure(_ error: Error) {
        if (error as? URLError)?.code != .cancelled { status = .error }
    }
}

struct PDFExternalLinkContent {
    let link: PDFExternalLink
    let origin: URL
    let browser: PDFExternalLinkBrowser
}

#if os(macOS)
extension PDFExternalLinkContent: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { browser.makeView(for: link, origin: origin) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension PDFExternalLinkContent: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { browser.makeView(for: link, origin: origin) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
