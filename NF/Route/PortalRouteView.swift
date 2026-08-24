//
//  PortalRouteView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import AuthenticationServices
import SwiftUI

/**
 Intro, OnBoarding, Login, WebView 화면 전환을 담당하는 Root Route View 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalRouteViewModel``, ``PortalRouteState``
 */
struct PortalRouteView: View {
    /// 현재 웹 테마의 네이티브 색상 팔레트입니다.
    @Environment(\.portalAppTheme) private var portalTheme
    /// Route 화면 상태와 UI 기능을 처리하는 ViewModel 입니다.
    @StateObject private var viewModel = PortalRouteViewModel()
    /// Intro 로고와 Login 카드 로고 사이의 이동 애니메이션을 관리하는 Namespace 입니다.
    @Namespace private var introLoginAnimation
    /// Google OAuth 외부 인증 세션을 관리하는 Coordinator 입니다.
    @StateObject private var oauthCoordinator = PortalOAuthSessionCoordinator()
    /// iOS 안내 Alert 메시지 입니다.
    @State private var routeMessage: String?
    /// 현재 앱 내부 PDF 미리보기로 표시할 첨부 파일 정보입니다.
    @State private var attachmentPreviewItem: PortalAttachmentPreviewItem?
    /// 웹 탭바에서 진입한 네이티브 PDF 문서 페이지 표시 여부입니다.
    @State private var isPDFDocumentsPresented = false
    /// 현재 로컬에 보관 중인 활성·휴지통 PDF 문서 수입니다.
    @State private var localPDFDocumentCount = 0
    /// 탭바 표시 조건과 네이티브 문서 페이지가 공유하는 로컬 저장소입니다.
    private let pdfLocalStorageRepository = PortalPDFLocalStorageRepository()
    /// 현재 Sign in with Apple 요청과 서버 검증을 연결하는 원본 nonce 입니다.
    @State private var appleRawNonce: String?

