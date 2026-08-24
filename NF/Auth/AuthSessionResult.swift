//
//  AuthSessionResult.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 OAuth 인증 결과를 Portal WebView 세션으로 교환한 결과 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct AuthSessionResult {
    /// 인증 완료 후 WKWebView가 열어야 하는 Portal URL 입니다.
    let redirectURL: URL
    /// WKWebView CookieStore에 세팅한 Cookie 개수 입니다.
    let cookieCount: Int
}
