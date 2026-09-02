//
//  PortalWebView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/**
 Portal WebView로 전달할 iOS 앱 지원 폰트 목록입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalWebView.Coordinator.deliverSupportedFonts(to:)``
 */
private let portalSupportedWebViewFonts: [String] = {
    /// iOS 기본/한글 표시에서 우선적으로 노출할 대표 폰트 후보입니다.
    let preferredFonts = [
        "Apple SD Gothic Neo",
        "SF Pro Display",
        "SF Pro Text",
        "Helvetica Neue",
        "Helvetica",
        "Arial",
        "Menlo",
        "Courier",
        "Courier New",
        "Times New Roman",
        "Georgia"
    ]
    /// UIKit이 현재 앱에서 사용할 수 있다고 알려주는 폰트 Family와 PostScript 이름을 수집합니다.
    let availableFonts = UIFont.familyNames.flatMap { familyName in
        [familyName] + UIFont.fontNames(forFamilyName: familyName)
    }
    /// 대표 후보를 먼저 보여주고 이후 실제 사용 가능한 폰트를 중복 없이 정렬해 반환합니다.
    var seenFonts = Set<String>()
    return (preferredFonts + availableFonts.sorted()).compactMap { fontName in
        let trimmedFontName = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFontName.isEmpty, !seenFonts.contains(trimmedFontName) else { return nil }
        seenFonts.insert(trimmedFontName)
        return trimmedFontName
    }
}()

/**
 iOS 앱 지원 폰트 목록을 JavaScript Array 문자열로 변환합니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``portalSupportedWebViewFonts``
 */
private let portalSupportedWebViewFontPayload: String = {
    /// JSONSerialization을 사용해 따옴표/특수문자 이스케이프를 JavaScript가 안전하게 해석할 수 있게 합니다.
    guard let data = try? JSONSerialization.data(withJSONObject: portalSupportedWebViewFonts, options: []),
          let payload = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return payload
}()

/**
 NF Portal 내부 화면을 표시하는 WKWebView 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalWebViewModel``, ``PortalWebViewState``
 */
struct PortalWebView: View {
#if targetEnvironment(macCatalyst)
    @StateObject private var desktopChrome = PortalDesktopChromeModel()
    @StateObject private var secondaryDesktopChrome = PortalDesktopChromeModel()
    @State private var isDesktopSplitViewEnabled = false
    @EnvironmentObject private var portalThemeController: PortalAppThemeController
#endif

    let portalURL: URL
    let loginInfo: LoginInfo?
    let onLoginInfo: (LoginInfo) -> Void
    let onOpenExternal: (URL) -> Void
    let onPreviewAttachment: (PortalAttachmentPreviewItem) -> Void
    let onLogout: () -> Void
    let onAccountAccessIssue: () -> Void
    let onAccountDeleted: () -> Void
    let onNetworkUnavailable: () -> Void
    let onAutoLoginChanged: (Bool) -> Void
    let autoLoginEnabled: Bool
    let onPDFLocalStorageChanged: (Bool) -> Void
    let pdfLocalStorageEnabled: Bool
    let onOpenPDFDocuments: () -> Void
    let localPDFDocumentCount: Int

    var body: some View {
#if targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            PortalDesktopPane(
                model: desktopChrome,
                theme: portalThemeController.theme,
                reservesTrafficLightArea: true,
                showsBreadcrumbs: isDesktopSplitViewEnabled || desktopChrome.isNavigationMenuHidden,
                isSplitViewEnabled: isDesktopSplitViewEnabled,
                onToggleSplitView: toggleDesktopSplitView,
                content: makeContent(portalURL: portalURL).desktopChrome(desktopChrome)
            )

            if isDesktopSplitViewEnabled {
                Rectangle()
                    .fill(portalThemeController.theme.border.color)
                    .frame(width: 1)

                PortalDesktopPane(
                    model: secondaryDesktopChrome,
                    theme: portalThemeController.theme,
                    reservesTrafficLightArea: false,
                    showsBreadcrumbs: true,
                    isSplitViewEnabled: true,
                    onToggleSplitView: toggleDesktopSplitView,
                    content: makeContent(
                        portalURL: secondaryDesktopChrome.splitInitialURL ?? portalURL
                    ).desktopChrome(secondaryDesktopChrome)
                )
            }
        }
        // UITitlebar의 기본 제목을 숨긴 뒤에도 Catalyst가 남기는 상단 safe area까지
        // 통합 헤더가 확장돼, 신호등과 같은 줄에 탐색 컨트롤을 표시합니다.
        .ignoresSafeArea(.container, edges: .top)
        .background(MacCatalystTitlebarConfigurator())
#else
        makeContent(portalURL: portalURL)
#endif
    }

    /** 동일한 로그인 세션과 앱 브리지를 사용하는 Portal WebView를 생성합니다. */
    private func makeContent(portalURL: URL) -> PortalWebViewContent {
        PortalWebViewContent(
            portalURL: portalURL,
            loginInfo: loginInfo,
            onLoginInfo: onLoginInfo,
            onOpenExternal: onOpenExternal,
            onPreviewAttachment: onPreviewAttachment,
            onLogout: onLogout,
            onAccountAccessIssue: onAccountAccessIssue,
            onAccountDeleted: onAccountDeleted,
            onNetworkUnavailable: onNetworkUnavailable,
            onAutoLoginChanged: onAutoLoginChanged,
            autoLoginEnabled: autoLoginEnabled,
            onPDFLocalStorageChanged: onPDFLocalStorageChanged,
            pdfLocalStorageEnabled: pdfLocalStorageEnabled,
            onOpenPDFDocuments: onOpenPDFDocuments,
            localPDFDocumentCount: localPDFDocumentCount
        )
    }

#if targetEnvironment(macCatalyst)
    /** 현재 페이지를 오른쪽 편집 영역에 복제하거나 열린 2분할을 닫습니다. */
    private func toggleDesktopSplitView() {
        if isDesktopSplitViewEnabled {
            isDesktopSplitViewEnabled = false
        } else {
            secondaryDesktopChrome.prepareForSplit(from: desktopChrome, fallbackURL: portalURL)
            isDesktopSplitViewEnabled = true
        }
    }
#endif
}

/** iOS와 Mac Catalyst에서 공유하는 WKWebView 및 Portal 브리지 구현입니다. */
private struct PortalWebViewContent: UIViewRepresentable {
    /// 웹에서 수신한 팔레트를 네이티브 Safe Area와 문서 화면에 전달하는 앱 전역 테마 저장소입니다.
    @EnvironmentObject private var portalThemeController: PortalAppThemeController
    /// WKWebView가 처음 로드해야 하는 Portal URL 입니다.
    let portalURL: URL
    /// 외부 OAuth 인증 후 WKWebView JavaScript 영역으로 전달할 로그인 정보 입니다.
    let loginInfo: LoginInfo?
    /// WKWebView 또는 Deep Link에서 로그인 정보를 다시 받았을 때 Route로 전달하는 이벤트 입니다.
    let onLoginInfo: (LoginInfo) -> Void
    /// Portal 외부 URL을 외부 브라우저 또는 OAuth 세션으로 여는 이벤트 입니다.
    let onOpenExternal: (URL) -> Void
    /// PDFView 내부 미리보기로 표시할 첨부 파일을 Route로 전달하는 이벤트 입니다.
    let onPreviewAttachment: (PortalAttachmentPreviewItem) -> Void
    /// Portal WebView 안에서 로그아웃이 확인되었을 때 Login 화면으로 전환하는 이벤트 입니다.
    let onLogout: () -> Void
    /// Portal에서 삭제·중지·누락 계정으로 판정했을 때 저장된 인증 세션을 정리하는 이벤트 입니다.
    let onAccountAccessIssue: () -> Void
    /// 웹 계정 탈퇴 완료 후 앱의 모든 로컬 사용자 정보를 삭제하는 이벤트 입니다.
    let onAccountDeleted: () -> Void
    /// Portal 메인 화면 최초 진입 중 네트워크 오류가 발생했을 때 Login 화면으로 전환하는 이벤트 입니다.
    let onNetworkUnavailable: () -> Void
    /// Portal 웹 설정에서 자동 로그인 값을 변경했을 때 Route로 전달하는 이벤트 입니다.
    let onAutoLoginChanged: (Bool) -> Void
    /// 앱에 저장된 자동 로그인 설정 값 입니다.
    let autoLoginEnabled: Bool
    /// Portal 웹 설정에서 PDF 파일 로컬 저장 값을 변경했을 때 Route로 전달하는 이벤트 입니다.
    let onPDFLocalStorageChanged: (Bool) -> Void
    /// 앱에 저장된 PDF 파일 로컬 저장 설정 값 입니다.
    let pdfLocalStorageEnabled: Bool
    /// 웹 탭바의 PDF 문서 메뉴를 네이티브 문서 페이지로 연결하는 이벤트입니다.
    let onOpenPDFDocuments: () -> Void
    /// 활성 문서와 휴지통 문서를 포함한 로컬 PDF 문서 수입니다.
    let localPDFDocumentCount: Int
#if targetEnvironment(macCatalyst)
    /// Mac Catalyst 데스크톱 탐색 바 상태입니다.
    var desktopChrome: PortalDesktopChromeModel? = nil
#endif
    /// WebView 화면 데이터와 UI 기능을 처리하는 ViewModel 입니다.
    @StateObject private var viewModel = PortalWebViewModel()

#if targetEnvironment(macCatalyst)
    /** 상위 Mac Catalyst 화면의 데스크톱 탐색 바를 연결합니다. */
    func desktopChrome(_ desktopChrome: PortalDesktopChromeModel) -> Self {
        var next = self
        next.desktopChrome = desktopChrome
        return next
    }
#endif

