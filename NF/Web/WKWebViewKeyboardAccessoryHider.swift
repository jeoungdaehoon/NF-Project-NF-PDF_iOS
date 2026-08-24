//
//  WKWebViewKeyboardAccessoryHider.swift
//  NF
//
//  Created by hanwha on 7/30/26.
//

import UIKit
import WebKit

/**
 WKWebView 입력창 상단에 표시되는 iOS 기본 키보드 어시스트 바를 숨기는 확장 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalWebView``
 */
extension WKWebView {
    /**
     WebView 내부 입력 대상의 키보드 어시스트 바 버튼 그룹을 제거합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     */
    func hideKeyboardAssistantBar() {
        /// WKWebView 자체와 ScrollView 하위 입력 View에 모두 적용합니다.
        removeKeyboardAssistantBar(from: self)
        removeKeyboardAssistantBar(from: scrollView)
    }

    /**
     View 계층을 순회하며 iOS 기본 키보드 어시스트 바 버튼 그룹을 제거합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - view: 어시스트 바를 제거할 기준 View 입니다.
     */
    private func removeKeyboardAssistantBar(from view: UIView) {
        /// iOS가 자동 제공하는 좌/우 어시스트 버튼 그룹을 비워 키보드 위 기본 바가 보이지 않게 합니다.
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        /// WKContentView 등 WebKit 내부 입력 View가 나중에 생성될 수 있어 하위 View까지 반복 적용합니다.
        view.subviews.forEach { childView in
            removeKeyboardAssistantBar(from: childView)
        }
    }
}
