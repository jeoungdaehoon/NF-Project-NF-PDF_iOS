//
//  PortalDestination.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 NF iOS 앱의 상위 화면 목적지 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum PortalDestination: String {
    /// 앱 브랜드 Intro 화면 입니다.
    case intro
    /// 최초 1회 권한 안내 화면 입니다.
    case onBoarding
    /// Google 로그인 진입 화면 입니다.
    case login
    /// NF Portal WKWebView 화면 입니다.
    case webView
    /// 추후 설정 화면 확장 목적지 입니다.
    case setup
}
