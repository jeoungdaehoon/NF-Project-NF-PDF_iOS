//
//  NFApp.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI
import UIKit

/**
 NF iOS 앱의 단일 진입점 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalRouteView``
 */
@main
struct NFApp: App {
    /// 웹에서 전달한 테마를 네이티브 문서 화면과 Safe Area가 함께 사용합니다.
    @StateObject private var portalThemeController = PortalAppThemeController()

    init() {
        /// 시스템 Launch Screen에서 첫 SwiftUI 프레임으로 전환될 때 흰 Window 배경이 노출되지 않도록
        /// Intro와 동일한 NF 기본 배경색을 앱 Window 기본값으로 사용합니다.
        UIWindow.appearance().backgroundColor = UIColor(NFColor.background)
    }

    /**
     앱 Scene 구성을 리턴합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some Scene`
     */
    var body: some Scene {
        WindowGroup {
            /// Android 프로젝트와 동일하게 Route 화면이 Intro, OnBoarding, Login, WebView 흐름을 관리합니다.
            PortalRouteView()
                .environmentObject(portalThemeController)
                .environment(\.portalAppTheme, portalThemeController.theme)
                .preferredColorScheme(portalThemeController.theme.colorScheme)
        }
    }
}
