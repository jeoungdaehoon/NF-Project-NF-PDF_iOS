//
//  PortalRouteState.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 Portal 상위 Route 화면에서 처리되는 데이터를 관리하는 State 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalRouteViewModel``, ``PortalRouteView``
 */
struct PortalRouteState {
    /// 현재 표시해야 하는 상위 화면 목적지 입니다.
    var destination: PortalDestination = .intro
    /// 외부 OAuth 인증 후 WKWebView로 전달해야 하는 로그인 정보 입니다.
    var loginInfo: LoginInfo?
    /// WKWebView가 표시해야 하는 Portal Dashboard URL 입니다.
    var portalDashboardURL: URL = PortalConfig.portalDashboardURL
    /// 외부 인증 화면에서 열어야 하는 Portal Login URL 입니다.
    var portalLoginURL: URL = PortalConfig.portalLoginURL
    /// OAuth 인증 결과를 Portal WebView 세션으로 교환하는 현재 상태 입니다.
    var authExchangeStatus: AuthExchangeStatus = .idle
    /// 화면에 한 번만 표시할 포털 진입 로그인 정보 확인 결과 메시지 입니다.
    var authExchangeMessage: String?
    /// Portal 웹 설정에서 전달된 자동 로그인 사용 여부 입니다.
    var isAutoLoginEnabled: Bool = false
    /// Portal 웹 설정에서 전달된 PDF 파일 로컬 저장 사용 여부 입니다.
    var isPDFLocalStorageEnabled: Bool = false
}

/**
 외부 OAuth 인증 결과를 Portal WKWebView 세션으로 교환하는 상태 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum AuthExchangeStatus: Equatable {
    /// 교환 요청 전 기본 상태 입니다.
    case idle
    /// 서버 세션 교환 진행 중 상태 입니다.
    case exchanging
    /// 서버 세션 교환 성공 상태 입니다.
    case authenticated
    /// 서버 세션 교환 실패 상태 입니다.
    case failed
}
