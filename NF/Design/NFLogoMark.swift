//
//  NFLogoMark.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI

/**
 NoteFree 브랜드 N/F 심볼 View 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct NFLogoMark: View {
    /// 로고 포인트 색상 입니다.
    var accentColor: Color = NFColor.mint
    /// 로고 기본 획 색상 입니다.
    var foregroundColor: Color = NFColor.title

    /**
     벡터 기반 NF 심볼을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        GeometryReader { proxy in
            /// 현재 View 크기를 기준으로 Path 좌표를 비율 계산합니다.
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                /// N의 왼쪽 세로 획 입니다.
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: width * 0.08, height: height * 0.72)
                    .position(x: width * 0.20, y: height * 0.50)
                /// N의 대각선 획 입니다.
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: width * 0.08, height: height * 0.84)
                    .rotationEffect(.degrees(-30))
                    .position(x: width * 0.42, y: height * 0.50)
                /// F의 세로 획 입니다.
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: width * 0.08, height: height * 0.72)
                    .position(x: width * 0.62, y: height * 0.50)
                /// F의 상단 획 입니다.
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: width * 0.34, height: height * 0.08)
                    .position(x: width * 0.75, y: height * 0.16)
                /// F의 중앙 포인트 획 입니다.
                Capsule()
                    .fill(accentColor)
                    .frame(width: width * 0.25, height: height * 0.08)
                    .position(x: width * 0.72, y: height * 0.50)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("NoteFree")
    }
}

#Preview {
    NFLogoMark()
        .frame(width: 120, height: 120)
        .padding()
        .background(NFColor.background)
}
