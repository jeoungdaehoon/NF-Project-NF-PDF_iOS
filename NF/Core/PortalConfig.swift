//
//  PortalConfig.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 NF Portal iOS 앱에서 공유하는 서버 및 라우팅 설정 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum PortalConfig {
    /// 운영 Portal Host 정보 입니다.
    static let portalHost = "hlp-project-portal-745194786909.asia-northeast3.run.app"
    /// 운영 Portal Origin 정보 입니다.
    static let portalOrigin = "https://\(portalHost)"
    /// WebView에서 표시할 Dashboard URL 정보 입니다.
    static let portalDashboardURL = URL(string: "\(portalOrigin)/dashboard")!
    /// 외부 Google OAuth를 바로 시작할 Portal Login URL 정보 입니다.
    static let portalLoginURL = URL(string: "\(portalOrigin)/api/auth/start-google?callbackUrl=%2Fapi%2Fauth%2Fmobile%2Fcomplete")!
    /// 모바일 OAuth 인증 결과를 WKWebView 세션으로 교환하는 API URL 정보 입니다.
    static let portalAuthSessionExchangeURL = URL(string: "\(portalOrigin)/api/auth/mobile/exchange")!
    /// iOS Sign in with Apple 결과를 서버 검증 후 모바일 ticket으로 교환하는 API URL 정보 입니다.
    static let portalAppleLoginURL = URL(string: "\(portalOrigin)/api/auth/mobile/apple")!
    /// Android와 서버 OAuth 설정을 공유하기 위한 앱 Callback Scheme 입니다.
    static let oauthCallbackScheme = "com.nf.portal"
    /// 서버에서 iOS WKWebView 요청과 현재 앱 버전을 식별할 수 있도록 UserAgent에 추가하는 값 입니다.
    static var userAgentSuffix: String { AppVersion.userAgentSuffix }

    /**
     Portal WebView에서 열 URL을 운영 도메인 기준으로 보정합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - rawURL: 서버 응답 또는 저장 상태에서 전달된 Portal 후보 URL 입니다.
     - Returns: `URL`
     */
    static func normalizePortalURL(_ rawURL: URL?) -> URL {
        /// URL 값이 없는 경우 기본 Dashboard URL을 사용합니다.
        guard let rawURL else {
            return portalDashboardURL
        }
        /// 운영 도메인 URL은 그대로 사용합니다.
        guard let host = rawURL.host else {
            return portalDashboardURL
        }
        /// Portal 운영 도메인인 경우 원본 URL을 유지합니다.
        if host == portalHost {
            return rawURL
        }
        /// 개발 서버 URL이 내려오면 휴대폰 localhost 오동작을 막기 위해 운영 도메인으로 치환합니다.
        if isLocalDevelopmentHost(host) {
            var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = portalHost
            components?.port = nil
            return components?.url ?? portalDashboardURL
        }
        /// 외부 도메인은 WebView 시작 URL로 사용하지 않습니다.
        return portalDashboardURL
    }

    /**
     Portal 내부 URL 여부를 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: WebView 또는 외부 인증에서 전달된 URL 입니다.
     - Returns: `Bool`
     */
    static func isPortalURL(_ url: URL) -> Bool {
        return url.host == portalHost
    }

    /**
     개발 서버 Host 여부를 확인합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - host: URL Host 문자열 입니다.
     - Returns: `Bool`
     */
    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host.hasSuffix(".local")
    }
}
