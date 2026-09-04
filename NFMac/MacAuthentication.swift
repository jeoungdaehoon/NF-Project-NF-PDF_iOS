import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import WebKit

struct MacLoginInfo: Codable, Equatable {
    let code: String?
    let state: String?
    let token: String?
    let ticket: String?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        code = components.queryItems?.first { $0.name == "code" }?.value
        state = components.queryItems?.first { $0.name == "state" }?.value
        token = components.queryItems?.first { $0.name == "token" }?.value
        ticket = components.queryItems?.first { $0.name == "ticket" }?.value
        guard [code, state, token, ticket].contains(where: { $0?.isEmpty == false }) else { return nil }
    }

    init(ticket: String) {
        code = nil
        state = nil
        token = nil
        self.ticket = ticket
    }
}

struct MacAppleLoginCredential: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let rawNonce: String
    let fullName: MacAppleLoginFullName?
}

struct MacAppleLoginFullName: Encodable {
    let givenName: String?
    let familyName: String?
}

private struct MacAppleTicketResponse: Decodable { let ticket: String }

@MainActor
final class MacAuthenticationModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var isProcessing = false
    @Published var message: String?

    private var session: ASWebAuthenticationSession?
    private let defaults = UserDefaults.standard
    private static let sessionKey = "nf.mac.portal.session.available.v1"

    override init() {
        isAuthenticated = UserDefaults.standard.bool(forKey: Self.sessionKey)
        super.init()
    }

    func startGoogleLogin() {
        guard !isProcessing else { return }
        isProcessing = true
        message = nil
        session?.cancel()
        let session = ASWebAuthenticationSession(
            url: MacPortalConfig.googleLoginURL,
            callbackURLScheme: MacPortalConfig.callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.isProcessing = false
                    return
                }
                guard error == nil, let callbackURL, let loginInfo = MacLoginInfo(url: callbackURL) else {
                    self.isProcessing = false
                    self.message = "Google 로그인을 완료하지 못했습니다. 다시 시도해 주세요."
                    return
                }
                await self.exchange(loginInfo)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            isProcessing = false
            message = "로그인 창을 열지 못했습니다."
        }
    }

    func handle(url: URL) {
        guard let info = MacLoginInfo(url: url) else { return }
        Task { await exchange(info) }
    }

    func beginAppleRequest(_ request: ASAuthorizationAppleIDRequest, rawNonce: inout String?) {
        let nonce = Self.randomNonce()
        rawNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeAppleLogin(_ result: Result<ASAuthorization, Error>, rawNonce: String?) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let rawNonce,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code != .canceled {
                message = "Apple 로그인을 완료하지 못했습니다."
            }
            return
        }
        isProcessing = true
        let body = MacAppleLoginCredential(
            identityToken: identityToken,
            authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            rawNonce: rawNonce,
            fullName: MacAppleLoginFullName(
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName
            )
        )
        Task {
            do {
                var request = URLRequest(url: MacPortalConfig.appleLoginURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let ticket = try? JSONDecoder().decode(MacAppleTicketResponse.self, from: data) else {
                    throw URLError(.badServerResponse)
                }
                await exchange(MacLoginInfo(ticket: ticket.ticket))
            } catch {
                isProcessing = false
                message = "Apple 로그인 정보를 포털에 연결하지 못했습니다."
            }
        }
    }

    func logout() {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) { }
        defaults.removeObject(forKey: Self.sessionKey)
        isAuthenticated = false
    }

    func requireLogin() {
        session?.cancel()
        isProcessing = false
        defaults.removeObject(forKey: Self.sessionKey)
        isAuthenticated = false
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    private func exchange(_ loginInfo: MacLoginInfo) async {
        do {
            var request = URLRequest(url: MacPortalConfig.exchangeURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(loginInfo)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                guard let key = item.key as? String else { return }
                result[key] = "\(item.value)"
            }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: MacPortalConfig.dashboardURL)
            for cookie in cookies {
                await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = object["cookies"] as? [[String: Any]] {
                for item in items {
                    guard let name = item["name"] as? String, let value = item["value"] as? String else { continue }
                    let properties: [HTTPCookiePropertyKey: Any] = [
                        .name: name,
                        .value: value,
                        .domain: item["domain"] as? String ?? MacPortalConfig.host,
                        .path: item["path"] as? String ?? "/",
                        .secure: "TRUE"
                    ]
                    if let cookie = HTTPCookie(properties: properties) {
                        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
                    }
                }
            }
            defaults.set(true, forKey: Self.sessionKey)
            isProcessing = false
            isAuthenticated = true
        } catch {
            isProcessing = false
            message = "포털 로그인 세션을 생성하지 못했습니다. 다시 로그인해 주세요."
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { return UUID().uuidString }
            for byte in bytes where result.count < length && byte < characters.count {
                result.append(characters[Int(byte)])
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
