import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

enum MacPortalConfig {
    static let host = "hlp-project-portal-745194786909.asia-northeast3.run.app"
    static let origin = "https://\(host)"
    static let dashboardURL = URL(string: "\(origin)/dashboard")!
    static let googleLoginURL = URL(string: "\(origin)/api/auth/start-google?callbackUrl=%2Fapi%2Fauth%2Fmobile%2Fcomplete")!
    static let exchangeURL = URL(string: "\(origin)/api/auth/mobile/exchange")!
    static let appleLoginURL = URL(string: "\(origin)/api/auth/mobile/apple")!
    static let callbackScheme = "com.nf.portal"

    static func isPortalURL(_ url: URL) -> Bool { url.host == host }
}

enum MacAppVersion {
    static var number: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.3"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "23"
    }

    static var displayText: String { "v\(number) Build \(build)" }
}

enum MacPortalAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var webAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class MacPortalPreferences: ObservableObject {
    @Published private var storedZoomPercent: Int

    var zoomPercent: Int {
        get { storedZoomPercent }
        set {
            let normalized = Self.normalizedZoom(newValue)
            guard storedZoomPercent != normalized else { return }
            storedZoomPercent = normalized
            defaults.set(normalized, forKey: Self.zoomKey)
        }
    }

    @Published var appearance: MacPortalAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    private let defaults: UserDefaults
    private static let zoomKey = "nf.mac.portal.zoomPercent.v2"
    private static let appearanceKey = "nf.mac.portal.appearance.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedZoom = defaults.integer(forKey: Self.zoomKey)
        storedZoomPercent = storedZoom == 0 ? 120 : Self.normalizedZoom(storedZoom)
        appearance = MacPortalAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    private static func normalizedZoom(_ value: Int) -> Int {
        min(200, max(80, Int((Double(value) / 5).rounded()) * 5))
    }
}

struct MacPortalPage: Identifiable, Codable, Equatable {
    let url: URL
    var title: String
    var accessedAt: TimeInterval

    var id: String { url.absoluteString }
}

struct MacPortalBreadcrumb: Identifiable, Equatable {
    let title: String
    let url: URL?

    var id: String { "\(title)|\(url?.absoluteString ?? "group")" }
}

@MainActor
final class MacPortalBrowserModel: ObservableObject {
    @Published private(set) var pages: [MacPortalPage] = []
    @Published private(set) var activePageID: String?
    @Published private(set) var breadcrumbs: [MacPortalBreadcrumb] = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var sidebarHidden = false {
        didSet { defaults.set(sidebarHidden, forKey: sidebarKey) }
    }
    @Published var themeBackground = Color(nsColor: .windowBackgroundColor)
    @Published var themeForeground = Color(nsColor: .labelColor)

    weak var webView: WKWebView?
    var onGoogleLogin: (() -> Void)?
    var onLogout: (() -> Void)?
    let identifier: String
    private let defaults: UserDefaults
    private var initialURL: URL

    private var pagesKey: String { "nf.mac.portal.pages.\(identifier).v2" }
    private var sidebarKey: String { "nf.mac.portal.sidebarHidden.\(identifier).v2" }

    init(identifier: String, initialURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.identifier = identifier
        self.initialURL = initialURL ?? MacPortalConfig.dashboardURL
        self.defaults = defaults
        sidebarHidden = defaults.bool(forKey: "nf.mac.portal.sidebarHidden.\(identifier).v2")
        if let data = defaults.data(forKey: "nf.mac.portal.pages.\(identifier).v2"),
           let stored = try? JSONDecoder().decode([MacPortalPage].self, from: data) {
            pages = Array(stored.sorted { $0.accessedAt < $1.accessedAt }.suffix(14))
            if let last = pages.last {
                self.initialURL = last.url
                activePageID = last.id
            }
        }
    }

    func connect(_ webView: WKWebView) {
        self.webView = webView
        refreshNavigationState()
    }

    func startURL() -> URL { initialURL }

    func cloneState(from source: MacPortalBrowserModel) {
        pages = source.pages
        breadcrumbs = source.breadcrumbs
        sidebarHidden = source.sidebarHidden
        initialURL = source.webView?.url ?? source.currentPage?.url ?? MacPortalConfig.dashboardURL
        activePageID = initialURL.absoluteString
        persistPages()
    }

    var currentPage: MacPortalPage? { pages.first { $0.id == activePageID } }

    func record(url: URL, title: String?, breadcrumbRecords: [[String: Any]] = []) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle?.isEmpty == false ? cleanTitle! : fallbackTitle(for: url)
        let page = MacPortalPage(url: url, title: resolvedTitle, accessedAt: Date().timeIntervalSince1970)
        pages.removeAll { $0.id == page.id }
        pages.append(page)
        pages = Array(pages.suffix(14))
        activePageID = page.id
        initialURL = url
        persistPages()
        breadcrumbs = resolveBreadcrumbs(breadcrumbRecords, url: url, title: resolvedTitle)
        refreshNavigationState()
        applySidebarVisibility()
    }

    func open(_ page: MacPortalPage) {
        activePageID = page.id
        webView?.load(URLRequest(url: page.url))
    }

    func open(_ breadcrumb: MacPortalBreadcrumb) {
        guard let url = breadcrumb.url else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func toggleSidebar() {
        sidebarHidden.toggle()
        applySidebarVisibility()
    }

    func refreshNavigationState() {
        let nextCanGoBack = webView?.canGoBack ?? false
        let nextCanGoForward = webView?.canGoForward ?? false
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
    }

    func applySidebarVisibility() {
        guard let webView else { return }
        let hidden = sidebarHidden ? "true" : "false"
        webView.evaluateJavaScript("window.__nfMacSetSidebarHidden && window.__nfMacSetSidebarHidden(\(hidden));")
    }

    func updateTheme(background: String?, foreground: String?) {
        if let background, let color = NSColor(cssColor: background) {
            themeBackground = Color(nsColor: color)
        }
        if let foreground, let color = NSColor(cssColor: foreground) {
            themeForeground = Color(nsColor: color)
        }
    }

    private func persistPages() {
        if let data = try? JSONEncoder().encode(pages) {
            defaults.set(data, forKey: pagesKey)
        }
    }

    private func fallbackTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        return name.isEmpty || name == "dashboard" ? "NF Portal" : name
    }

    private func resolveBreadcrumbs(
        _ records: [[String: Any]],
        url: URL,
        title: String
    ) -> [MacPortalBreadcrumb] {
        let resolved = records.compactMap { record -> MacPortalBreadcrumb? in
            guard let rawTitle = record["title"] as? String else { return nil }
            let clean = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let itemURL = (record["url"] as? String).flatMap(URL.init(string:))
            return MacPortalBreadcrumb(title: clean, url: itemURL)
        }
        if !resolved.isEmpty { return resolved }
        return [
            MacPortalBreadcrumb(title: "NF Portal", url: URL(string: MacPortalConfig.origin)),
            MacPortalBreadcrumb(title: title, url: url)
        ]
    }
}

private extension NSColor {
    convenience init?(cssColor: String) {
        let values = cssColor
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count >= 3 else { return nil }
        let alpha = values.count > 3 ? values[3] : 1
        self.init(srgbRed: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: alpha)
    }
}
