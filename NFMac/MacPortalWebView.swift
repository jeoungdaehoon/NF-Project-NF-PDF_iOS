import AppKit
import SwiftUI
import WebKit

struct MacPortalWebView: NSViewRepresentable {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var preferences: MacPortalPreferences
    let onFocus: () -> Void
    let onSidebarNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            preferences: preferences,
            onFocus: onFocus,
            onSidebarNavigate: onSidebarNavigate
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(context.coordinator, name: "NFPortalMacNavigation")
        controller.add(context.coordinator, name: "NFPortalIOSGoogleLogin")
        controller.add(context.coordinator, name: "NFPortalIOSLogout")
        controller.add(context.coordinator, name: "NFPortalIOSPDFLocalStorage")
        controller.add(context.coordinator, name: "NFPortalIOSPDFDocuments")
        controller.add(context.coordinator, name: "NFPortalMacPageZoom")
        controller.add(context.coordinator, name: "NFPortalMacPaneFocus")
        controller.add(context.coordinator, name: "NFPortalMacSidebarNavigation")
        controller.add(context.coordinator, name: "NFPortalMacSidebarHover")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.applicationNameForUserAgent = "NFPortalMac/\(MacAppVersion.number)"
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = CGFloat(preferences.zoomPercent) / 100
        webView.appearance = preferences.appearance.webAppearance
        context.coordinator.lastAppliedZoomPercent = preferences.zoomPercent
        context.coordinator.lastAppliedAppearance = preferences.appearance
        context.coordinator.lastAppliedPDFLocalStorageEnabled = preferences.pdfLocalStorageEnabled
        context.coordinator.lastAppliedPDFDocumentCount = model.localPDFDocumentCount
        model.connect(webView)