    /**
     현재 Route 목적지에 맞는 화면을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        ZStack {
            /// 현재 목적지 기준으로 화면을 전환합니다.
            switch viewModel.state.destination {
            case .intro:
                IntroView(
                    onFinished: {
                        /// Intro가 Login으로 직접 연결되는 경우 카드와 로고가 함께 자연스럽게 나타나도록 애니메이션을 적용합니다.
                        withAnimation(.easeInOut(duration: 0.72)) {
                            viewModel.onIntroFinished()
                        }
                    },
                    animationNamespace: introLoginAnimation
                )
                .transition(.opacity)
            case .onBoarding:
                OnBoardingView(onStartLogin: viewModel.onStartLogin)
            case .login:
                LoginView(
                    isProcessing: viewModel.state.authExchangeStatus == .exchanging,
                    onGoogleLogin: openGoogleLogin,
                    onAppleRequest: prepareAppleLogin,
                    onAppleCompletion: completeAppleLogin,
                    animationNamespace: introLoginAnimation
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .center)),
                    removal: .opacity
                ))
            case .webView:
                PortalWebView(
                    portalURL: viewModel.state.portalDashboardURL,
                    loginInfo: viewModel.state.loginInfo,
                    onLoginInfo: viewModel.onLoginInfoReceived,
                    onOpenExternal: openExternalURL,
                    onPreviewAttachment: presentAttachmentPreview,
                    onLogout: viewModel.onPortalLogout,
                    onAccountAccessIssue: viewModel.onPortalAccountAccessIssue,
                    onAccountDeleted: viewModel.onAccountDeleted,
                    onNetworkUnavailable: viewModel.onPortalNetworkUnavailable,
                    onAutoLoginChanged: viewModel.onAutoLoginChanged,
                    autoLoginEnabled: viewModel.state.isAutoLoginEnabled,
                    onPDFLocalStorageChanged: viewModel.onPDFLocalStorageChanged,
                    pdfLocalStorageEnabled: viewModel.state.isPDFLocalStorageEnabled,
                    onOpenPDFDocuments: openPDFDocuments,
                    localPDFDocumentCount: localPDFDocumentCount
                )
            case .setup:
                LoginView(
                    isProcessing: false,
                    onGoogleLogin: openGoogleLogin,
                    onAppleRequest: prepareAppleLogin,
                    onAppleCompletion: completeAppleLogin,
                    animationNamespace: introLoginAnimation
                )
            }
        }
        .animation(.easeInOut(duration: 0.72), value: viewModel.state.destination)
        .background(portalTheme.backgroundColor.ignoresSafeArea())
        .onOpenURL { url in
            if url.isFileURL {
                importExternalPDF(url)
                return
            }
            /// 앱 외부 Deep Link로 인증 결과가 들어온 경우 LoginInfo로 변환합니다.
            if let loginInfo = LoginInfo(url: url) {
                viewModel.onLoginInfoReceived(loginInfo)
            }
        }
        .onChange(of: viewModel.state.authExchangeMessage) { _, message in
            /// ViewModel의 일회성 메시지를 Alert로 표시합니다.
            routeMessage = message
        }
        .fullScreenCover(item: $attachmentPreviewItem) { item in
            PortalPDFPreviewView(
                item: item,
                onPDFLocalStorageEnabled: {
                    viewModel.onPDFLocalStorageChanged(true)
                }
            )
        }
        .fullScreenCover(isPresented: $isPDFDocumentsPresented) {
            PortalPDFDocumentsView()
        }
        .task {
            refreshLocalPDFDocumentCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: PortalPDFLocalStorageRepository.didChangeNotification)) { _ in
            refreshLocalPDFDocumentCount()
        }
        .alert("안내", isPresented: routeMessageBinding) {
            Button("확인") {
                viewModel.onRouteMessageConsumed()
            }
        } message: {
            Text(routeMessage ?? "")
        }
    }

    /**
     Google OAuth 외부 인증을 시작합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    private func openGoogleLogin() {
        oauthCoordinator.start(url: viewModel.state.portalLoginURL) { result in
            switch result {
            case .success(let loginInfo):
                /// 외부 인증이 성공한 경우 서버 세션 교환을 시작합니다.
                viewModel.onLoginInfoReceived(loginInfo)
            case .failure:
                /// 사용자가 인증을 취소하거나 Callback이 유효하지 않으면 Login 화면에 머무릅니다.
                routeMessage = "Google 로그인을 완료하지 못했습니다. 다시 시도해 주세요."
            }
        }
    }

    /** Apple 인증 요청에 사용자 정보 scope와 재전송 방지 nonce를 설정합니다. */
    private func prepareAppleLogin(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let rawNonce = try AppleSignInNonce.random()
            appleRawNonce = rawNonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInNonce.sha256(rawNonce)
        } catch {
            appleRawNonce = nil
            routeMessage = "Apple 로그인을 준비하지 못했습니다. 다시 시도해 주세요."
        }
    }

    /** Apple 인증 결과를 NF 서버 검증 및 Portal 세션 교환 흐름으로 전달합니다. */
    private func completeAppleLogin(_ result: Result<ASAuthorization, Error>) {
        defer { appleRawNonce = nil }
        guard case .success(let authorization) = result,
              let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let rawNonce = appleRawNonce,
              let tokenData = appleCredential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            routeMessage = "Apple 로그인을 완료하지 못했습니다. 다시 시도해 주세요."
            return
        }

        let authorizationCode = appleCredential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        let fullName = AppleLoginFullName(
            givenName: appleCredential.fullName?.givenName,
            familyName: appleCredential.fullName?.familyName
        )
        viewModel.onAppleCredentialReceived(AppleLoginCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce,
            fullName: fullName
        ))
    }

    /**
     Portal 첨부 파일을 앱 내부 PDF 미리보기 전체 화면으로 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - item: PDF 미리보기 화면에 전달할 첨부 파일 정보입니다.
     */
    private func presentAttachmentPreview(_ item: PortalAttachmentPreviewItem) {
        /// fullScreenCover(item:) 상태를 갱신해 현재 Route 위에 PDF 미리보기를 전체 화면으로 표시합니다.
        attachmentPreviewItem = item
    }

    /** 웹 탭바의 PDF 문서 메뉴에서 네이티브 문서 페이지로 전환합니다. */
    private func openPDFDocuments() {
        refreshLocalPDFDocumentCount()
        isPDFDocumentsPresented = true
    }

    /** Files 앱이나 공유 화면에서 전달한 PDF를 네이티브 문서 라이브러리에 저장합니다. */
    private func importExternalPDF(_ url: URL) {
        Task {
            do {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                _ = try pdfLocalStorageRepository.createDocument(
                    data: data,
                    fileName: url.lastPathComponent
                )
                refreshLocalPDFDocumentCount()
                isPDFDocumentsPresented = true
            } catch {
                routeMessage = "선택한 PDF 문서를 NF로 가져오지 못했습니다."
            }
        }
    }

    /** 로컬 PDF 수를 다시 계산해 WebView 탭바 표시 조건에 전달합니다. */
    private func refreshLocalPDFDocumentCount() {
        localPDFDocumentCount = pdfLocalStorageRepository.documents().count
            + pdfLocalStorageRepository.folders().count
    }

    /**
     Portal 외부 URL을 외부 브라우저 흐름으로 엽니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: 외부로 열 URL 입니다.
     */
    private func openExternalURL(_ url: URL) {
        /// Portal Login URL은 OAuth 세션으로 열고, 그 외 URL은 시스템 브라우저로 전달합니다.
        if url == PortalConfig.portalLoginURL {
            openGoogleLogin()
        } else {
            UIApplication.shared.open(url)
        }
    }

    /**
     Alert 표시 여부를 Route 메시지 상태와 연결합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `Binding<Bool>`
     */
    private var routeMessageBinding: Binding<Bool> {
        Binding(
            get: { routeMessage != nil },
            set: { isPresented in
                if !isPresented {
                    routeMessage = nil
                    viewModel.onRouteMessageConsumed()
                }
            }
        )
    }
}

#Preview {
    PortalRouteView()
        .environmentObject(PortalAppThemeController())
}
