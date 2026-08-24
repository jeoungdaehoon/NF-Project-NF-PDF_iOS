//
//  AuthSessionRepository.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import Foundation
import WebKit

/**
 외부 OAuth 로그인 정보를 Portal WKWebView 세션으로 교환하는 Repository 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 - SeeAlso: ``LoginInfo``, ``AuthSessionResult``
 */
@MainActor
final class AuthSessionRepository {
    /** Sign in with Apple 결과를 서버에서 검증하고 기존 모바일 로그인 ticket으로 변환합니다. */
    func createAppleLoginInfo(_ credential: AppleLoginCredential) async throws -> LoginInfo {
        var request = URLRequest(url: PortalConfig.portalAppleLoginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(credential)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let result = try? JSONDecoder().decode(AppleLoginTicketResponse.self, from: data),
              !result.ticket.isEmpty else {
            throw AuthSessionRepositoryError.invalidResponse
        }
        return LoginInfo(ticket: result.ticket)
    }

    /**
     OAuth 로그인 정보를 서버 세션으로 교환합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - loginInfo: 외부 OAuth 인증 후 앱으로 전달된 로그인 정보 입니다.
     - Returns: ``AuthSessionResult``
     */
    func exchangeLoginInfo(_ loginInfo: LoginInfo) async throws -> AuthSessionResult {
        /// 서버 API 호출 Request를 생성합니다.
        var request = URLRequest(url: PortalConfig.portalAuthSessionExchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(loginInfo)
        /// 서버에서 세션 Cookie와 Redirect URL 정보를 수신합니다.
        let (data, response) = try await URLSession.shared.data(for: request)
        /// HTTP 응답 여부와 성공 StatusCode를 검증합니다.
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AuthSessionRepositoryError.invalidResponse
        }
        /// 응답 Body 문자열을 생성합니다.
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        /// 서버 응답 Header와 Body에서 Cookie를 추출해 WKWebView CookieStore에 저장합니다.
        let cookieCount = await setResponseCookies(headerFields: httpResponse.allHeaderFields, responseBody: responseBody)
        /// 서버 응답에서 WKWebView가 열 URL을 추출하고 운영 도메인 기준으로 보정합니다.
        let redirectURL = PortalConfig.normalizePortalURL(parseRedirectURL(responseBody))
        return AuthSessionResult(redirectURL: redirectURL, cookieCount: cookieCount)
    }

    /**
     WKWebView에 저장된 Portal 인증 세션을 정리합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     */
    func clearWebViewSession() async {
        /// WKWebView 기본 DataStore에서 모든 WebSite 데이터를 제거합니다.
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: date) {
                continuation.resume()
            }
        }
    }

    /**
     서버 응답 Cookie를 WKWebView CookieStore에 저장합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - headerFields: HTTP 응답 Header 정보 입니다.
        - responseBody: HTTP 응답 Body 문자열 입니다.
     - Returns: `Int`
     */
    private func setResponseCookies(headerFields: [AnyHashable: Any], responseBody: String) async -> Int {
        /// Header Dictionary를 HTTPCookie 파서가 이해할 수 있는 타입으로 변환합니다.
        let stringHeaderFields = headerFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else {
                return
            }
            result[key] = "\(item.value)"
        }
        /// Set-Cookie Header에서 Cookie 목록을 추출합니다.
        let headerCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaderFields, for: PortalConfig.portalDashboardURL)
        /// JSON Body에 cookies 배열이 포함된 경우를 고려해 추가 Cookie를 추출합니다.
        let bodyCookies = parseBodyCookies(responseBody)
        /// 중복 Cookie를 줄이기 위해 name/domain/path 기준으로 정리합니다.
        let cookies = Dictionary(grouping: headerCookies + bodyCookies) { cookie in
            "\(cookie.name)|\(cookie.domain)|\(cookie.path)"
        }.compactMap { $0.value.last }
        /// WKWebView CookieStore에 순차 저장합니다.
        for cookie in cookies {
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        }
        return cookies.count
    }

    /**
     서버 응답 Body에서 Redirect URL을 추출합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - responseBody: HTTP 응답 Body 문자열 입니다.
     - Returns: `URL?`
     */
    private func parseRedirectURL(_ responseBody: String) -> URL? {
        /// JSON 응답이 아닌 경우 기본 Dashboard URL을 사용합니다.
        guard let data = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        /// 서버가 사용할 수 있는 Redirect Key를 순서대로 확인합니다.
        let redirectText = ["redirectUrl", "dashboardUrl", "url"]
            .compactMap { json[$0] as? String }
            .first { !$0.isEmpty }
        /// 상대 경로가 내려온 경우 Portal Origin을 붙여 URL을 구성합니다.
        if let redirectText, redirectText.hasPrefix("/") {
            return URL(string: PortalConfig.portalOrigin + redirectText)
        }
        return redirectText.flatMap(URL.init(string:))
    }

    /**
     서버 응답 Body에서 Cookie 배열을 추출합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - responseBody: HTTP 응답 Body 문자열 입니다.
     - Returns: `[HTTPCookie]`
     */
    private func parseBodyCookies(_ responseBody: String) -> [HTTPCookie] {
        /// JSON 응답이 아닌 경우 Body Cookie는 없는 것으로 처리합니다.
        guard let data = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cookieItems = json["cookies"] as? [[String: Any]] else {
            return []
        }
        /// 서버 Cookie 속성을 HTTPCookiePropertyKey Dictionary로 변환합니다.
        return cookieItems.compactMap { item in
            guard let name = item["name"] as? String,
                  let value = item["value"] as? String else {
                return nil
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: item["domain"] as? String ?? PortalConfig.portalHost,
                .path: item["path"] as? String ?? "/"
            ]
            /// 운영 HTTPS Auth.js 세션 쿠키가 유효하게 저장되도록 Secure 속성을 유지합니다.
            if item.boolValue(for: "secure", defaultValue: true) {
                properties[.secure] = "TRUE"
            }
            /// 서버가 Max-Age를 내려주는 경우 iOS CookieStore가 유지 시간을 알 수 있도록 Expires로 변환합니다.
            if let maxAge = item.timeIntervalValue(for: "maxAge") {
                properties[.expires] = Date(timeIntervalSinceNow: maxAge)
            }
            /// 만료 시간이 있는 경우 Cookie 속성에 추가합니다.
            if let expires = item.timeIntervalValue(for: "expires") {
                properties[.expires] = Date(timeIntervalSince1970: expires)
            }
            return HTTPCookie(properties: properties)
        }
    }
}