    /**
     WKWebView Coordinator를 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: ``Coordinator``
     */
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, viewModel: viewModel)
    }

    /**
     WKWebView 인스턴스를 생성하고 기본 설정을 적용합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - context: UIViewRepresentable Context 정보 입니다.
     - Returns: `WKWebView`
     */
    func makeUIView(context: Context) -> WKWebView {
        /// JavaScript Bridge를 연결하기 위한 UserContentController 입니다.
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.googleLoginBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.logoutBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.accountDeletionBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.autoLoginBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.pdfLocalStorageBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.pdfDocumentsBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.themeBridgeName)
#if targetEnvironment(macCatalyst)
        userContentController.add(context.coordinator, name: Coordinator.macPageZoomBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.macNavigationStateBridgeName)
        userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.macNavigationObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.macDesktopAssistBarHiderScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
#endif
        /// WKWebView 기본 설정 입니다.
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
#if targetEnvironment(macCatalyst)
        /// Catalyst에서도 Safari·Chrome과 같은 데스크톱용 HTML/CSS 분기를 사용합니다.
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
#endif
        /// WKWebView 인스턴스를 생성합니다.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.backgroundColor = portalThemeController.theme.background.uiColor
        webView.isOpaque = false
        webView.backgroundColor = portalThemeController.theme.background.uiColor
        /// iOS가 링크를 길게 눌렀을 때 표시하는 미리보기/열기 메뉴를 비활성화합니다.
        webView.allowsLinkPreview = false
        /// WebView 입력창 포커스 시 iOS 기본 키보드 어시스트 바가 보이지 않도록 처리합니다.
        webView.hideKeyboardAssistantBar()
        /// 기본 UserAgent를 보존한 상태에서 NF iOS 식별 값을 추가합니다.
        let defaultUserAgent = webView.value(forKey: "userAgent") as? String ?? ""
        webView.customUserAgent = "\(defaultUserAgent) \(PortalConfig.userAgentSuffix)"
#if targetEnvironment(macCatalyst)
        /// 저장된 Mac 전용 화면 배율과 데스크톱 탐색 상태를 연결합니다.
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.isDirectionalLockEnabled = true
        desktopChrome?.connect(webView)
#endif
        /// 최초 Portal URL을 로드합니다.
        webView.load(URLRequest(url: PortalConfig.normalizePortalURL(portalURL)))
        context.coordinator.webView = webView
        return webView
    }

    /**
     SwiftUI State 변경을 WKWebView에 반영합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - webView: 갱신 대상 WKWebView 입니다.
        - context: UIViewRepresentable Context 정보 입니다.
     */
    func updateUIView(_ webView: WKWebView, context: Context) {
        /// SwiftUI 갱신 시점에도 WebKit 내부 입력 View의 어시스트 바 상태를 다시 정리합니다.
        webView.hideKeyboardAssistantBar()
        /// 웹 테마 변경 시 WebView 바깥의 네이티브 여백과 스크롤 배경도 같은 색으로 갱신합니다.
        webView.scrollView.backgroundColor = portalThemeController.theme.background.uiColor
        webView.backgroundColor = portalThemeController.theme.background.uiColor
        /// Coordinator가 최신 WebView State와 Web 브리지 Callback을 사용하도록 부모 값을 갱신합니다.
        context.coordinator.parent = self
#if targetEnvironment(macCatalyst)
        desktopChrome?.connect(webView)
#endif
        /// Portal 편집 어시스트가 앱 지원 폰트를 즉시 사용할 수 있도록 폰트 목록을 다시 전달합니다.
        context.coordinator.deliverSupportedFonts(to: webView)
        /// 웹 설정에서 자동 로그인 값이 변경된 경우 최신 앱 State를 다시 전달합니다.
        context.coordinator.deliverAutoLoginState(to: webView)
        /// 웹 설정에서 PDF 파일 로컬 저장 값이 변경된 경우 최신 앱 State를 다시 전달합니다.
        context.coordinator.deliverPDFLocalStorageState(to: webView)
        /// 로컬 PDF가 한 개 이상일 때만 웹 탭바 분기가 나타나도록 문서 수를 전달합니다.
        context.coordinator.deliverPDFDocumentLibraryState(to: webView)
        /// 로그인 결과가 화면 로드 이후 들어온 경우에도 즉시 JavaScript 영역에 전달합니다.
        if let loginInfo {
            context.coordinator.deliverLoginInfo(loginInfo, to: webView)
        }
    }

    /**
     WKWebView가 제거될 때 JavaScript Bridge를 정리합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - webView: 제거 대상 WKWebView 입니다.
        - coordinator: WKWebView Coordinator 입니다.
     */
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelInitialLoadTimeout()
        /// ScriptMessageHandler 순환 참조를 막기 위해 Bridge를 제거합니다.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.googleLoginBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.logoutBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.accountDeletionBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.autoLoginBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.pdfLocalStorageBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.pdfDocumentsBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.themeBridgeName)
#if targetEnvironment(macCatalyst)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.macPageZoomBridgeName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.macNavigationStateBridgeName)
#endif
    }
}