        var request = URLRequest(url: model.startURL())
        request.setValue("ko-KR,ko;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.preferences = preferences
        context.coordinator.onFocus = onFocus
        context.coordinator.onSidebarNavigate = onSidebarNavigate
        if model.webView !== webView { model.connect(webView) }
        if context.coordinator.lastAppliedZoomPercent != preferences.zoomPercent {
            webView.pageZoom = CGFloat(preferences.zoomPercent) / 100
            context.coordinator.lastAppliedZoomPercent = preferences.zoomPercent
            webView.evaluateJavaScript("""
            try { localStorage.setItem('nfPortalMacPageZoom', '\(preferences.zoomPercent)'); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: \(preferences.zoomPercent) } }));
            """)
        }
        if context.coordinator.lastAppliedAppearance != preferences.appearance {
            webView.appearance = preferences.appearance.webAppearance
            context.coordinator.lastAppliedAppearance = preferences.appearance
            let scheme = preferences.appearance == .dark ? "dark" : preferences.appearance == .light ? "light" : "normal"
            webView.evaluateJavaScript("document.documentElement.style.colorScheme='\(scheme)';")
        }
        if context.coordinator.lastAppliedPDFLocalStorageEnabled != preferences.pdfLocalStorageEnabled
            || context.coordinator.lastAppliedPDFDocumentCount != model.localPDFDocumentCount {
            context.coordinator.deliverPDFState(to: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        [
            "NFPortalMacNavigation",
            "NFPortalIOSGoogleLogin",
            "NFPortalIOSLogout",
            "NFPortalIOSPDFLocalStorage",
            "NFPortalIOSPDFDocuments",
            "NFPortalMacPageZoom",
            "NFPortalMacPaneFocus",
            "NFPortalMacSidebarNavigation",
            "NFPortalMacSidebarHover",
        ]
            .forEach(controller.removeScriptMessageHandler(forName:))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var model: MacPortalBrowserModel
        var preferences: MacPortalPreferences
        var onFocus: () -> Void
        var onSidebarNavigate: (URL) -> Void
        var lastAppliedZoomPercent: Int?
        var lastAppliedAppearance: MacPortalAppearance?
        var lastAppliedPDFLocalStorageEnabled: Bool?
        var lastAppliedPDFDocumentCount: Int?

        init(
            model: MacPortalBrowserModel,
            preferences: MacPortalPreferences,
            onFocus: @escaping () -> Void,
            onSidebarNavigate: @escaping (URL) -> Void
        ) {
            self.model = model
            self.preferences = preferences
            self.onFocus = onFocus
            self.onSidebarNavigate = onSidebarNavigate
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.connect(webView)
            model.record(url: webView.url ?? MacPortalConfig.dashboardURL, title: webView.title)
            webView.evaluateJavaScript("""
            try { localStorage.setItem('nfPortalMacPageZoom', '\(preferences.zoomPercent)'); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: \(preferences.zoomPercent) } }));
            window.__nfMacNotifyNavigation && window.__nfMacNotifyNavigation(0);
            """)
            deliverPDFState(to: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.refreshNavigationState()
            model.applySidebarVisibility()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == MacPortalConfig.callbackScheme {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            if url == MacPortalConfig.googleLoginURL {
                model.onGoogleLogin?()
                decisionHandler(.cancel)
                return
            }
            if isAttachmentNavigationURL(url) {
                presentAttachmentPreview(url, from: webView)
                decisionHandler(.cancel)
                return
            }
            if let scheme = url.scheme, !["http", "https", "about", "blob", "data"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isAttachmentNavigationURL(url) { presentAttachmentPreview(url, from: webView) }
                else if MacPortalConfig.isPortalURL(url) { webView.load(URLRequest(url: url)) }
                else { NSWorkspace.shared.open(url) }
            }
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) { model.refreshNavigationState() }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "NFPortalMacNavigation":
                guard let record = message.body as? [String: Any],
                      let rawURL = record["url"] as? String,
                      let url = URL(string: rawURL) else { return }
                let title = record["title"] as? String
                let breadcrumbs = record["breadcrumbs"] as? [[String: Any]] ?? []
                model.record(url: url, title: title, breadcrumbRecords: breadcrumbs)
                model.updateTheme(
                    background: record["background"] as? String,
                    foreground: record["foreground"] as? String
                )
            case "NFPortalIOSGoogleLogin":
                model.onGoogleLogin?()
            case "NFPortalIOSLogout":
                model.onLogout?()
            case "NFPortalIOSPDFLocalStorage":
                if let enabled = boolValue(from: message.body) {
                    preferences.pdfLocalStorageEnabled = enabled
                    deliverPDFState(to: model.webView)
                }
            case "NFPortalIOSPDFDocuments":
                model.onOpenPDFDocuments?()
            case "NFPortalMacPageZoom":
                if let value = message.body as? NSNumber {
                    preferences.zoomPercent = value.intValue
                } else if let record = message.body as? [String: Any], let value = record["percent"] as? NSNumber {
                    preferences.zoomPercent = value.intValue
                }
            case "NFPortalMacPaneFocus":
                onFocus()
            case "NFPortalMacSidebarNavigation":
                guard let record = message.body as? [String: Any],
                      let rawURL = record["url"] as? String,
                      let url = URL(string: rawURL) else { return }
                onSidebarNavigate(url)
            case "NFPortalMacSidebarHover":
                if let record = message.body as? [String: Any] {
                    let hovering = (record["hovering"] as? NSNumber)?.boolValue ?? false
                    let width = (record["width"] as? NSNumber).map { CGFloat(truncating: $0) }
                    model.setWebSidebarHover(hovering, width: width)
                } else if let hovering = message.body as? Bool {
                    model.setWebSidebarHover(hovering)
                }
            default:
                break
            }
        }

        func deliverPDFState(to webView: WKWebView?) {
            guard let webView else { return }
            let enabled = preferences.pdfLocalStorageEnabled ? "true" : "false"
            let count = max(0, model.localPDFDocumentCount)
            lastAppliedPDFLocalStorageEnabled = preferences.pdfLocalStorageEnabled
            lastAppliedPDFDocumentCount = count
            webView.evaluateJavaScript("""
            (function() {
                var enabled = \(enabled);
                var count = \(count);
                window.__NF_PORTAL_PDF_LOCAL_STORAGE_ENABLED__ = enabled;
                window.__NF_PORTAL_LOCAL_PDF_DOCUMENT_COUNT__ = count;
                try {
                    localStorage.setItem('nfPortalPDFLocalStorageEnabled', String(enabled));
                    localStorage.setItem('nfPortalLocalPDFDocumentCount', String(count));
                } catch (_) {}
                window.dispatchEvent(new CustomEvent('nfPortalPDFLocalStorageState', {
                    detail: { platform: 'mac', enabled: enabled }
                }));
                window.dispatchEvent(new CustomEvent('nfPortalLocalPDFDocumentState', {
                    detail: { platform: 'mac', count: count }
                }));
            })();
            """)
        }

        private func boolValue(from body: Any) -> Bool? {
            if let value = body as? Bool { return value }
            if let value = body as? NSNumber { return value.boolValue }
            if let value = body as? String {
                if ["true", "1", "on"].contains(value.lowercased()) { return true }
                if ["false", "0", "off"].contains(value.lowercased()) { return false }
            }
            if let record = body as? [String: Any] {
                return record["enabled"].flatMap(boolValue(from:))
            }
            return nil
        }

        private func isAttachmentNavigationURL(_ url: URL) -> Bool {
            if url.path.hasPrefix("/api/artifacts/files") { return true }
            if url.pathExtension.lowercased() == "pdf" { return true }
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                $0.name.lowercased() == "download"
            }) == true { return true }
            return false
        }

        private func presentAttachmentPreview(_ url: URL, from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let host = url.host?.lowercased()
                let matching = cookies.filter { cookie in
                    guard let host else { return false }
                    let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    return host == domain || host.hasSuffix(".\(domain)")
                }
                let cookieHeader = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                Task { @MainActor in
                    self.model.onPreviewPDFAttachment?(MacPDFRemoteRequest(
                        url: url,
                        cookieHeader: cookieHeader.isEmpty ? nil : cookieHeader
                    ))
                }
            }
        }
    }

    private static let bootstrapScript = #"""
    (function() {
        document.documentElement.lang = 'ko-KR';
        document.documentElement.style.setProperty('-webkit-locale', '"ko-KR"');
        document.documentElement.setAttribute('data-nf-desktop-host', 'true');
        window.NFPortalIOS = window.NFPortalIOS || {};
        window.NFPortalIOS.setPDFLocalStorageEnabled = function(enabled) {
            window.webkit.messageHandlers.NFPortalIOSPDFLocalStorage.postMessage({ enabled: !!enabled });
        };
        window.NFPortalIOS.openPDFDocuments = function() {
            window.webkit.messageHandlers.NFPortalIOSPDFDocuments.postMessage('open');
        };

        function installDesktopHostStyle() {
            if (document.getElementById('__nfMacDesktopHostStyle')) return;
            var style = document.createElement('style');
            style.id = '__nfMacDesktopHostStyle';
            style.textContent = `
                html[data-nf-desktop-host="true"] .portal-titlebar button[aria-controls="portal-navigation"],
                html[data-nf-desktop-host="true"] .portal-titlebar button[aria-label="탭바 열기"] {
                    display: none !important;
                }
                html[data-nf-desktop-host="true"] .mobile-navigation-overlay {
                    display: none !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) *:has(> #portal-navigation) {
                    display: grid !important;
                    grid-template-columns: 276px minmax(0, 1fr) !important;
                    width: 100% !important;
                    height: 100dvh !important;
                    min-height: 0 !important;
                    overflow: hidden !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) #portal-navigation {
                    display: block !important;
                    position: sticky !important;
                    inset: auto !important;
                    top: 0 !important;
                    width: 276px !important;
                    height: 100dvh !important;
                    align-self: start !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                    translate: none !important;
                    transform: none !important;
                    -webkit-transform: none !important;
                    animation: none !important;
                    box-shadow: none !important;
                }
                html[data-nf-desktop-host="true"]:not([data-nf-mac-sidebar-collapsed="true"]) #portal-content {
                    width: 100% !important;
                    min-width: 0 !important;
                    height: 100dvh !important;
                    min-height: 0 !important;
                    overflow-y: auto !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-navigation {
                    display: block !important;
                    position: fixed !important;
                    inset: 0 auto 0 0 !important;
                    top: 0 !important;
                    right: auto !important;
                    bottom: 0 !important;
                    left: 0 !important;
                    margin-left: 0 !important;
                    width: var(--nf-mac-sidebar-preview-width, 276px) !important;
                    height: 100% !important;
                    z-index: 90 !important;
                    visibility: visible !important;
                    opacity: 1 !important;
                    transform: translate3d(-100%, 0, 0) !important;
                    transition: transform 300ms cubic-bezier(0.22, 1, 0.36, 1) !important;
                    will-change: transform;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"][data-nf-mac-sidebar-preview="true"] #portal-navigation {
                    transform: none !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] #portal-content {
                    transform: translate3d(0, 0, 0) !important;
                    transition: transform 300ms cubic-bezier(0.22, 1, 0.36, 1) !important;
                    will-change: transform;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"][data-nf-mac-sidebar-preview="true"] #portal-content {
                    transform: translate3d(var(--nf-mac-sidebar-preview-width, 276px), 0, 0) !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"] {
                    top: 34px !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"][data-linked-document-fullscreen="true"] {
                    inset: 34px 0 0 !important;
                    height: auto !important;
                }
                html[data-nf-desktop-host="true"][data-nf-mac-sidebar-collapsed="true"] [data-linked-document-panel="true"] > [data-linked-document-body="true"] {
                    height: calc(100% - 56px) !important;
                }
            `;
            (document.head || document.documentElement).appendChild(style);
        }
        installDesktopHostStyle();

        function clean(value) { return String(value || '').replace(/\s+/g, ' ').trim(); }
        function currentTitle() {
            var navigation = document.getElementById('portal-navigation');
            if (navigation) {
                var current = location.pathname.replace(/\/$/, '') + location.search;
                var links = Array.from(navigation.querySelectorAll('a[href]'));
                var active = links.find(function(link) { return link.getAttribute('aria-current') === 'page'; }) ||
                    links.find(function(link) {
                        try { var u = new URL(link.href, location.href); return u.pathname.replace(/\/$/, '') + u.search === current; }
                        catch (_) { return false; }
                    });
                if (active) return clean((active.querySelector('span.truncate') || active.querySelector('span') || active).textContent);
            }
            return clean(document.title) || 'NF Portal';
        }
        function breadcrumbs() {
            var navigation = document.getElementById('portal-navigation');
            var home = { title: 'NF Portal', url: location.origin + '/' };
            if (!navigation) return [home, { title: currentTitle(), url: location.href }];
            var current = location.pathname.replace(/\/$/, '') + location.search;
            var links = Array.from(navigation.querySelectorAll('a[href]'));
            var active = links.find(function(link) { return link.getAttribute('aria-current') === 'page'; }) ||
                links.find(function(link) {
                    try { var u = new URL(link.href, location.href); return u.pathname.replace(/\/$/, '') + u.search === current; }
                    catch (_) { return false; }
                });
            if (!active) return [home, { title: currentTitle(), url: location.href }];
            var labels = [];
            var row = active.closest('[data-navigation-key], li, [role="treeitem"]') || active;
            var key = clean(row.getAttribute && row.getAttribute('data-navigation-key'));
            if (/[>›/]/.test(key)) labels = key.split(/\s*[>›/]\s*/).map(clean).filter(Boolean);
            var page = clean((active.querySelector('span.truncate') || active.querySelector('span') || active).textContent) || currentTitle();
            labels = labels.filter(function(label) { return label !== page; });
            labels.push(page);
            return [home].concat(labels.map(function(label, index) {
                return { title: label, url: index === labels.length - 1 ? active.href : null };
            }));
        }

        window.__nfMacSidebarHidden = false;
        window.__nfMacSetSidebarContentInset = function(reserved) {
            var requestToken = (window.__nfMacSidebarContentInsetToken || 0) + 1;
            window.__nfMacSidebarContentInsetToken = requestToken;
            function apply() {
                if (requestToken !== window.__nfMacSidebarContentInsetToken) return;
                var content = document.getElementById('portal-content');
                if (!content) return;
                if (reserved) {
                    content.dataset.nfMacSidebarContentInset = 'true';
                    content.style.setProperty('padding-top', '34px', 'important');
                    content.style.setProperty('box-sizing', 'border-box', 'important');
                } else {
                    delete content.dataset.nfMacSidebarContentInset;
                    content.style.removeProperty('padding-top');
                    content.style.removeProperty('box-sizing');
                }
            }
            [0, 80, 250, 700].forEach(function(delay) { setTimeout(apply, delay); });
        };
        window.__nfMacSetSidebarPreviewVisible = function(visible, width) {
            var root = document.documentElement;
            var resolvedWidth = Number(width);
            if (Number.isFinite(resolvedWidth) && resolvedWidth > 0) {
                root.style.setProperty('--nf-mac-sidebar-preview-width', resolvedWidth + 'px');
            }
            if (!window.__nfMacSidebarHidden) visible = false;
            if (visible) root.setAttribute('data-nf-mac-sidebar-preview', 'true');
            else root.removeAttribute('data-nf-mac-sidebar-preview');
            var openButton = document.querySelector('.portal-titlebar button[aria-controls="portal-navigation"]');
            if (visible && openButton && openButton.getAttribute('aria-expanded') !== 'true') {
                openButton.click();
            } else if (!visible) {
                var closeButton = document.querySelector('button[aria-label="탭바 닫기"]');
                if (closeButton) closeButton.click();
            }
        };
        window.__nfMacSetSidebarHidden = function(hidden) {
            window.__nfMacSidebarHidden = !!hidden;
            if (hidden) document.documentElement.setAttribute('data-nf-mac-sidebar-collapsed', 'true');
            else document.documentElement.removeAttribute('data-nf-mac-sidebar-collapsed');
            if (!hidden) window.__nfMacSetSidebarPreviewVisible(false);
            var requestToken = (window.__nfMacSidebarToken || 0) + 1;
            window.__nfMacSidebarToken = requestToken;
            function apply() {
                if (requestToken !== window.__nfMacSidebarToken) return;
                var navigation = document.getElementById('portal-navigation');
                var content = document.getElementById('portal-content');
                var root = navigation && navigation.parentElement;
                if (!navigation || !content || !root) return;
                if (hidden) {
                    navigation.dataset.nfMacHidden = 'true';
                    navigation.style.removeProperty('display');
                    root.style.setProperty('display', 'block', 'important');
                    root.style.setProperty('grid-template-columns', 'minmax(0, 1fr)', 'important');
                    content.style.setProperty('width', '100%', 'important');
                } else {
                    delete navigation.dataset.nfMacHidden;
                    document.documentElement.removeAttribute('data-nf-mac-sidebar-preview');
                    navigation.style.removeProperty('display');
                    root.style.removeProperty('display');
                    root.style.removeProperty('grid-template-columns');
                    content.style.removeProperty('width');
                    if (getComputedStyle(navigation).display === 'none') navigation.style.setProperty('display', 'block', 'important');
                }
            }
            [0, 80, 250, 700].forEach(function(delay) { setTimeout(apply, delay); });
            window.dispatchEvent(new CustomEvent('nfPortalDesktopSidebarToggle', {
                detail: { collapsed: !!hidden, platform: 'mac' }
            }));
        };

        var timer = null;
        var lastSignature = '';
        window.__nfMacNotifyNavigation = function(delay) {
            clearTimeout(timer);
            timer = setTimeout(function() {
                document.documentElement.lang = 'ko-KR';
                document.querySelectorAll('input[type="date"]').forEach(function(input) { input.lang = 'ko-KR'; });
                if (window.__nfMacSidebarHidden) window.__nfMacSetSidebarHidden(true);
                var style = getComputedStyle(document.body || document.documentElement);
                var title = currentTitle();
                var signature = location.href + '|' + title;
                if (signature === lastSignature && delay !== 0) return;
                lastSignature = signature;
                window.webkit.messageHandlers.NFPortalMacNavigation.postMessage({
                    url: location.href,
                    title: title,
                    breadcrumbs: breadcrumbs(),
                    background: style.backgroundColor,
                    foreground: style.color
                });
            }, typeof delay === 'number' ? delay : 100);
        };
        ['pushState', 'replaceState'].forEach(function(name) {
            var original = history[name];
            history[name] = function() {
                var result = original.apply(this, arguments);
                window.__nfMacNotifyNavigation(80);
                return result;
            };
        });
        addEventListener('popstate', function() { window.__nfMacNotifyNavigation(40); });
        addEventListener('pageshow', function() { window.__nfMacNotifyNavigation(0); });
        document.addEventListener('pointerdown', function(event) {
            var target = event.target;
            if (!target || !target.closest || target.closest('#portal-navigation')) return;
            window.webkit.messageHandlers.NFPortalMacPaneFocus.postMessage('focus');
        }, true);
        document.addEventListener('pointerover', function(event) {
            var navigation = event.target && event.target.closest && event.target.closest('#portal-navigation');
            if (!navigation || (event.relatedTarget && navigation.contains(event.relatedTarget))) return;
            window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({
                hovering: true,
                width: navigation.getBoundingClientRect().width
            });
        }, true);
        document.addEventListener('pointerout', function(event) {
            var navigation = event.target && event.target.closest && event.target.closest('#portal-navigation');
            if (!navigation || (event.relatedTarget && navigation.contains(event.relatedTarget))) return;
            window.webkit.messageHandlers.NFPortalMacSidebarHover.postMessage({ hovering: false });
        }, true);
        document.addEventListener('click', function(event) {
            var target = event.target;
            var link = target && target.closest && target.closest('a[href]');
            var navigation = target && target.closest && target.closest('#portal-navigation');
            if (link && navigation) {
                try {
                    var url = new URL(link.href, location.href);
                    if (url.origin === location.origin) {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.NFPortalMacSidebarNavigation.postMessage({ url: url.href });
                        return;
                    }
                } catch (_) {}
            }
            if (link) {
                window.__nfMacNotifyNavigation(160);
                setTimeout(function() { window.__nfMacNotifyNavigation(0); }, 450);
            }
        }, true);
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() { window.__nfMacNotifyNavigation(0); }, { once: true });
        } else {
            window.__nfMacNotifyNavigation(0);
        }
    })();
    """#
}
