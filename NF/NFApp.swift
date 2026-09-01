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
#if targetEnvironment(macCatalyst)
        WindowGroup("NF PDF") {
            rootContent
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            NFDesktopCommands()
        }
#else
        WindowGroup {
            rootContent
        }
#endif
    }

    /// iOS와 Mac Catalyst가 같은 로그인·포털·PDF 상태 그래프를 공유합니다.
    private var rootContent: some View {
        PortalRouteView()
            .environmentObject(portalThemeController)
            .environment(\.portalAppTheme, portalThemeController.theme)
            .preferredColorScheme(portalThemeController.theme.colorScheme)
    }
}

#if targetEnvironment(macCatalyst)
/// Mac 메뉴 막대에서 자주 쓰는 문서 기능을 키보드로 바로 실행합니다.
private struct NFDesktopCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("PDF 가져오기…") {
                NotificationCenter.default.post(name: .nfDesktopImportPDF, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandMenu("문서") {
            Button("NF PDF 문서 열기") {
                NotificationCenter.default.post(name: .nfDesktopOpenPDFLibrary, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
#endif
