//
//  AppleSignInNonce.swift
//  NF
//

import CryptoKit
import Foundation
import Security

/** Sign in with Apple 재전송 공격 방지를 위한 nonce 생성 및 SHA-256 변환 기능입니다. */
enum AppleSignInNonce {
    static func random(length: Int = 32) throws -> String {
        precondition(length > 0)
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            guard status == errSecSuccess else { throw AppleSignInNonceError.randomGenerationFailed }
            for byte in randomBytes where remaining > 0 {
                if byte < characters.count {
                    result.append(characters[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum AppleSignInNonceError: Error {
    case randomGenerationFailed
}