// MARK: - WKWebView Delegate Coordinator 입니다.
extension PortalWebViewContent {
    /**
     WKWebView Navigation, UI, JavaScript Bridge 처리를 담당하는 Coordinator 입니다. ( J.D.H )
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIDocumentPickerDelegate {
        /// Google 로그인 Bridge 이름 입니다.
        static let googleLoginBridgeName = "NFPortalIOSGoogleLogin"
        /// 로그아웃 Bridge 이름 입니다.
        static let logoutBridgeName = "NFPortalIOSLogout"
        /// 계정 탈퇴 완료 후 로컬 데이터 삭제 Bridge 이름입니다.
        static let accountDeletionBridgeName = "NFPortalIOSAccountDeletion"
        /// 웹 설정의 자동 로그인 토글을 앱으로 전달하는 Bridge 이름 입니다.
        static let autoLoginBridgeName = "NFPortalIOSAutoLogin"
        /// 웹 설정의 PDF 파일 로컬 저장 토글을 앱으로 전달하는 Bridge 이름 입니다.
        static let pdfLocalStorageBridgeName = "NFPortalIOSPDFLocalStorage"
        /// 웹 탭바의 네이티브 PDF 문서 페이지 열기 Bridge 이름입니다.
        static let pdfDocumentsBridgeName = "NFPortalIOSPDFDocuments"
        /// 웹 화면 테마의 실제 CSS 팔레트를 네이티브 앱으로 전달하는 Bridge 이름입니다.
        static let themeBridgeName = "NFPortalIOSTheme"
#if targetEnvironment(macCatalyst)
        /// 웹 설정 화면의 Mac 전용 화면 배율을 네이티브 WKWebView로 전달하는 Bridge 이름입니다.
        static let macPageZoomBridgeName = "NFPortalMacPageZoom"
        /// Portal SPA 경로 변경을 Mac 상단 탭과 경로 바로 전달하는 Bridge 이름입니다.
        static let macNavigationStateBridgeName = "NFPortalMacNavigationState"
        /// 전체 문서 이동과 SPA History API 이동을 동일하게 감지하는 Mac 전용 UserScript입니다.
        static let macNavigationObserverScript = """
        (function() {
            if (window.__nfPortalMacNavigationObserverInstalled) return;
            window.__nfPortalMacNavigationObserverInstalled = true;

            var lastSignature = '';
            var notificationTimer = null;
            function currentPageTitle() {
                var navigation = document.getElementById('portal-navigation');
                if (navigation) {
                    var links = Array.from(navigation.querySelectorAll('a[href]'));
                    var currentPath = location.pathname.replace(/\\/$/, '') + location.search;
                    var active = links.find(function(anchor) {
                        return anchor.getAttribute('aria-current') === 'page';
                    }) || links.find(function(anchor) {
                        try {
                            var url = new URL(anchor.href, location.href);
                            return url.pathname.replace(/\\/$/, '') + url.search === currentPath;
                        } catch (_) {
                            return false;
                        }
                    });
                    if (active) {
                        var label = active.querySelector('span.truncate') || active.querySelector('span') || active;
                        var text = String(label.textContent || '').replace(/\\s+/g, ' ').trim();
                        if (text) return text;
                    }
                }
                return String(document.title || '').trim();
            }
            function notifyNavigationChanged(delay) {
                clearTimeout(notificationTimer);
                notificationTimer = setTimeout(function() {
                    var title = currentPageTitle();
                    var signature = location.href + '|' + title;
                    if (signature === lastSignature) return;
                    lastSignature = signature;
                    window.webkit.messageHandlers.\(macNavigationStateBridgeName).postMessage({
                        url: location.href,
                        title: title
                    });
                    // Mac 전용 보조 기능은 전체 DOM을 감시하지 않고 실제 경로 변경 때만 갱신합니다.
                    window.dispatchEvent(new CustomEvent('nfPortalMacNavigationChanged'));
                }, typeof delay === 'number' ? delay : 120);
            }

            ['pushState', 'replaceState'].forEach(function(methodName) {
                var original = history[methodName];
                history[methodName] = function() {
                    var result = original.apply(this, arguments);
                    notifyNavigationChanged(120);
                    return result;
                };
            });
            window.addEventListener('popstate', function() { notifyNavigationChanged(80); });
            document.addEventListener('click', function(event) {
                var link = event.target && event.target.closest ? event.target.closest('#portal-navigation a[href]') : null;
                if (!link) return;
                notifyNavigationChanged(150);
                setTimeout(function() { notifyNavigationChanged(0); }, 500);
            }, true);

            var documentRootObserver = null;
            function installDOMObserver() {
                var navigation = document.getElementById('portal-navigation');
                if (!navigation) return false;
                if (documentRootObserver) {
                    documentRootObserver.disconnect();
                    documentRootObserver = null;
                }
                if (navigation.__nfPortalMacObserved) return true;
                navigation.__nfPortalMacObserved = true;
                new MutationObserver(function() { notifyNavigationChanged(100); }).observe(navigation, {
                    subtree: true,
                    childList: true,
                    attributes: true,
                    attributeFilter: ['aria-current', 'data-state']
                });
                notifyNavigationChanged(0);
                return true;
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', installDOMObserver, { once: true });
            } else {
                installDOMObserver();
            }
            function observeDocumentRoot() {
                if (!document.documentElement) {
                    setTimeout(observeDocumentRoot, 0);
                    return;
                }
                if (installDOMObserver()) return;
                documentRootObserver = new MutationObserver(function() {
                    installDOMObserver();
                });
                documentRootObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
            }
            observeDocumentRoot();
        })();
        """
        /// Mac 데스크톱에서는 모바일 입력용으로 고정된 하단 웹 편집 어시스트바를 숨깁니다.
        static let macDesktopAssistBarHiderScript = """
        (function() {
            if (window.__nfPortalMacAssistBarHiderInstalled) return;
            window.__nfPortalMacAssistBarHiderInstalled = true;

            var hiddenAttribute = 'data-nf-portal-mac-assist-hidden';
            var style = document.createElement('style');
            style.id = '__nfPortalMacAssistBarHiderStyle';
            style.textContent = '[' + hiddenAttribute + '] { display: none !important; }';
            (document.head || document.documentElement).appendChild(style);

            var scanTimer = null;
            function scheduleScan(delay) {
                clearTimeout(scanTimer);
                scanTimer = setTimeout(hideBottomAssistBar, typeof delay === 'number' ? delay : 80);
            }

            function visibleRect(element) {
                if (!element || !element.getBoundingClientRect) return null;
                var rect = element.getBoundingClientRect();
                if (rect.width < 1 || rect.height < 1) return null;
                var computed = window.getComputedStyle(element);
                if (computed.display === 'none' || computed.visibility === 'hidden') return null;
                return rect;
            }

            function hideBottomAssistBar() {
                // 한 번 숨긴 고정 바는 SPA 페이지 이동 뒤에도 유지되므로 다시 전체 문서를 검색하지 않습니다.
                if (document.querySelector('[' + hiddenAttribute + ']')) return true;
                var viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
                var viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
                if (viewportWidth < 1 || viewportHeight < 1) return false;

                var bottomControls = Array.from(document.querySelectorAll(
                    'button, [role="button"], input, select, [contenteditable="true"]'
                )).filter(function(control) {
                    var rect = visibleRect(control);
                    return rect && rect.top >= viewportHeight - 120 && rect.bottom <= viewportHeight + 8;
                });

                var candidates = [];
                bottomControls.forEach(function(control) {
                    var element = control.parentElement;
                    var depth = 0;
                    while (element && element !== document.body && depth < 8) {
                        var rect = visibleRect(element);
                        if (rect &&
                            rect.top >= viewportHeight - 120 &&
                            rect.bottom >= viewportHeight - 12 &&
                            rect.height >= 34 && rect.height <= 100 &&
                            rect.width >= viewportWidth * 0.65) {
                            var position = window.getComputedStyle(element).position;
                            var controlCount = element.querySelectorAll(
                                'button, [role="button"], input, select, [contenteditable="true"]'
                            ).length;
                            if ((position === 'fixed' || position === 'sticky') && controlCount >= 6) {
                                candidates.push({ element: element, rect: rect, count: controlCount });
                            }
                        }
                        element = element.parentElement;
                        depth += 1;
                    }
                });

                candidates.sort(function(left, right) {
                    if (right.rect.width !== left.rect.width) return right.rect.width - left.rect.width;
                    return left.rect.height - right.rect.height;
                });
                if (candidates.length > 0) {
                    candidates[0].element.setAttribute(hiddenAttribute, 'true');
                    return true;
                }
                return false;
            }

            window.addEventListener('resize', function() { scheduleScan(0); });
            window.addEventListener('popstate', function() { scheduleScan(80); });
            window.addEventListener('nfPortalMacNavigationChanged', function() { scheduleScan(150); });
            document.addEventListener('focusin', function(event) {
                var target = event.target;
                if (!target || !target.closest) return;
                if (target.closest('input, textarea, select, [contenteditable="true"], [role="textbox"]')) {
                    scheduleScan(80);
                }
            }, true);
            hideBottomAssistBar();
            // 비동기 Portal 초기화만 제한 횟수로 확인합니다. 차트 셀 변경은 더 이상 재검색을 유발하지 않습니다.
            [250, 1000, 2500].forEach(function(delay) {
                setTimeout(hideBottomAssistBar, delay);
            });
        })();
        """
#endif
        /// 부모 PortalWebView 정보 입니다.
        var parent: PortalWebViewContent
        /// WebView 화면 기능 처리를 담당하는 ViewModel 입니다.
        private let viewModel: PortalWebViewModel
        /// 현재 연결된 WKWebView 입니다.
        weak var webView: WKWebView?
        /// 메인 화면 최초 로딩이 무한정 대기하지 않도록 제한하는 시간(초) 입니다.
        private let initialLoadTimeout: TimeInterval = 30
        /// 최초 로딩 제한시간 작업 입니다.
        private var initialLoadTimeoutWorkItem: DispatchWorkItem?
        /// 최초 Portal 화면이 한 번이라도 정상 완료되었는지 여부 입니다.
        private var hasCompletedInitialLoad = false
        /// 네트워크 오류 안내를 중복 표시하지 않기 위한 상태 입니다.
        private var hasReportedNetworkIssue = false
        /// 같은 계정 접근 오류 이동에서 세션 정리 Callback이 중복 실행되지 않도록 관리하는 상태입니다.
        private var hasReportedAccountAccessIssue = false
        /// WebView 파일 입력창의 선택 결과를 반환할 completion 입니다.
        private var filePickerCompletionHandler: (([URL]?) -> Void)?

        /**
         Coordinator를 생성합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - parent: 부모 PortalWebView 입니다.
            - viewModel: WebView 화면 ViewModel 입니다.
         */
        init(parent: PortalWebViewContent, viewModel: PortalWebViewModel) {
            self.parent = parent
            self.viewModel = viewModel
        }

        /**
         WKWebView URL 이동 정책을 결정합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: URL 이동을 요청한 WKWebView 입니다.
            - navigationAction: URL 이동 요청 정보 입니다.
            - decisionHandler: 이동 허용/취소 처리 Callback 입니다.
         */
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            /// URL이 없는 이동은 기본 허용합니다.
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            /// 첨부 파일/다운로드 URL은 현재 Portal WebView를 덮지 않도록 외부 열기로 분리합니다.
            if isAttachmentNavigationURL(url) {
                presentAttachmentPreview(url, from: webView)
                decisionHandler(.cancel)
                return
            }
            /// target blank 새 창 요청은 Portal 내부 화면만 현재 WKWebView에서 이어서 로드하고, 그 외 URL은 외부 열기로 분리합니다.
            if navigationAction.targetFrame == nil {
                if viewModel.isPortalURL(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    parent.onOpenExternal(url)
                }
                decisionHandler(.cancel)
                return
            }
            /// 외부 인증 Callback URL이 들어오면 로그인 정보로 변환합니다.
            if let loginInfo = LoginInfo(url: url) {
                parent.onLoginInfo(loginInfo)
                decisionHandler(.cancel)
                return
            }
            /// 삭제·중지됐거나 DB에서 찾을 수 없는 계정이면 웹 오류 화면 대신 세션을 정리하고 Native Login으로 돌아갑니다.
            if viewModel.isPortalURL(url), viewModel.isPortalAccountAccessIssueRoute(url) {
                if !hasReportedAccountAccessIssue {
                    hasReportedAccountAccessIssue = true
                    parent.onAccountAccessIssue()
                }
                decisionHandler(.cancel)
                return
            }
            /// Portal 로그아웃 또는 Login 화면 진입은 Native LoginView 전환으로 처리합니다.
            if viewModel.isPortalURL(url), viewModel.isPortalLogoutRoute(url) {
                parent.onLogout()
                decisionHandler(.cancel)
                return
            }
            /// Google OAuth 시작 URL은 WKWebView가 아닌 외부 인증 세션으로 위임합니다.
            if viewModel.isPortalGoogleAuthStartURL(url) {
                parent.onOpenExternal(PortalConfig.portalLoginURL)
                decisionHandler(.cancel)
                return
            }
            /// Portal 내부 URL은 WKWebView에서 계속 표시합니다.
            if viewModel.isPortalURL(url) {
                decisionHandler(.allow)
                return
            }
            /// Portal 외부 URL은 시스템 브라우저로 위임합니다.
            parent.onOpenExternal(url)
            decisionHandler(.cancel)
        }

        /**
         WKWebView 최초 연결이 시작될 때 제한시간 감시를 시작합니다.
         - Version: 1.0.0
         - Date: 2026.08.05
         */
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
#if targetEnvironment(macCatalyst)
            parent.desktopChrome?.refreshNavigationState(in: webView)
#endif
            guard !hasCompletedInitialLoad, !hasReportedNetworkIssue else { return }
            initialLoadTimeoutWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.reportNetworkUnavailable()
            }
            initialLoadTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + initialLoadTimeout,
                execute: workItem
            )
        }

        /// 응답 문서가 WKWebView에 반영되는 시점에 뒤로·앞으로 상태를 다시 계산합니다.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
#if targetEnvironment(macCatalyst)
            parent.desktopChrome?.refreshNavigationState(in: webView)
