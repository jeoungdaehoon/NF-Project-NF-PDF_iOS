//
//  LoginInfo.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation

/**
 외부 OAuth 인증 후 Portal WebView 세션 교환에 사용할 로그인 정보 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct LoginInfo: Codable, Equatable {
    /// OAuth 인증 코드 입니다.
    let code: String?
    /// OAuth state 검증 값 입니다.
    let state: String?
    /// 서버에서 직접 전달할 수 있는 인증 Token 값 입니다.
    let token: String?
    /// 모바일 WebView 세션 교환용 Ticket 값 입니다.
    let ticket: String?

    /**
     Deep Link URL Query 정보를 로그인 정보로 변환합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - url: 외부 OAuth 인증 완료 후 앱으로 돌아온 Callback URL 입니다.
     */
    init?(url: URL) {
        /// URL QueryItems를 추출합니다.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        /// OAuth 인증 코드 정보 입니다.
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        /// OAuth state 정보 입니다.
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        /// 인증 Token 정보 입니다.
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        /// 모바일 세션 교환 Ticket 정보 입니다.
        let ticket = components.queryItems?.first(where: { $0.name == "ticket" })?.value
        /// 로그인 관련 값이 하나도 없다면 유효한 인증 결과로 보지 않습니다.
        guard [code, state, token, ticket].contains(where: { ($0?.isEmpty == false) }) else {
            return nil
        }
        self.code = code
        self.state = state
        self.token = token
        self.ticket = ticket
    }

    /**
     직접 전달된 로그인 값으로 모델을 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - code: OAuth 인증 코드 입니다.
        - state: OAuth state 검증 값 입니다.
        - token: 인증 Token 값 입니다.
        - ticket: 모바일 세션 교환 Ticket 값 입니다.
     */
    init(code: String? = nil, state: String? = nil, token: String? = nil, ticket: String? = nil) {
        self.code = code
        self.state = state
        self.token = token
        self.ticket = ticket
    }

    /**
     WKWebView JavaScript 영역으로 전달할 JSON 문자열을 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `String`
     */
    func jsonPayload() -> String {
        /// JSON 직렬화 실패 시 빈 객체를 전달해 JavaScript 오류를 방지합니다.
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
