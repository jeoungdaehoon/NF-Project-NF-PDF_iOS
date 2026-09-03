import AppKit
import SwiftUI
import WebKit

struct MacPortalWebView: NSViewRepresentable {
    @ObservedObject var model: MacPortalBrowserModel
    @ObservedObject var preferences: MacPortalPreferences

    func makeCoordinator() -> Coordinator { Coordinator(model: model, preferences: preferences) }

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
        controller.add(context.coordinator, name: "NFPortalMacPageZoom")

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
        model.connect(webView)

        var request = URLRequest(url: model.startURL())
        request.setValue("ko-KR,ko;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.preferences = preferences
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
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        ["NFPortalMacNavigation", "NFPortalIOSGoogleLogin", "NFPortalIOSLogout", "NFPortalMacPageZoom"]
            .forEach(controller.removeScriptMessageHandler(forName:))
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var model: MacPortalBrowserModel
        var preferences: MacPortalPreferences
        var lastAppliedZoomPercent: Int?
        var lastAppliedAppearance: MacPortalAppearance?

        init(model: MacPortalBrowserModel, preferences: MacPortalPreferences) {
            self.model = model
            self.preferences = preferences
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.connect(webView)
            model.record(url: webView.url ?? MacPortalConfig.dashboardURL, title: webView.title)
            webView.evaluateJavaScript("""
            try { localStorage.setItem('nfPortalMacPageZoom', '\(preferences.zoomPercent)'); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: \(preferences.zoomPercent) } }));
            window.__nfMacNotifyNavigation && window.__nfMacNotifyNavigation(0);
            """)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.refreshNavigationState()
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
                if MacPortalConfig.isPortalURL(url) { webView.load(URLRequest(url: url)) }
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
            case "NFPortalMacPageZoom":
                if let value = message.body as? NSNumber {
                    preferences.zoomPercent = value.intValue
                } else if let record = message.body as? [String: Any], let value = record["percent"] as? NSNumber {
                    preferences.zoomPercent = value.intValue
                }
            default:
                break
            }
        }
    }

    private static let bootstrapScript = #"""
    (function() {
        document.documentElement.lang = 'ko-KR';
        document.documentElement.style.setProperty('-webkit-locale', '"ko-KR"');

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
        window.__nfMacSetSidebarHidden = function(hidden) {
            window.__nfMacSidebarHidden = !!hidden;
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
                    navigation.style.setProperty('display', 'none', 'important');
                    root.style.setProperty('display', 'block', 'important');
                    root.style.setProperty('grid-template-columns', 'minmax(0, 1fr)', 'important');
                    content.style.setProperty('width', '100%', 'important');
                } else {
                    delete navigation.dataset.nfMacHidden;
                    navigation.style.removeProperty('display');
                    root.style.removeProperty('display');
                    root.style.removeProperty('grid-template-columns');
                    content.style.removeProperty('width');
                    if (getComputedStyle(navigation).display === 'none') navigation.style.setProperty('display', 'flex', 'important');
                }
                window.dispatchEvent(new CustomEvent('nfPortalDesktopSidebarToggle', {
                    detail: { collapsed: !!hidden, platform: 'macOS' }
                }));
            }
            [0, 80, 250, 700].forEach(function(delay) { setTimeout(apply, delay); });
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
        document.addEventListener('click', function(event) {
            if (event.target && event.target.closest && event.target.closest('a[href]')) {
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
