//
//  PortalRouteViewModel.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation
import Combine

/**
 Portal 상위 Route 화면의 UI 기능과 데이터 처리를 담당하는 ViewModel 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``PortalRouteState``, ``PortalRouteView``
 */
@MainActor
final class PortalRouteViewModel: ObservableObject {
    /// Route 화면에서 표시할 전체 상태 정보 입니다.
    @Published private(set) var state: PortalRouteState
    /// OAuth 인증 결과를 WKWebView 세션으로 교환하는 Repository 입니다.
    private let authSessionRepository: AuthSessionRepository
    /// OnBoardingView 최초 노출 여부를 관리하는 Repository 입니다.
    private let onBoardingPreferenceRepository: OnBoardingPreferenceRepository
    /// Portal 웹 설정에서 변경한 자동 로그인 값을 저장하는 Repository 입니다.
    private let autoLoginPreferenceRepository: AutoLoginPreferenceRepository
    /// 계정 탈퇴 시 저장된 PDF와 편집 메타데이터를 삭제하는 Repository 입니다.
    private let pdfLocalStorageRepository: PortalPDFLocalStorageRepository

    /**
     ViewModel을 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - state: 최초 Route State 입니다.
        - authSessionRepository: 인증 세션 교환 Repository 입니다.
        - onBoardingPreferenceRepository: OnBoarding 최초 노출 Repository 입니다.
     */
    init(
        state: PortalRouteState? = nil,
        authSessionRepository: AuthSessionRepository? = nil,
        onBoardingPreferenceRepository: OnBoardingPreferenceRepository? = nil,
        autoLoginPreferenceRepository: AutoLoginPreferenceRepository? = nil,
        pdfLocalStorageRepository: PortalPDFLocalStorageRepository? = nil
    ) {
        // 기본 인스턴스는 @MainActor init 본문에서 생성해 Swift 6 격리 규칙을 지킵니다.
        let resolvedOnBoardingRepository = onBoardingPreferenceRepository
            ?? OnBoardingPreferenceRepository()
        let resolvedAutoLoginRepository = autoLoginPreferenceRepository
            ?? AutoLoginPreferenceRepository()
        let resolvedPDFStorageRepository = pdfLocalStorageRepository
            ?? PortalPDFLocalStorageRepository()
        var initialState = state ?? PortalRouteState()
        /// UserDefaults에 저장된 자동 로그인 값을 앱 State의 최초 값으로 연결합니다.
        initialState.isAutoLoginEnabled = resolvedAutoLoginRepository.isAutoLoginEnabled()
        /// UserDefaults에 저장된 PDF 파일 로컬 저장 값을 앱 State의 최초 값으로 연결합니다.
        initialState.isPDFLocalStorageEnabled = resolvedAutoLoginRepository.isPDFLocalStorageEnabled()
        self.state = initialState
        self.authSessionRepository = authSessionRepository ?? AuthSessionRepository()
        self.onBoardingPreferenceRepository = resolvedOnBoardingRepository
        self.autoLoginPreferenceRepository = resolvedAutoLoginRepository
        self.pdfLocalStorageRepository = resolvedPDFStorageRepository
    }

    /**
     Intro 완료 후 다음 화면으로 이동합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func onIntroFinished() {
        /// OnBoarding은 최초 실행 1회만 노출합니다.
        updateState { currentState in
            guard onBoardingPreferenceRepository.hasCompletedOnBoarding() else {
                currentState.destination = .onBoarding
                return
            }
            /// 자동 로그인 설정과 저장된 Portal 세션이 모두 있으면 Login 화면을 건너뜁니다.
            currentState.destination = autoLoginPreferenceRepository.isAutoLoginEnabled()
                && autoLoginPreferenceRepository.hasStoredPortalSession()
                ? .webView
                : .login
        }
    }

    /**
     Portal 웹 설정에서 전달된 자동 로그인 값을 저장하고 State를 갱신합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Parameters:
        - enabled: 웹 설정에서 선택한 자동 로그인 사용 여부 입니다.

     [Note]
     - WebView가 보내는 값은 네이티브 UserDefaults에 저장해 다음 앱 시작 시 사용합니다.
     - Google 토큰은 저장하지 않고 WKWebView 보안 세션 쿠키만 유지합니다.
     */
    func onAutoLoginChanged(_ enabled: Bool) {
        autoLoginPreferenceRepository.setAutoLoginEnabled(enabled)
        updateState { currentState in
            currentState.isAutoLoginEnabled = enabled
        }
    }

