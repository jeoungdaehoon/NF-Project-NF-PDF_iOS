//
//  PortalWebViewModel.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation
import Combine

/**
 Portal WKWebView 화면의 UI 기능과 데이터 처리를 담당하는 ViewModel 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalWebViewState``, ``PortalWebView``
 */
@MainActor
final class PortalWebViewModel: ObservableObject {
    /// WebView 화면에서 표시/처리할 상태 정보 입니다.
    @Published private(set) var state = PortalWebViewState()

    /**
     Route에서 전달된 Portal URL을 State에 반영합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - portalURL: WKWebView가 로드해야 하는 Portal URL 입니다.
     */
    func setPortalURL(_ portalURL: URL) {
        updateState { currentState in
            currentState.portalURL = PortalConfig.normalizePortalURL(portalURL)
        }
    }

    /**
     Route에서 전달된 로그인 정보를 State에 반영합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - loginInfo: WKWebView JavaScript 영역으로 전달할 로그인 정보 입니다.
     */
    func setLoginInfo(_ loginInfo: LoginInfo?) {
        updateState { currentState in
            currentState.loginInfo = loginInfo
        }
    }

    /**
     WKWebView 뒤로가기 가능 여부를 갱신합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - canGoBack: WKWebView.canGoBack 결과 값 입니다.
     */
    func setCanGoBack(_ canGoBack: Bool) {
        updateState { currentState in
            currentState.canGoBack = canGoBack
        }
    }

    /**
     Portal 내부 URL 여부를 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: WKWebView가 이동하려는 URL 입니다.
     - Returns: `Bool`
     */
    func isPortalURL(_ url: URL) -> Bool {
        return PortalConfig.isPortalURL(url)
    }

    /**
     Portal Google 로그인 시작 URL 여부를 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: WKWebView가 이동하려는 URL 입니다.
     - Returns: `Bool`
     */
    func isPortalGoogleAuthStartURL(_ url: URL) -> Bool {
        /// NextAuth Google Provider 시작 URL이면 외부 OAuth 세션으로 위임합니다.
        return url.path.contains("/api/auth/signin") && url.absoluteString.contains("google")
    }

    /**
     Portal 로그아웃 URL 여부를 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: WKWebView가 이동하려는 URL 입니다.
     - Returns: `Bool`
     */
    func isPortalLogoutRoute(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/logout") || path.contains("/login") || path.contains("/api/auth/signout")
    }

    /** Portal이 현재 인증 세션의 계정을 사용할 수 없다고 판정한 URL인지 확인합니다. */
    func isPortalAccountAccessIssueRoute(_ url: URL) -> Bool {
        return url.path.lowercased().hasPrefix("/account-disabled")
    }

    /**
     Route State를 갱신합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - transform: 변경할 State 처리 블록 입니다.
     */
    private func updateState(_ transform: (inout PortalWebViewState) -> Void) {
        var nextState = state
        transform(&nextState)
        state = nextState
    }
}
