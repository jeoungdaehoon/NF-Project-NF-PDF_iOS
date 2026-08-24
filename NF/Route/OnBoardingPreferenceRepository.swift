//
//  OnBoardingPreferenceRepository.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 OnBoardingView 최초 노출 여부를 저장/조회하는 Repository 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
final class OnBoardingPreferenceRepository {
    /// UserDefaults 저장소 입니다.
    private let userDefaults: UserDefaults

    /**
     Repository를 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - userDefaults: 권한 안내 확인 여부를 저장할 UserDefaults 입니다.
     */
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /**
     권한 안내 화면을 이미 확인했는지 조회합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `Bool`
     */
    func hasCompletedOnBoarding() -> Bool {
        return userDefaults.bool(forKey: Self.completedKey)
    }

    /**
     권한 안내 화면 확인 완료 상태를 저장합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func markOnBoardingCompleted() {
        userDefaults.set(true, forKey: Self.completedKey)
    }

    /// 권한 안내 완료 여부 저장 Key 입니다.
    private static let completedKey = "nf.portal.onboarding.completed"
}
