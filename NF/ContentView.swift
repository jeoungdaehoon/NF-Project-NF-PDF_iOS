//
//  ContentView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI

/**
 Xcode Preview와 기본 템플릿 호환을 위한 Root ContentView 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalRouteView``
 */
struct ContentView: View {
    /**
     NF 앱의 실제 Root Route 화면을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        PortalRouteView()
    }
}

#Preview {
    ContentView()
        .environmentObject(PortalAppThemeController())
}
