//
//  AppleLoginCredential.swift
//  NF
//

import Foundation

/** 서버 검증에 전달할 Sign in with Apple 인증 정보입니다. */
struct AppleLoginCredential: Encodable {
    let identityToken: String
    let authorizationCode: String?
    let rawNonce: String
    let fullName: AppleLoginFullName?
}

/** Apple이 최초 승인 시에만 제공하는 사용자 이름입니다. */
struct AppleLoginFullName: Encodable {
    let givenName: String?
    let familyName: String?
}

/** Apple 모바일 로그인 API 응답입니다. */
struct AppleLoginTicketResponse: Decodable {
    let ticket: String
}
