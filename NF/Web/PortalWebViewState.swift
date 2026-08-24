//
//  PortalWebViewState.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 Portal WKWebView 화면에서 처리되는 데이터를 관리하는 State 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct PortalWebViewState {
    /// WKWebView가 로드해야 하는 Portal URL 입니다.
    var portalURL: URL = PortalConfig.portalDashboardURL
    /// WKWebView JavaScript 영역으로 전달해야 하는 로그인 정보 입니다.
    var loginInfo: LoginInfo?
    /// WKWebView 내부 히스토리 뒤로가기 가능 여부 입니다.
    var canGoBack = false
}
