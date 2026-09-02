//
//  AppVersion.swift
//  NF
//
//  Created by Codex on 8/2/26.
//

import Foundation

/**
 설치된 NF 앱의 버전 정보를 화면과 WebView에서 공통으로 사용합니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.08.02
 */
enum AppVersion {
    /// Info.plist의 사용자 표시용 앱 버전입니다.
    static let number: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "알 수 없음"
    }()

    /// Info.plist의 내부 빌드 번호입니다. Xcode의 `CURRENT_PROJECT_VERSION` 값을 자동으로 표시합니다.
    static let buildNumber: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "알 수 없음"
    }()

    /// 앱 화면에 표시할 버전·빌드 문구입니다.
    static var displayText: String {
        "v\(number) Build \(buildNumber)"
    }

    /// Portal 설정 화면이 현재 실행 플랫폼과 앱 버전을 식별할 수 있도록 UserAgent에 추가하는 값입니다.
    static var userAgentSuffix: String {
        let normalizedNumber = number.replacingOccurrences(of: " ", with: "-")
#if targetEnvironment(macCatalyst)
        /// Mac Catalyst는 넓은 데스크톱 WebView를 사용하므로 포털이 iOS 축소 레이아웃을 적용하지 않게 구분합니다.
        return "NFPortalMac/\(normalizedNumber)"
#else
        return "NFPortaliOS/\(normalizedNumber)"
#endif
    }
}

private extension String {
    /// 빈 문자열을 `nil`로 정규화합니다.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