    /**
     Portal 웹 설정에서 전달된 PDF 파일 로컬 저장 값을 저장하고 State를 갱신합니다.
     - Version: 1.0.0
     - Date: 2026.08.08
     - Parameters:
        - enabled: PDF 선택 시 로컬 저장을 사용할지 여부 입니다.
     */
    func onPDFLocalStorageChanged(_ enabled: Bool) {
        autoLoginPreferenceRepository.setPDFLocalStorageEnabled(enabled)
        updateState { currentState in
            currentState.isPDFLocalStorageEnabled = enabled
        }
    }

    /**
     OnBoarding 확인 완료 후 Login 화면으로 이동합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func onStartLogin() {
        /// 권한 안내 확인 완료를 저장해 다음 앱 실행부터 OnBoarding을 건너뜁니다.
        onBoardingPreferenceRepository.markOnBoardingCompleted()
        updateState { currentState in
            currentState.destination = .login
        }
    }

    /**
     외부 OAuth 인증 결과를 Portal WKWebView 세션으로 교환합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - loginInfo: 외부 인증 완료 후 앱으로 전달된 로그인 정보 입니다.
     */
    func onLoginInfoReceived(_ loginInfo: LoginInfo) {
        /// 동일 OAuth Callback이 인증 세션과 앱 Deep Link 양쪽에서 전달돼도 일회용 Ticket을 중복 교환하지 않습니다.
        if state.loginInfo == loginInfo,
           state.authExchangeStatus == .exchanging || state.authExchangeStatus == .authenticated {
            return
        }
        /// 로그인 정보 교환 진행 상태로 전환합니다.
        updateState { currentState in
            currentState.destination = .login
            currentState.loginInfo = loginInfo
            currentState.authExchangeStatus = .exchanging
            currentState.authExchangeMessage = nil
        }
        /// 서버 세션 교환은 비동기로 진행합니다.
        Task {
            do {
                let result = try await authSessionRepository.exchangeLoginInfo(loginInfo)
                /// 서버에서 받은 Cookie가 WKWebView에 세팅된 뒤 Portal 화면으로 이동합니다.
                updateState { currentState in
                    currentState.destination = .webView
                    currentState.loginInfo = loginInfo
                    currentState.portalDashboardURL = PortalConfig.normalizePortalURL(result.redirectURL)
                    currentState.authExchangeStatus = .authenticated
                    /// 로그인 성공 세션이 생성되었음을 저장해 자동 로그인 진입 기준으로 사용합니다.
                    autoLoginPreferenceRepository.markPortalSessionAvailable()
                    /// 로그인 성공 시에는 별도 안내 팝업 없이 즉시 NF Portal 메인 화면을 표시합니다.
                    currentState.authExchangeMessage = nil
                }
            } catch {
                /// 인증 교환 실패 시 Login 화면에 머물도록 처리합니다.
                updateState { currentState in
                    currentState.destination = .login
                    currentState.loginInfo = loginInfo
                    currentState.authExchangeStatus = .failed
                    currentState.authExchangeMessage = "포털 진입 로그인 정보를 확인하지 못했습니다. 다시 로그인해 주세요."
                }
            }
        }
    }

    /** Sign in with Apple 결과를 서버 검증 후 기존 Portal 세션 교환 흐름으로 연결합니다. */
    func onAppleCredentialReceived(_ credential: AppleLoginCredential) {
        guard state.authExchangeStatus != .exchanging else { return }
        updateState { currentState in
            currentState.destination = .login
            currentState.authExchangeStatus = .exchanging
            currentState.authExchangeMessage = nil
        }
        Task {
            do {
                let loginInfo = try await authSessionRepository.createAppleLoginInfo(credential)
                onLoginInfoReceived(loginInfo)
            } catch {
                updateState { currentState in
                    currentState.destination = .login
                    currentState.authExchangeStatus = .failed
                    currentState.authExchangeMessage = "Apple 로그인 정보를 확인하지 못했습니다. 다시 로그인해 주세요."
                }
            }
        }
    }

