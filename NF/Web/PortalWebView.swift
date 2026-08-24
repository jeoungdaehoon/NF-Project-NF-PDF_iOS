//
//  PortalWebView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import AVFoundation
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
struct PortalWebView: UIViewRepresentable {
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
    /// WebView 화면 데이터와 UI 기능을 처리하는 ViewModel 입니다.
    @StateObject private var viewModel = PortalWebViewModel()

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
        /// WKWebView 기본 설정 입니다.
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
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
    }
}

// MARK: - WKWebView Delegate Coordinator 입니다.
extension PortalWebView {
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
        /// 부모 PortalWebView 정보 입니다.
        var parent: PortalWebView
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
        init(parent: PortalWebView, viewModel: PortalWebViewModel) {
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