#endif
        }

        /**
         Portal 첨부 파일 또는 WebView가 직접 표시하면 안 되는 파일성 URL인지 확인합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - url: WKWebView Navigation에서 전달된 URL 입니다.
         - Returns: 현재 WebView가 아닌 외부 열기로 분리해야 하는 경우 `true` 입니다.
         */
        private func isAttachmentNavigationURL(_ url: URL) -> Bool {
            /// Portal 내부 첨부 파일 API는 이미지/PDF 등을 현재 WebView에 바로 표시할 수 있어 사용자가 원래 페이지로 돌아가기 어려워집니다.
            if url.path.hasPrefix("/api/artifacts/files") { return true }
            /// 다운로드 Query가 명시된 URL은 화면 전환 대상이 아니라 파일 처리 대상입니다.
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name.lowercased() == "download" }) == true { return true }
            /// file/blob/data URL은 Portal 화면 Navigation으로 유지할 대상이 아니므로 현재 WebView 로드를 차단합니다.
            if ["file", "blob", "data"].contains(url.scheme?.lowercased() ?? "") { return true }
            return false
        }

        /**
         WKWebView 인증 Cookie를 포함해 첨부 파일 내부 미리보기 화면을 요청합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - url: 내부 PDF 미리보기로 열 첨부 파일 URL 입니다.
            - webView: Cookie Store를 제공하는 현재 WKWebView 입니다.
         */
        private func presentAttachmentPreview(_ url: URL, from webView: WKWebView) {
            /// Portal 첨부 API가 인증 Cookie를 요구할 수 있어 WKWebView CookieStore에서 현재 도메인 Cookie를 함께 전달합니다.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let cookieHeader = self.cookieHeader(for: url, cookies: cookies)
                Task { @MainActor in
                    self.parent.onPreviewAttachment(PortalAttachmentPreviewItem(url: url, cookieHeader: cookieHeader))
                }
            }
        }

        /**
         첨부 URL 도메인에 전달할 Cookie Header 문자열을 생성합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - url: Cookie가 사용될 첨부 파일 URL 입니다.
            - cookies: WKWebView CookieStore에서 읽은 전체 Cookie 목록입니다.
         - Returns: URL Host와 일치하는 Cookie Header 문자열입니다.
         */
        private func cookieHeader(for url: URL, cookies: [HTTPCookie]) -> String? {
            /// Host가 없으면 Cookie 도메인 매칭을 할 수 없어 Header를 전달하지 않습니다.
            guard let host = url.host?.lowercased() else { return nil }
            let matchedCookies = cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return host == domain || host.hasSuffix(".\(domain)")
            }
            let header = matchedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            return header.isEmpty ? nil : header
        }

        /**
         WKWebView 페이지 로드 완료 후 JavaScript Bridge를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: 로드가 완료된 WKWebView 입니다.
            - navigation: 완료된 Navigation 정보 입니다.
         */
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasCompletedInitialLoad = true
            cancelInitialLoadTimeout()
            /// 페이지 로드 완료 후 생성된 WebKit 내부 입력 View에도 키보드 어시스트 바 제거를 적용합니다.
            webView.hideKeyboardAssistantBar()
            /// 뒤로가기 가능 여부를 ViewModel State에 반영합니다.
            Task { @MainActor in
                viewModel.setCanGoBack(webView.canGoBack)
            }
#if targetEnvironment(macCatalyst)
            parent.desktopChrome?.recordCurrentPage(in: webView)
#endif
        /// Portal 페이지에 Google 로그인/로그아웃 Bridge와 길게 누르기 차단 스크립트를 주입합니다.
        injectGoogleLoginBridge(to: webView)
        injectLogoutBridge(to: webView)
        injectAccountDeletionBridge(to: webView)
        injectAutoLoginBridge(to: webView)
        injectPDFLocalStorageBridge(to: webView)
        injectPDFDocumentsBridge(to: webView)
        injectThemeBridge(to: webView)
        injectLongPressBlocker(to: webView)
        deliverSupportedFonts(to: webView)
        deliverAutoLoginState(to: webView)
        deliverPDFLocalStorageState(to: webView)
        deliverPDFDocumentLibraryState(to: webView)
            /// 로그인 정보가 있다면 Portal JavaScript 영역으로 전달합니다.
            if let loginInfo = parent.loginInfo {
                deliverLoginInfo(loginInfo, to: webView)
            }
        }

        /**
         WKWebView가 초기 연결 단계에서 실패하면 네트워크 오류 흐름으로 전환합니다.
         - Version: 1.0.0
         - Date: 2026.08.05
         */
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleInitialNavigationFailure(error)
        }

        /**
         WKWebView가 초기 문서 로딩 중 실패하면 네트워크 오류 흐름으로 전환합니다.
         - Version: 1.0.0
         - Date: 2026.08.05
         */
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleInitialNavigationFailure(error)
        }

        /// 사용자 취소로 발생하는 Navigation 실패는 오류 안내에서 제외합니다.
        private func handleInitialNavigationFailure(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            reportNetworkUnavailable()
        }

        /// 네트워크 오류 안내를 한 번만 상위 Route로 전달합니다.
        private func reportNetworkUnavailable() {
            guard !hasCompletedInitialLoad, !hasReportedNetworkIssue else { return }
            hasReportedNetworkIssue = true
            cancelInitialLoadTimeout()
            Task { @MainActor [weak self] in
                self?.parent.onNetworkUnavailable()
            }
        }

        /// 최초 로딩 제한시간 작업을 정리합니다.
        func cancelInitialLoadTimeout() {
            initialLoadTimeoutWorkItem?.cancel()
            initialLoadTimeoutWorkItem = nil
        }

        /**
         target blank 또는 window.open 요청을 현재 WKWebView에서 처리합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: 원본 WKWebView 입니다.
            - configuration: 새 WebView 설정 정보 입니다.
            - navigationAction: 새 창 Navigation 정보 입니다.
            - windowFeatures: 새 창 Feature 정보 입니다.
         - Returns: `WKWebView?`
         */
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            /// Portal 내부 화면은 현재 WKWebView에서 이어서 표시하되, 첨부 파일은 Portal 화면을 덮지 않도록 외부 열기로 분리합니다.
            if let url = navigationAction.request.url {
                if isAttachmentNavigationURL(url) {
                    presentAttachmentPreview(url, from: webView)
                } else if !viewModel.isPortalURL(url) {
                    parent.onOpenExternal(url)
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        /**
         WKWebView 길게 누르기 시 표시되는 iOS 기본 Context Menu를 차단합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - webView: Context Menu 표시를 요청한 WKWebView 입니다.
            - elementInfo: 길게 누른 Web 요소 정보 입니다.
            - completionHandler: Context Menu 표시 여부 Callback 입니다.
         */
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            /// 링크/이미지/텍스트를 길게 눌러도 Safari 열기 또는 미리보기 메뉴가 표시되지 않도록 nil을 반환합니다.
            completionHandler(nil)
        }

        /**
         WebView의 `<input type="file">`를 iOS 파일 선택창으로 연결합니다.
         - Version: 1.0.0
         - Date: 2026.08.08
         - Parameters:
            - webView: 파일 선택을 요청한 WKWebView 입니다.
            - parameters: 파일 선택창의 다중 선택 설정입니다.
            - frame: 파일 선택을 요청한 WebView Frame 정보입니다.
            - completionHandler: 선택한 파일 URL을 WebKit으로 전달하는 Callback 입니다.

         [Note]
         - `asCopy: true`로 선택한 파일을 앱이 읽을 수 있는 임시 복사본으로 전달합니다.
         - 시스템 파일 선택창에서 사용자가 허용한 뒤에만 URL을 WebView에 전달합니다.
         */
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            filePickerCompletionHandler?(nil)
            filePickerCompletionHandler = completionHandler

            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.item],
                asCopy: true
            )
            picker.allowsMultipleSelection = parameters.allowsMultipleSelection
            picker.delegate = self

            guard let presenter = topViewController(from: webView.window?.rootViewController) else {
                completeFilePicker(with: nil)
                return
            }
            presenter.present(picker, animated: true)
        }

        /** 선택한 파일 URL을 WebView 파일 입력창에 전달합니다. */
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completeFilePicker(with: urls)
        }

        /** 사용자가 파일 선택창을 취소한 경우 WebView의 선택 상태를 정리합니다. */
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completeFilePicker(with: nil)
        }

        private func completeFilePicker(with urls: [URL]?) {
            let completionHandler = filePickerCompletionHandler
            filePickerCompletionHandler = nil
            completionHandler?(urls)
        }

        private func topViewController(from rootViewController: UIViewController?) -> UIViewController? {
            guard let rootViewController else { return nil }
            if let presentedViewController = rootViewController.presentedViewController {
                return topViewController(from: presentedViewController)
            }
            if let navigationController = rootViewController as? UINavigationController {
                return topViewController(from: navigationController.visibleViewController)
            }
            if let tabBarController = rootViewController as? UITabBarController {
                return topViewController(from: tabBarController.selectedViewController)
            }
            return rootViewController
        }

        /**
         Portal Web이 카메라 접근 권한을 요청할 때 iOS 권한 흐름으로 연결합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: 권한을 요청한 WKWebView 입니다.
            - origin: 권한 요청 Origin 정보 입니다.
            - frame: 권한을 요청한 Frame 정보 입니다.
            - type: 요청한 Media Capture 타입 입니다.
            - decisionHandler: 권한 허용/거부 Callback 입니다.
         */
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            /// 현재 NF Portal 요구사항은 카메라만 허용하고 마이크 등 미정의 권한은 거부합니다.
            guard type == .camera else {
                decisionHandler(.deny)
                return
            }
            /// iOS 카메라 권한 상태를 확인합니다.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                decisionHandler(.grant)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    decisionHandler(granted ? .grant : .deny)
                }
            default:
                decisionHandler(.deny)
            }
        }

        /**
         JavaScript Bridge 메시지를 처리합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - userContentController: 메시지를 전달한 UserContentController 입니다.
            - message: JavaScript에서 전달한 ScriptMessage 입니다.
         */
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            /// Portal Google 로그인 버튼 클릭을 외부 OAuth 세션으로 연결합니다.
            if message.name == Self.googleLoginBridgeName {
                parent.onOpenExternal(PortalConfig.portalLoginURL)
                return
            }
        /// Portal 로그아웃 버튼 클릭을 Native Login 화면 전환으로 연결합니다.
        if message.name == Self.logoutBridgeName {
            parent.onLogout()
            return
        }
        /// 서버 계정 삭제 성공 후 앱 로컬 정보와 세션을 모두 삭제합니다.
        if message.name == Self.accountDeletionBridgeName {
            parent.onAccountDeleted()
            return
        }
        /// Portal 웹 설정에서 전달한 자동 로그인 ON/OFF 값을 앱 로컬 설정에 저장합니다.
        if message.name == Self.autoLoginBridgeName,
           let enabled = autoLoginEnabledValue(from: message.body) {
            parent.onAutoLoginChanged(enabled)
            return
        }
        /// Portal 웹 설정에서 전달한 PDF 파일 로컬 저장 ON/OFF 값을 앱 로컬 설정에 저장합니다.
        if message.name == Self.pdfLocalStorageBridgeName,
           let enabled = autoLoginEnabledValue(from: message.body) {
            parent.onPDFLocalStorageChanged(enabled)
            return
        }
        /// 웹 탭바의 문서 메뉴를 네이티브 PDF 문서 페이지로 전환합니다.
        if message.name == Self.pdfDocumentsBridgeName {
            parent.onOpenPDFDocuments()
            return
        }
        /// 웹에서 계산된 현재 테마 색상을 앱 전역 네이티브 팔레트로 갱신합니다.
        if message.name == Self.themeBridgeName {
            let messageBody = message.body
            Task { @MainActor [weak self] in
                self?.parent.portalThemeController.apply(messageBody: messageBody)
            }
            return
        }
