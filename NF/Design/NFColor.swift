//
//  NFColor.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI

/**
 NF iOS 앱에서 공통으로 사용하는 색상 팔레트 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum NFColor {
    /// 앱 기본 다크 배경색 입니다.
    static let background = Color(red: 23.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0)
    /// 카드 배경색 입니다.
    static let card = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 33.0 / 255.0)
    /// 카드 테두리 색상 입니다.
    static let border = Color(red: 51.0 / 255.0, green: 51.0 / 255.0, blue: 55.0 / 255.0)
    /// 메인 텍스트 색상 입니다.
    static let title = Color(red: 0.930, green: 0.930, blue: 0.930)
    /// 설명 텍스트 색상 입니다.
    static let body = Color(red: 0.720, green: 0.720, blue: 0.720)
    /// 보조 텍스트 색상 입니다.
    static let muted = Color(red: 171.0 / 255.0, green: 171.0 / 255.0, blue: 178.0 / 255.0)
    /// NF Portal CTA 블루 색상 입니다.
    static let blue = Color(red: 0.185, green: 0.502, blue: 0.929)
    /// NoteFree 포인트 민트 색상 입니다.
    static let mint = Color(red: 0.231, green: 0.965, blue: 0.722)
}