    /**
     Portal WebView 내부 로그아웃을 처리하고 Login 화면으로 이동합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func onPortalLogout() {
        /// WebView Cookie와 LocalStorage를 정리해 로그아웃 후 세션이 복원되지 않게 합니다.
        Task {
            await authSessionRepository.clearWebViewSession()
            /// 로그아웃 시 자동 로그인에 사용할 세션 존재 상태도 함께 삭제합니다.
            autoLoginPreferenceRepository.clearPortalSession()
            updateState { currentState in
                currentState.destination = .login
                currentState.loginInfo = nil
                currentState.portalDashboardURL = PortalConfig.portalDashboardURL
                currentState.authExchangeStatus = .idle
                currentState.authExchangeMessage = nil
                currentState.isAutoLoginEnabled = autoLoginPreferenceRepository.isAutoLoginEnabled()
                currentState.isPDFLocalStorageEnabled = autoLoginPreferenceRepository.isPDFLocalStorageEnabled()
            }
        }
    }

    /** 서버가 삭제·중지·누락 계정으로 판정한 경우 남아 있는 WebView 인증 정보를 폐기합니다. */
    func onPortalAccountAccessIssue() {
        Task {
            await authSessionRepository.clearWebViewSession()
            autoLoginPreferenceRepository.clearPortalSession()
            updateState { currentState in
                currentState.destination = .login
                currentState.loginInfo = nil
                currentState.portalDashboardURL = PortalConfig.portalDashboardURL
                currentState.authExchangeStatus = .idle
                currentState.authExchangeMessage = "저장된 로그인 계정을 사용할 수 없어 기존 로그인 정보를 정리했습니다. 다시 로그인해 주세요."
                currentState.isAutoLoginEnabled = autoLoginPreferenceRepository.isAutoLoginEnabled()
                currentState.isPDFLocalStorageEnabled = autoLoginPreferenceRepository.isPDFLocalStorageEnabled()
            }
        }
    }

    /** 웹에서 계정 삭제가 완료된 뒤 앱 로컬 정보와 인증 세션을 삭제하고 로그인 화면으로 이동합니다. */
    func onAccountDeleted() {
        Task {
            await authSessionRepository.clearWebViewSession()
            try? pdfLocalStorageRepository.removeAllLocalData()
            autoLoginPreferenceRepository.clearAccountPreferences()
            updateState { currentState in
                currentState.destination = .login
                currentState.loginInfo = nil
                currentState.portalDashboardURL = PortalConfig.portalDashboardURL
                currentState.authExchangeStatus = .idle
                currentState.authExchangeMessage = nil
                currentState.isAutoLoginEnabled = false
                currentState.isPDFLocalStorageEnabled = false
            }
        }
    }

    /**
     Portal 메인 화면 최초 진입 중 네트워크 오류 또는 제한시간 초과를 처리합니다.
     - Version: 1.0.0
     - Date: 2026.08.05
     */
    func onPortalNetworkUnavailable() {
        /// 네트워크 오류 뒤 자동 재진입하지 않도록 기존 WebView 인증 상태를 정리합니다.
        Task {
            await authSessionRepository.clearWebViewSession()
            autoLoginPreferenceRepository.clearPortalSession()
            updateState { currentState in
                currentState.destination = .login
                currentState.loginInfo = nil
                currentState.portalDashboardURL = PortalConfig.portalDashboardURL
                currentState.authExchangeStatus = .idle
                currentState.authExchangeMessage = "네트워크 연결이 원활하지 않아 메인 화면을 열지 못했습니다. 네트워크를 확인한 뒤 로그인부터 다시 진행해 주세요."
                currentState.isAutoLoginEnabled = autoLoginPreferenceRepository.isAutoLoginEnabled()
                currentState.isPDFLocalStorageEnabled = autoLoginPreferenceRepository.isPDFLocalStorageEnabled()
            }
        }
    }

    /**
     일회성 안내 메시지를 소비 처리합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func onRouteMessageConsumed() {
        updateState { currentState in
            currentState.authExchangeMessage = nil
        }
    }

    /**
     Route State를 갱신합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - transform: 변경할 State 처리 블록 입니다.
     */
    private func updateState(_ transform: (inout PortalRouteState) -> Void) {
        var nextState = state
        transform(&nextState)
        state = nextState
    }
}
