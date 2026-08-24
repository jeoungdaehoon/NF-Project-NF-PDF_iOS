//
//  PortalOAuthSessionCoordinator.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import AuthenticationServices
import UIKit
import Combine

/**
 Google OAuth 외부 인증을 ASWebAuthenticationSession으로 처리하는 Coordinator 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``LoginInfo``
 */
@MainActor
final class PortalOAuthSessionCoordinator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    /// 현재 진행 중인 외부 인증 세션 입니다.
    private var session: ASWebAuthenticationSession?

    /**
     Google OAuth 외부 인증을 시작합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: Portal Login URL 입니다.
        - completion: 인증 완료 또는 실패 결과 Callback 입니다.
     */
    func start(url: URL, completion: @escaping (Result<LoginInfo, Error>) -> Void) {
        /// 기존 인증 세션이 남아 있다면 취소 후 새 세션을 시작합니다.
        session?.cancel()
        /// ASWebAuthenticationSession은 Safari/Google 세션을 사용하면서 앱 Callback URL을 안전하게 돌려받습니다.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: PortalConfig.oauthCallbackScheme) { callbackURL, error in
            Task { @MainActor in
                /// 시스템 인증 오류 또는 사용자 취소를 처리합니다.
                if let error {
                    completion(.failure(error))
                    return
                }
                /// Callback URL을 LoginInfo로 변환합니다.
                guard let callbackURL, let loginInfo = LoginInfo(url: callbackURL) else {
                    completion(.failure(PortalOAuthSessionError.invalidCallback))
                    return
                }
                completion(.success(loginInfo))
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        /// 인증 세션 시작에 실패하면 즉시 실패 Callback을 전달합니다.
        if !session.start() {
            completion(.failure(PortalOAuthSessionError.failedToStart))
        }
    }

    /**
     ASWebAuthenticationSession이 표시될 Anchor Window를 제공합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - session: 외부 인증 세션 객체 입니다.
     - Returns: `ASPresentationAnchor`
     */
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        /// 현재 활성 WindowScene의 Key Window를 우선 사용합니다.
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

/**
 OAuth 세션 처리 중 발생할 수 있는 오류 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum PortalOAuthSessionError: Error {
    /// 인증 Callback URL이 로그인 정보로 변환되지 않는 경우 입니다.
    case invalidCallback
    /// ASWebAuthenticationSession 시작에 실패한 경우 입니다.
    case failedToStart
}
