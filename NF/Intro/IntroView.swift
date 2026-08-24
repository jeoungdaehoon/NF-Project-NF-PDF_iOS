//
//  IntroView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI

/**
 앱 최초 진입 시 보여주는 Intro 화면 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct IntroView: View {
    /// Intro 완료 후 다음 Route로 이동하기 위한 이벤트 입니다.
    let onFinished: () -> Void
    /// Intro 로고와 Login 카드 로고를 연결하는 SwiftUI Namespace 입니다.
    let animationNamespace: Namespace.ID?

    /**
     NoteFree 브랜드 Intro 화면을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        ZStack {
            /// Intro와 Login 전환 사이에 흰색 화면이 보이지 않도록 다크 배경을 유지합니다.
            NFColor.background.ignoresSafeArea()
            VStack(spacing: 18) {
                setLogoView()
                setBrandTitleView()
                Text("PROJECT OPERATIONS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(3.0)
                    .foregroundStyle(NFColor.muted)
            }
        }
        .task {
            /// Android와 동일하게 2초간 Intro를 노출한 뒤 다음 화면으로 이동합니다.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onFinished()
        }
    }

    /**
     Intro 중앙에 NF 로고를 표시합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: `some View`

     [Note]
     - Login 화면에도 같은 matchedGeometryEffect ID를 사용해 화면 전환 시 로고가 카드 우측 상단으로 이동합니다.
     */
    @ViewBuilder
    private func setLogoView() -> some View {
        if let animationNamespace {
            NFLogoMark()
                .frame(width: 86, height: 86)
                .matchedGeometryEffect(id: "nf-portal-login-logo", in: animationNamespace, properties: .frame, anchor: .center)
        } else {
            NFLogoMark()
                .frame(width: 86, height: 86)
        }
    }

    /**
     Intro NF Portal 브랜드 문구를 표시합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: `some View`

     [Note]
     - NF는 로그인 카드 제목의 NF 위치로 이동하고 Portal 문구는 Intro에서 함께 표시합니다.
     */
    @ViewBuilder
    private func setBrandTitleView() -> some View {
        HStack(spacing: 6) {
            if let animationNamespace {
                Text("NF")
                    .matchedGeometryEffect(id: "nf-portal-login-title", in: animationNamespace, properties: .frame, anchor: .center)
            } else {
                Text("NF")
            }
            Text("Portal")
        }
        .font(.system(size: 34, weight: .bold))
        .foregroundStyle(NFColor.title)
    }
}

#Preview {
    IntroView(onFinished: {}, animationNamespace: nil)
}