// MARK: - JSON Cookie Value Helper 입니다.
private extension Dictionary where Key == String, Value == Any {
    /**
     JSON Cookie 객체에서 Boolean 값을 안전하게 추출합니다. ( J.D.H )
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - key: 확인할 JSON Key 입니다.
        - defaultValue: 값이 없거나 변환할 수 없을 때 사용할 기본 값 입니다.
     - Returns: `Bool`
     */
    func boolValue(for key: String, defaultValue: Bool) -> Bool {
        /// Bool 타입 값은 그대로 반환합니다.
        if let value = self[key] as? Bool {
            return value
        }
        /// 문자열로 내려온 true/false 값도 서버 환경 차이를 고려해 변환합니다.
        if let value = self[key] as? String {
            return NSString(string: value).boolValue
        }
        /// 숫자로 내려온 1/0 값도 안전하게 Boolean으로 변환합니다.
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return defaultValue
    }

    /**
     JSON Cookie 객체에서 시간 값을 안전하게 추출합니다. ( J.D.H )
     - Version: 1.0.0
     - Date: 2026.07.29
     - Parameters:
        - key: 확인할 JSON Key 입니다.
     - Returns: `TimeInterval?`
     */
    func timeIntervalValue(for key: String) -> TimeInterval? {
        /// 숫자 타입 시간 값은 TimeInterval로 변환합니다.
        if let value = self[key] as? TimeInterval {
            return value
        }
        /// 문자열 숫자로 내려오는 경우도 고려해 TimeInterval로 변환합니다.
        if let value = self[key] as? String {
            return TimeInterval(value)
        }
        /// NSNumber 타입으로 내려온 경우 Double 값으로 변환합니다.
        if let value = self[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }
}

/**
 Portal 인증 세션 교환 중 발생할 수 있는 오류입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
enum AuthSessionRepositoryError: Error {
    /// 서버 응답이 HTTP 성공 응답이 아닌 경우 입니다.
    case invalidResponse
}