#if targetEnvironment(macCatalyst)
        /// 화면 설정의 배율 슬라이더 값을 Mac Catalyst WKWebView에 즉시 적용합니다.
        if message.name == Self.macPageZoomBridgeName {
            let percent: Int? = {
                if let number = message.body as? NSNumber { return number.intValue }
                if let body = message.body as? [String: Any], let number = body["percent"] as? NSNumber { return number.intValue }
                return nil
            }()
            if let percent {
                parent.desktopChrome?.setZoom(percent: percent)
            }
            return
        }
        /// 전체 메뉴에서 발생한 SPA 경로 이동도 탭과 경로 바에 즉시 반영합니다.
        if message.name == Self.macNavigationStateBridgeName,
           let body = message.body as? [String: Any],
           let webView {
            let url = (body["url"] as? String).flatMap(URL.init(string:))
            let title = body["title"] as? String
            parent.desktopChrome?.recordCurrentPage(in: webView, url: url, title: title)
            return
        }
#endif
        }

        /**
         WebView 페이지 내부의 길게 누르기 Callout과 Context Menu Event를 차단하는 JavaScript를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - webView: JavaScript를 주입할 WKWebView 입니다.
         */
        private func injectLongPressBlocker(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSLongPressBlockerInstalled) return;
                window.__nfPortalIOSLongPressBlockerInstalled = true;

                var styleId = '__nfPortalIOSLongPressBlockerStyle';
                var style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    style.textContent = 'body *:not(input):not(textarea):not([contenteditable]):not([role="textbox"]) { -webkit-touch-callout: none !important; } a, img { -webkit-user-drag: none !important; }';
                    document.documentElement.appendChild(style);
                }

                function isEditableElement(element) {
                    if (!element || !element.closest) return false;
                    var editable = element.closest('input, textarea, select, [contenteditable], [role="textbox"], [data-editor-id], [data-inner-input-box]');
                    return !!editable || element.isContentEditable === true;
                }

                ['contextmenu', 'dragstart'].forEach(function(eventName) {
                    document.addEventListener(eventName, function(event) {
                        if (isEditableElement(event.target)) return;
                        event.preventDefault();
                    }, true);
                });
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         Portal 로그인 버튼 클릭을 Native OAuth 세션으로 연결하는 JavaScript를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: JavaScript를 주입할 WKWebView 입니다.
         */
        private func injectGoogleLoginBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSGoogleBridgeInstalled) return;
                window.__nfPortalIOSGoogleBridgeInstalled = true;
                document.addEventListener('click', function(event) {
                    var target = event.target && event.target.closest ? event.target.closest('button,a,[role="button"]') : null;
                    if (!target) return;
                    var label = (target.textContent || target.getAttribute('aria-label') || '').toLowerCase();
                    if (label.includes('google') || label.includes('구글')) {
                        event.preventDefault();
                        window.webkit.messageHandlers.NFPortalIOSGoogleLogin.postMessage('google');
                    }
                }, true);
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         Portal 로그아웃 버튼 클릭을 Native Login 화면으로 연결하는 JavaScript를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - webView: JavaScript를 주입할 WKWebView 입니다.
         */
        private func injectLogoutBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSLogoutBridgeInstalled) return;
                window.__nfPortalIOSLogoutBridgeInstalled = true;
                function isLogoutElement(element) {
                    if (!element) return false;
                    var label = [element.textContent, element.getAttribute && element.getAttribute('aria-label'), element.getAttribute && element.getAttribute('title')].filter(Boolean).join(' ').toLowerCase();
                    return label.includes('로그아웃') || label.includes('logout') || label.includes('sign out') || label.includes('signout');
                }
                document.addEventListener('click', function(event) {
                    var target = event.target && event.target.closest ? event.target.closest('button,a,[role="button"],[role="menuitem"]') : null;
                    if (!isLogoutElement(target)) return;
                    window.setTimeout(function() {
                        window.webkit.messageHandlers.NFPortalIOSLogout.postMessage('logout');
                    }, 500);
                }, true);
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /** 웹 탈퇴 완료 이벤트를 앱의 로컬 데이터 삭제 흐름으로 연결합니다. */
        private func injectAccountDeletionBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSAccountDeletionBridgeInstalled) return;
                window.__nfPortalIOSAccountDeletionBridgeInstalled = true;
                window.NFPortalIOS = window.NFPortalIOS || {};
                window.NFPortalIOS.deleteAccountLocalData = function() {
                    window.webkit.messageHandlers.NFPortalIOSAccountDeletion.postMessage('delete');
                };
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         Portal 웹 설정의 자동 로그인 토글을 iOS 설정 저장소로 연결하는 JavaScript Bridge를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.08.03
         - Parameters:
            - webView: JavaScript를 주입할 WKWebView 입니다.

         [Note]
         - 웹은 `window.NFPortalIOS.setAutoLoginEnabled(true|false)`를 호출하거나
           `nfPortalAutoLoginChanged` CustomEvent를 발생시켜 값을 전달할 수 있습니다.
         */
        private func injectAutoLoginBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSAutoLoginBridgeInstalled) return;
                window.__nfPortalIOSAutoLoginBridgeInstalled = true;
                window.NFPortalIOS = window.NFPortalIOS || {};
                window.NFPortalIOS.setAutoLoginEnabled = function(enabled) {
                    window.webkit.messageHandlers.NFPortalIOSAutoLogin.postMessage({ enabled: !!enabled });
                };
                window.addEventListener('nfPortalAutoLoginChanged', function(event) {
                    var detail = event && event.detail;
                    var enabled = typeof detail === 'boolean' ? detail : detail && detail.enabled;
                    if (typeof enabled === 'boolean') {
                        window.NFPortalIOS.setAutoLoginEnabled(enabled);
                    }
                });
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         Portal 웹 설정의 PDF 파일 로컬 저장 토글을 iOS 설정 저장소로 연결하는 JavaScript Bridge를 주입합니다.
         - Version: 1.0.0
         - Date: 2026.08.08
         - Parameters:
            - webView: JavaScript를 주입할 WKWebView 입니다.
         */
        private func injectPDFLocalStorageBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSPDFLocalStorageBridgeInstalled) return;
                window.__nfPortalIOSPDFLocalStorageBridgeInstalled = true;
                window.NFPortalIOS = window.NFPortalIOS || {};
                window.NFPortalIOS.setPDFLocalStorageEnabled = function(enabled) {
                    window.webkit.messageHandlers.NFPortalIOSPDFLocalStorage.postMessage({ enabled: !!enabled });
                };
                window.addEventListener('nfPortalPDFLocalStorageChanged', function(event) {
                    var detail = event && event.detail;
                    var enabled = typeof detail === 'boolean' ? detail : detail && detail.enabled;
                    if (typeof enabled === 'boolean') {
                        window.NFPortalIOS.setPDFLocalStorageEnabled(enabled);
                    }
                });
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /** 웹 탭바의 PDF 문서 메뉴를 네이티브 화면으로 연결합니다. */
        private func injectPDFDocumentsBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSPDFDocumentsBridgeInstalled) return;
                window.__nfPortalIOSPDFDocumentsBridgeInstalled = true;
                window.NFPortalIOS = window.NFPortalIOS || {};
                window.NFPortalIOS.openPDFDocuments = function() {
                    window.webkit.messageHandlers.NFPortalIOSPDFDocuments.postMessage('open');
                };
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         현재 웹 테마의 CSS 변수를 iOS 네이티브 팔레트로 전달하고 이후 테마 변경을 계속 감시합니다.
         - 웹 설정에서 프리셋 또는 세부 색상을 변경하면 `html`의 style/data 속성 변경을 감지합니다.
         - 앱 문서 화면을 연 뒤에도 마지막 팔레트가 유지되도록 네이티브 저장소에 전달합니다.
         */
        private func injectThemeBridge(to webView: WKWebView) {
            let script = """
            (function() {
                if (window.__nfPortalIOSThemeBridgeInstalled) {
                    if (window.NFPortalIOS && window.NFPortalIOS.syncTheme) {
                        window.NFPortalIOS.syncTheme();
                    }
                    return;
                }
                window.__nfPortalIOSThemeBridgeInstalled = true;
                window.NFPortalIOS = window.NFPortalIOS || {};

                var pendingFrame = 0;
                function cssValue(computed, name, fallback) {
                    var value = computed.getPropertyValue(name).trim();
                    return value || fallback;
                }
                function sendTheme() {
                    pendingFrame = 0;
                    var root = document.documentElement;
                    if (!root) return;
                    var computed = window.getComputedStyle(root);
                    var presetID = root.dataset.portalTheme || 'default';
                    var fallbackMuted = presetID === 'soft-gray' ? '#3b3b3b' : '#8f8f8f';
                    var fallbackSidebar = presetID === 'soft-gray' ? '#c4c4c4' : '#202020';
                    var scheme = (computed.colorScheme || '').toLowerCase();
                    window.webkit.messageHandlers.NFPortalIOSTheme.postMessage({
                        presetID: presetID,
                        backgroundColor: cssValue(computed, '--background', '#191919'),
                        surfaceColor: cssValue(computed, '--card-background', '#202020'),
                        sidebarBackgroundColor: cssValue(computed, '--sidebar-background', fallbackSidebar),
                        foregroundColor: cssValue(computed, '--foreground', '#d4d4d4'),
                        mutedColor: cssValue(computed, '--theme-muted', fallbackMuted),
                        borderColor: cssValue(computed, '--card-border', '#2f2f2f'),
                        accentColor: cssValue(computed, '--detail-animation-color', '#4667ec'),
                        colorScheme: scheme.indexOf('light') >= 0 ? 'light' : 'dark'
                    });
                }
                function scheduleThemeSync() {
                    if (pendingFrame) window.cancelAnimationFrame(pendingFrame);
                    pendingFrame = window.requestAnimationFrame(sendTheme);
                }

                window.NFPortalIOS.syncTheme = scheduleThemeSync;
                window.addEventListener('nfPortalThemeChanged', scheduleThemeSync);
                var root = document.documentElement;
                if (root) {
                    new MutationObserver(scheduleThemeSync).observe(root, {
                        attributes: true,
                        attributeFilter: ['data-portal-theme', 'style']
                    });
                }
                scheduleThemeSync();
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         iOS 앱이 지원 가능한 폰트 목록을 WKWebView JavaScript 영역에 전달합니다.
         - Version: 1.0.0
         - Date: 2026.07.30
         - Parameters:
            - webView: JavaScript를 실행할 WKWebView 입니다.
         */
        func deliverSupportedFonts(to webView: WKWebView) {
            /// 전역 변수와 CustomEvent를 함께 사용해 페이지 초기화 전/후 어느 시점에도 폰트 목록을 받을 수 있게 합니다.
            let script = """
            (function() {
                var fonts = \(portalSupportedWebViewFontPayload);
                window.__NF_PORTAL_APP_FONTS__ = fonts;
                try {
                    window.localStorage.setItem('nfPortalAppFonts', JSON.stringify(fonts));
                } catch (error) {}
                window.dispatchEvent(new CustomEvent('nfPortalAppFonts', {
                    detail: {
                        platform: 'ios',
                        fonts: fonts
                    }
                }));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         앱에 저장된 자동 로그인 값을 Portal 웹 설정 화면에 전달합니다.
         - Version: 1.0.0
         - Date: 2026.08.03
         - Parameters:
            - webView: JavaScript를 실행할 WKWebView 입니다.
         */
        func deliverAutoLoginState(to webView: WKWebView) {
            /// 전역 값·localStorage·CustomEvent를 함께 제공해 웹 설정 UI가 어느 시점에도 현재 값을 읽을 수 있게 합니다.
            let enabled = parent.autoLoginEnabled ? "true" : "false"
            let script = """
            (function() {
                var enabled = \(enabled);
                window.__NF_PORTAL_AUTO_LOGIN_ENABLED__ = enabled;
                try {
                    window.localStorage.setItem('nfPortalAutoLoginEnabled', String(enabled));
                } catch (error) {}
                window.dispatchEvent(new CustomEvent('nfPortalAutoLoginState', {
                    detail: { platform: 'ios', enabled: enabled }
                }));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         앱에 저장된 PDF 파일 로컬 저장 값을 Portal 웹 설정 화면에 전달합니다.
         - Version: 1.0.0
         - Date: 2026.08.08
         - Parameters:
            - webView: JavaScript를 실행할 WKWebView 입니다.
         */
        func deliverPDFLocalStorageState(to webView: WKWebView) {
            /// 전역 값·localStorage·CustomEvent를 함께 제공해 웹 설정 UI가 현재 값을 읽을 수 있게 합니다.
            let enabled = parent.pdfLocalStorageEnabled ? "true" : "false"
            let script = """
            (function() {
                var enabled = \(enabled);
                window.__NF_PORTAL_PDF_LOCAL_STORAGE_ENABLED__ = enabled;
                try {
                    window.localStorage.setItem('nfPortalPDFLocalStorageEnabled', String(enabled));
                } catch (error) {}
                window.dispatchEvent(new CustomEvent('nfPortalPDFLocalStorageState', {
                    detail: { platform: 'ios', enabled: enabled }
                }));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /** 로컬 PDF 문서 수를 웹 탭바에 전달해 PDF 문서 분기 표시 여부를 갱신합니다. */
        func deliverPDFDocumentLibraryState(to webView: WKWebView) {
            let count = max(0, parent.localPDFDocumentCount)
            let script = """
            (function() {
                var count = \(count);
                window.__NF_PORTAL_LOCAL_PDF_DOCUMENT_COUNT__ = count;
                try {
                    window.localStorage.setItem('nfPortalLocalPDFDocumentCount', String(count));
                } catch (error) {}
                window.dispatchEvent(new CustomEvent('nfPortalLocalPDFDocumentState', {
                    detail: { platform: 'ios', count: count }
                }));
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /**
         JavaScript Bridge Body에서 자동 로그인 Bool 값을 안전하게 추출합니다.
         - Version: 1.0.0
         - Date: 2026.08.03
         - Parameters:
            - body: WKScriptMessage가 전달한 JavaScript 값 입니다.
         - Returns: 해석 가능한 자동 로그인 값 또는 `nil` 입니다.
         */
        private func autoLoginEnabledValue(from body: Any) -> Bool? {
            if let value = body as? Bool {
                return value
            }
            if let value = body as? NSNumber {
                return value.boolValue
            }
            if let value = body as? String {
                switch value.lowercased() {
                case "true", "1", "on": return true
                case "false", "0", "off": return false
                default: return nil
                }
            }
            if let dictionary = body as? [String: Any] {
                return dictionary["enabled"].flatMap { autoLoginEnabledValue(from: $0) }
                    ?? dictionary["isEnabled"].flatMap { autoLoginEnabledValue(from: $0) }
            }
            return nil
        }

        /**
         네이티브 OAuth 결과를 WKWebView JavaScript 영역에 전달합니다.
         - Version: 1.0.0
         - Date: 2026.07.29
         - Parameters:
            - loginInfo: WKWebView에 전달할 네이티브 OAuth 로그인 정보 입니다.
            - webView: JavaScript를 실행할 WKWebView 입니다.
         */
        func deliverLoginInfo(_ loginInfo: LoginInfo, to webView: WKWebView) {
            /// JSON Payload는 localStorage와 CustomEvent 두 경로로 전달합니다.
            let payload = loginInfo.jsonPayload()
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let script = """
            (function() {
                var payload = JSON.parse('\(payload)');
                window.localStorage.setItem('nfPortalLoginInfo', JSON.stringify(payload));
                window.dispatchEvent(new CustomEvent('nfPortalLoginInfo', { detail: payload }));
            })();
            """
            webView.evaluateJavaScript(script)
        }
    }
}

// MARK: - Mac Catalyst 전용 데스크톱 Chrome

#if targetEnvironment(macCatalyst)
/** Mac Catalyst용 WebView 탐색 바의 상태와 동작을 관리합니다. */
private final class PortalDesktopChromeModel: ObservableObject {
    struct Page: Identifiable, Equatable, Codable {
        let url: URL
        let title: String
        let accessedAt: TimeInterval

        var id: String { url.absoluteString }
    }

    struct Breadcrumb: Identifiable, Equatable {
        let title: String
        let url: URL?

        var id: String { "\(title)|\(url?.absoluteString ?? "group")" }
    }

    @Published private(set) var pages: [Page] = []
    @Published private(set) var activePageID: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isNavigationMenuHidden = false
    @Published private(set) var zoomPercent: Int
    @Published private(set) var breadcrumbs: [Breadcrumb] = []

    private weak var webView: WKWebView?
    private let defaults: UserDefaults
    private static let recentPagesKey = "NFPortalMacRecentPages.v1"
    private static let zoomPercentKey = "NFPortalMacPageZoomPercent.v1"
    private static let defaultZoomPercent = 120
    private static let minimumZoomPercent = 80
    private static let maximumZoomPercent = 160

    /// WebKit이 문서 레이아웃 단계에서 적용할 Mac 전용 화면 배율입니다.
    var zoomScale: CGFloat { CGFloat(zoomPercent) / 100 }
    /// 2분할을 열 때 오른쪽 WebView가 최초로 복제할 현재 페이지입니다.
    private(set) var splitInitialURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedZoom = defaults.integer(forKey: Self.zoomPercentKey)
        zoomPercent = Self.clampedZoom(storedZoom == 0 ? Self.defaultZoomPercent : storedZoom)
        if let data = defaults.data(forKey: Self.recentPagesKey),
           let storedPages = try? JSONDecoder().decode([Page].self, from: data) {
            pages = Array(storedPages.suffix(12))
        }
    }

    /** 오른쪽 편집 영역이 현재 페이지와 탐색 표시 상태를 복제해 시작하도록 준비합니다. */
    func prepareForSplit(from source: PortalDesktopChromeModel, fallbackURL: URL) {
        let sourceURL = source.webView?.url
            ?? source.pages.first(where: { $0.id == source.activePageID })?.url
            ?? fallbackURL
        splitInitialURL = sourceURL
        pages = source.pages
        activePageID = sourceURL.absoluteString
        canGoBack = false
        canGoForward = false
        isNavigationMenuHidden = source.isNavigationMenuHidden
        zoomPercent = source.zoomPercent
        breadcrumbs = source.breadcrumbs
        webView = nil
    }

    func connect(_ webView: WKWebView) {
        let isNewWebView = self.webView !== webView
        self.webView = webView
        /// WebView 전체에 SwiftUI transform을 적용하면 대형 차트의 모든 WebKit 레이어가
        /// 매 프레임 다시 합성됩니다. 문서 배율은 WebKit 레이아웃 단계에서 처리합니다.
        let pageZoom = zoomScale
        if abs(webView.pageZoom - pageZoom) > 0.001 {
            webView.pageZoom = pageZoom
        }
        if isNewWebView {
            applyDesktopFitLayout(to: webView)
        }
        refreshNavigationState(in: webView)
    }

    func recordCurrentPage(in webView: WKWebView, url overrideURL: URL? = nil, title overrideTitle: String? = nil) {
        connect(webView)
        applyDesktopReadability(to: webView)
        if isNavigationMenuHidden {
            applyNavigationMenuVisibility(true, in: webView)
        }

        guard let url = overrideURL ?? webView.url, url.scheme == "http" || url.scheme == "https" else { return }
        let suppliedTitle = overrideTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageTitle = suppliedTitle?.isEmpty == false
            ? suppliedTitle!
            : (documentTitle?.isEmpty == false ? documentTitle! : fallbackTitle(for: url))
        let page = Page(url: url, title: pageTitle, accessedAt: Date().timeIntervalSince1970)

        pages.removeAll { $0.id == page.id }
        pages.append(page)
        if pages.count > 12 {
            pages.removeFirst(pages.count - 12)
        }
        activePageID = page.id
        persistPages()
        syncRecentAccessPages(from: webView)
        syncCurrentBreadcrumbs(from: webView)
        deliverZoomState(to: webView)
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        webView.goBack()
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let webView else { return }
            self?.refreshNavigationState(in: webView)
        }
    }

    func goForward() {
        guard let webView, webView.canGoForward else { return }
        webView.goForward()
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let webView else { return }
            self?.refreshNavigationState(in: webView)
        }
    }

    func open(_ page: Page) {
        webView?.load(URLRequest(url: page.url))
        activePageID = page.id
    }

    func toggleNavigationMenu() {
        guard let webView else { return }
        let shouldHide = !isNavigationMenuHidden
        applyNavigationMenuVisibility(shouldHide, in: webView) { [weak self, weak webView] didApply in
            guard didApply else { return }
            self?.isNavigationMenuHidden = shouldHide
            if shouldHide, let webView {
                self?.syncCurrentBreadcrumbs(from: webView)
            }
        }
    }

    /** 단일 네이티브 숨김 상태를 현재 웹 문서의 사이드바 레이아웃에 적용합니다. */
    private func applyNavigationMenuVisibility(
        _ shouldHide: Bool,
        in webView: WKWebView,
        completion: ((Bool) -> Void)? = nil
    ) {
        let targetCollapsed = shouldHide ? "true" : "false"
        let script = """
        (function() {
            // 이전 빌드가 주입한 강제 숨김 CSS는 제거합니다. 레이아웃은 포털이 직접 재계산해야 합니다.
            document.getElementById('__nfPortalDesktopSidebarStyle')?.remove();

            // 문서 로드 직후 예약된 이전 요청이 사용자의 최신 열기/닫기 요청을 덮어쓰지 않도록 구분합니다.
            var requestToken = (window.__nfPortalMacSidebarRequestToken || 0) + 1;
            window.__nfPortalMacSidebarRequestToken = requestToken;
            var currentNavigation = document.getElementById('portal-navigation');
            if (\(targetCollapsed) && currentNavigation) {
                var initialDisplay = window.getComputedStyle(currentNavigation).display;
                if (initialDisplay && initialDisplay !== 'none') {
                    window.__nfPortalMacSidebarVisibleDisplay = initialDisplay;
                }
            }

            function applyRequestedVisibility() {
                if (window.__nfPortalMacSidebarRequestToken !== requestToken) return false;
                var navigation = document.getElementById('portal-navigation');
                var content = document.getElementById('portal-content');
                var root = navigation && navigation.parentElement;
                if (!navigation || !content || !root) return false;

                if (\(targetCollapsed)) {
                    var currentDisplay = window.getComputedStyle(navigation).display;
                    if (currentDisplay && currentDisplay !== 'none') {
                        window.__nfPortalMacSidebarVisibleDisplay = currentDisplay;
                    }
                    navigation.dataset.nfPortalMacHidden = 'true';
                    navigation.style.setProperty('display', 'none', 'important');
                    root.style.setProperty('display', 'block', 'important');
                    root.style.setProperty('grid-template-columns', 'minmax(0, 1fr)', 'important');
                    content.style.setProperty('width', '100%', 'important');
                } else {
                    var visibleDisplay = window.__nfPortalMacSidebarVisibleDisplay || 'flex';
                    delete navigation.dataset.nfPortalMacHidden;
                    navigation.style.removeProperty('display');
                    root.style.removeProperty('display');
                    root.style.removeProperty('grid-template-columns');
                    content.style.removeProperty('width');

                    // 포털 상태가 비동기로 갱신된 뒤에도 숨겨져 있으면 마지막 정상 표시값으로 복원합니다.
                    if (window.getComputedStyle(navigation).display === 'none' || navigation.getBoundingClientRect().width < 1) {
                        navigation.style.setProperty('display', visibleDisplay, 'important');
                    }
                }
                return true;
            }

            var request = new CustomEvent('nfPortalDesktopSidebarToggle', {
                detail: { collapsed: \(targetCollapsed), platform: 'mac' },
                cancelable: true
            });
            // 포털이 이 이벤트를 처리하면 preventDefault()로 처리 완료를 알립니다.
            var handledByPortal = !window.dispatchEvent(request);
            var appliedImmediately = applyRequestedVisibility();

            // React 렌더링이 늦게 끝나는 페이지에서도 가장 최근 요청만 다시 적용합니다.
            [0, 80, 250].forEach(function(delay) {
                setTimeout(applyRequestedVisibility, delay);
            });
            return handledByPortal || appliedImmediately;
        })();
        """
        webView.evaluateJavaScript(script) { result, _ in
            let didApply = (result as? Bool) == true || (result as? NSNumber)?.boolValue == true
            DispatchQueue.main.async {
                completion?(didApply)
            }
        }
    }

    func refreshNavigationState(in webView: WKWebView) {
        self.webView = webView
        if canGoBack != webView.canGoBack {
            canGoBack = webView.canGoBack
        }
        if canGoForward != webView.canGoForward {
            canGoForward = webView.canGoForward
        }
        if let currentURL = webView.url, activePageID != currentURL.absoluteString {
            activePageID = currentURL.absoluteString
        }
    }

    func setZoom(percent: Int) {
        let next = Self.clampedZoom(percent)
        zoomPercent = next
        defaults.set(next, forKey: Self.zoomPercentKey)
        guard let webView else { return }
        webView.pageZoom = zoomScale
        applyDesktopFitLayout(to: webView)
        let currentOffset = webView.scrollView.contentOffset
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: currentOffset.y), animated: false)
        deliverZoomState(to: webView)
    }

    private static func clampedZoom(_ value: Int) -> Int {
        let stepped = Int((Double(value) / 5).rounded()) * 5
        return min(maximumZoomPercent, max(minimumZoomPercent, stepped))
    }

    private func persistPages() {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        defaults.set(data, forKey: Self.recentPagesKey)
    }

    /** 현재 활성 메뉴의 실제 사이드바 계층을 읽어 Mac 경로 바로 전달합니다. */
    private func syncCurrentBreadcrumbs(from webView: WKWebView) {
        let script = """
        (function() {
            var navigation = document.getElementById('portal-navigation');
            if (!navigation) return [];

            function cleanLabel(value) {
                return String(value || '').replace(/\\s+/g, ' ').trim();
            }
            function conciseLabel(element) {
                if (!element) return '';
                var explicit = element.getAttribute('data-navigation-label') ||
                    element.getAttribute('data-section-title') ||
                    element.getAttribute('aria-label');
                if (explicit) return cleanLabel(explicit);
                var preferred = element.querySelector(':scope > span.truncate, :scope > span:not([aria-hidden="true"]), :scope > strong, :scope > h1, :scope > h2, :scope > h3');
                return cleanLabel(preferred ? preferred.textContent : element.textContent);
            }
            function normalizedLocation(anchor) {
                try {
                    var url = new URL(anchor.href, window.location.href);
                    return url.pathname.replace(/\\/$/, '') + url.search;
                } catch (_) {
                    return '';
                }
            }

            var currentPath = window.location.pathname.replace(/\\/$/, '') + window.location.search;
            var links = Array.from(navigation.querySelectorAll('a[href]'));
            var activeLink = links.find(function(anchor) {
                return anchor.getAttribute('aria-current') === 'page';
            }) || links.find(function(anchor) {
                return normalizedLocation(anchor) === currentPath;
            });
            if (!activeLink) return [];

            var row = activeLink.closest('[data-navigation-key], li, [role="treeitem"]') || activeLink;
            var branch = row;
            var ancestors = [];
            while (branch && branch !== navigation) {
                var parent = branch.parentElement;
                if (!parent || parent === navigation) break;
                ancestors.unshift({ container: parent, branch: branch });
                branch = parent;
            }

            var labels = [];
            ancestors.forEach(function(level) {
                var children = Array.from(level.container.children);
                var branchIndex = children.indexOf(level.branch);
                if (branchIndex < 0) return;
                var candidates = children.slice(0, branchIndex).filter(function(child) {
                    return child.matches('[data-navigation-label], [data-section-title], h1, h2, h3, h4, button, [role="button"]') &&
                        !child.matches('a[href]');
                });
                var candidate = candidates[candidates.length - 1];
                var label = conciseLabel(candidate);
                if (label && label.length <= 40 && !labels.includes(label)) labels.push(label);
            });

            var navigationKey = cleanLabel(row.getAttribute && row.getAttribute('data-navigation-key'));
            if (labels.length === 0 && /[>›/]/.test(navigationKey)) {
                labels = navigationKey.split(/\\s*[>›/]\\s*/).map(cleanLabel).filter(Boolean);
            }

            var pageLabel = conciseLabel(activeLink.querySelector('span.truncate') || activeLink);
            if (!pageLabel) pageLabel = cleanLabel(document.title) || '현재 페이지';
            labels = labels.filter(function(label) { return label !== pageLabel; });
            labels.push(pageLabel);

            var originURL = window.location.origin + '/';
            return [{ title: 'NF Portal', url: originURL }].concat(labels.map(function(label, index) {
                return { title: label, url: index === labels.length - 1 ? activeLink.href : null };
            }));
        })();
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            guard let self, let webView else { return }
            let records = result as? [[String: Any]] ?? []
            let resolved = records.compactMap { record -> Breadcrumb? in
                guard let rawTitle = record["title"] as? String else { return nil }
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let url = (record["url"] as? String).flatMap(URL.init(string:))
                return Breadcrumb(title: title, url: url)
            }
            let fallback: [Breadcrumb] = {
                guard let url = webView.url else { return [] }
                let currentTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = currentTitle?.isEmpty == false ? currentTitle! : self.fallbackTitle(for: url)
                return [
                    Breadcrumb(title: "NF Portal", url: URL(string: "/", relativeTo: url)?.absoluteURL),
                    Breadcrumb(title: title, url: url)
                ]
            }()
            DispatchQueue.main.async {
                self.breadcrumbs = resolved.isEmpty ? fallback : resolved
            }
        }
    }

    /** 포털이 관리하는 최근 접속 이력을 오래된 항목부터 최신 항목 순으로 상단 탭에 동기화합니다. */
    private func syncRecentAccessPages(from webView: WKWebView) {
        let script = """
        (function() {
            try {
                var accessed = JSON.parse(window.localStorage.getItem('hlp-navigation-recent-access') || '{}');
                var rows = Array.from(document.querySelectorAll('[data-navigation-key]'));
                return Object.entries(accessed)
                    .filter(function(entry) { return Number.isFinite(Number(entry[1])); })
                    .sort(function(first, second) { return Number(first[1]) - Number(second[1]); })
                    .map(function(entry) {
                        var key = entry[0];
                        var row = rows.find(function(element) { return element.getAttribute('data-navigation-key') === key; });
                        var link = row && row.querySelector('a[href]');
                        if (!link) return null;
                        var label = row.querySelector('span.truncate') || link.querySelector('span') || link;
                        return { url: link.href, title: (label.textContent || '').trim(), accessedAt: Number(entry[1]) / 1000 };
                    })
                    .filter(Boolean)
                    .slice(-12);
            } catch (_) {
                return [];
            }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let records = result as? [[String: Any]], !records.isEmpty else { return }
            var synchronized: [Page] = []
            for record in records {
                guard let urlText = record["url"] as? String,
                      let url = URL(string: urlText),
                      let accessedAt = (record["accessedAt"] as? NSNumber)?.doubleValue else { continue }
                let rawTitle = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let page = Page(url: url, title: rawTitle?.isEmpty == false ? rawTitle! : self.fallbackTitle(for: url), accessedAt: accessedAt)
                synchronized.removeAll { $0.id == page.id }
                synchronized.append(page)
            }
            guard !synchronized.isEmpty else { return }
            DispatchQueue.main.async {
                self.pages = synchronized
                if let currentURL = webView.url?.absoluteString {
                    self.activePageID = currentURL
                }
                self.persistPages()
            }
        }
    }

    private func deliverZoomState(to webView: WKWebView) {
        let script = """
        (function() {
            var percent = \(zoomPercent);
            try { window.localStorage.setItem('nfPortalMacPageZoom', String(percent)); } catch (_) {}
            window.dispatchEvent(new CustomEvent('nfPortalMacZoomState', { detail: { percent: percent } }));
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func applyDesktopReadability(to webView: WKWebView) {
#if targetEnvironment(macCatalyst)
        applyDesktopFitLayout(to: webView)
        let script = """
        (function() {
            var styleId = '__nfPortalDesktopReadabilityStyle';
            if (document.getElementById(styleId)) return;
            var style = document.createElement('style');
            style.id = styleId;
            style.textContent = `
                body { -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
            `;
            document.head.appendChild(style);
        })();
        """
        webView.evaluateJavaScript(script)
#endif
    }

    /** WebKit 문서 배율 변경 후에도 문서가 가로로 넘치지 않도록 웹 레이아웃 폭을 제한합니다. */
    private func applyDesktopFitLayout(to webView: WKWebView) {
        let script = """
        (function() {
            var styleId = '__nfPortalDesktopFitLayoutStyle';
            var style = document.getElementById(styleId);
            var css = `
                html, body {
                    width: 100% !important;
                    max-width: 100% !important;
                    overflow-x: hidden !important;
                    overscroll-behavior-x: none !important;
                }
                #portal-content,
                .portal-content-scroll-host {
                    min-width: 0 !important;
                    max-width: 100% !important;
                    overflow-x: hidden !important;
                    box-sizing: border-box !important;
                }
                #portal-main {
                    width: 100% !important;
                    min-width: 0 !important;
                    max-width: min(var(--portal-main-max-width, 100%), 100%) !important;
                    overflow-x: clip !important;
                    box-sizing: border-box !important;
                }
            `;
            if (!style) {
                style = document.createElement('style');
                style.id = styleId;
                document.head.appendChild(style);
            }
            if (style.textContent !== css) style.textContent = css;
            if (document.documentElement.scrollLeft !== 0) document.documentElement.scrollLeft = 0;
            if (document.body.scrollLeft !== 0) document.body.scrollLeft = 0;
            var host = document.querySelector('.portal-content-scroll-host');
            if (host && host.scrollLeft !== 0) host.scrollLeft = 0;
            return true;
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private func fallbackTitle(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? (url.host ?? "Portal") : path
    }
}

/** 각 분할 영역의 탭·경로·WebView를 독립적으로 구성합니다. */
private struct PortalDesktopPane<Content: View>: View {
    @ObservedObject var model: PortalDesktopChromeModel
    let theme: PortalAppTheme
    let reservesTrafficLightArea: Bool
    let showsBreadcrumbs: Bool
    let isSplitViewEnabled: Bool
    let onToggleSplitView: () -> Void
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PortalDesktopToolbar(
                model: model,
                theme: theme,
                reservesTrafficLightArea: reservesTrafficLightArea,
                isSplitViewEnabled: isSplitViewEnabled,
                onToggleSplitView: onToggleSplitView
            )
            if showsBreadcrumbs {
                PortalDesktopBreadcrumbBar(model: model, theme: theme)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/** 데스크톱 앱처럼 페이지 히스토리를 탭으로 보여 주는 상단 탐색 바입니다. */
private struct PortalDesktopToolbar: View {
    @ObservedObject var model: PortalDesktopChromeModel
    let theme: PortalAppTheme
    let reservesTrafficLightArea: Bool
    let isSplitViewEnabled: Bool
    let onToggleSplitView: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleNavigationMenu) {
                Image(systemName: model.isNavigationMenuHidden ? "line.3.horizontal" : "sidebar.left")
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(model.isNavigationMenuHidden ? "전체 메뉴 열기" : "전체 메뉴 닫기")
            .help(model.isNavigationMenuHidden ? "전체 메뉴 열기" : "전체 메뉴 닫기")

            Divider().frame(height: 22)

            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("뒤로 가기")

            Button(action: model.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("앞으로 가기")

            Divider().frame(height: 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.pages) { page in
                        Button {
                            model.open(page)
                        } label: {
                            Text(page.title)
                                .lineLimit(1)
                                .frame(maxWidth: 190)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(page.id == model.activePageID ? theme.accent.color.opacity(0.24) : theme.background.color.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(page.url.absoluteString)
                    }
                }
                .padding(.horizontal, 2)
            }

            Divider().frame(height: 22)

            Button(action: onToggleSplitView) {
                Image(systemName: isSplitViewEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .frame(width: 22, height: 22)
            }
            .fixedSize()
            .accessibilityLabel(isSplitViewEnabled ? "화면 2분할 닫기" : "화면 좌우 2분할")
            .help(isSplitViewEnabled ? "화면 2분할 닫기" : "현재 페이지를 좌우로 2분할")

            Divider().frame(height: 22)

            Menu {
                ForEach(Array(stride(from: 80, through: 160, by: 5)), id: \.self) { percent in
                    Button {
                        model.setZoom(percent: percent)
                    } label: {
                        if percent == model.zoomPercent {
                            Label("\(percent)%", systemImage: "checkmark")
                        } else {
                            Text("\(percent)%")
                        }
                    }
                }
            } label: {
                Label("\(model.zoomPercent)%", systemImage: "textformat.size")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("웹 콘텐츠 화면 배율")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(theme.foreground.color)
        .padding(.leading, reservesTrafficLightArea ? 92 : 12)
        .padding(.trailing, 14)
        .frame(height: 46)
        .background(theme.surface.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border.color).frame(height: 1)
        }
        .buttonStyle(.borderless)
    }
}

/** 전체 메뉴가 접힌 동안 현재 Portal 메뉴 계층을 Xcode 스타일로 표시하는 경로 바입니다. */
private struct PortalDesktopBreadcrumbBar: View {
    @ObservedObject var model: PortalDesktopChromeModel
    let theme: PortalAppTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, breadcrumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.muted.color)
                    }
                    if let url = breadcrumb.url {
                        Button {
                            model.open(.init(url: url, title: breadcrumb.title, accessedAt: Date().timeIntervalSince1970))
                        } label: {
                            if index == 0 {
                                Label {
                                    Text(breadcrumb.title).lineLimit(1)
                                } icon: {
                                    Image(systemName: "square.grid.2x2")
                                }
                            } else {
                                Text(breadcrumb.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(breadcrumb.title)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(theme.foreground.color)
        .frame(height: 36)
        .background(theme.surface.color)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border.color).frame(height: 1)
        }
    }
}

/** 기본 macOS 제목을 숨겨 신호등과 같은 높이의 테마형 통합 헤더를 표시합니다. */
private struct MacCatalystTitlebarConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        TitlebarConfigurationView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? TitlebarConfigurationView)?.configureTitlebarIfPossible()
    }

    private final class TitlebarConfigurationView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureTitlebarIfPossible()
        }

        func configureTitlebarIfPossible() {
            guard let titlebar = window?.windowScene?.titlebar else { return }
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
            titlebar.separatorStyle = .none
        }
    }
}
#endif
