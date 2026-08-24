//
//  LoginView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import AuthenticationServices
import SwiftUI

/**
 NoteFree Google 로그인 시작 화면 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct LoginView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var loginCardBorderRotation: Double = 0

    /// OAuth 인증 정보를 서버 세션으로 교환 중인지 여부 입니다.
    let isProcessing: Bool
    /// Google 로그인 버튼 선택 이벤트 입니다.
    let onGoogleLogin: () -> Void
    /// Sign in with Apple 요청 구성 이벤트 입니다.
    let onAppleRequest: (ASAuthorizationAppleIDRequest) -> Void
    /// Sign in with Apple 인증 완료 이벤트 입니다.
    let onAppleCompletion: (Result<ASAuthorization, Error>) -> Void
    /// Intro 중앙 로고와 Login 카드 로고를 연결하는 SwiftUI Namespace 입니다.
    let animationNamespace: Namespace.ID?

    /**
     Google 계정 로그인 화면을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        GeometryReader { geometry in
            /// 큰 화면에서도 현재 로그인 카드 폭을 유지하고, 작은 화면에서는 좌우 여백만큼 축소합니다.
            let cardWidth = min(460, max(0, geometry.size.width - 48))
            ZStack {
                NFColor.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        setLogoView()
                    }
                    .padding(.bottom, 26)
                    Text("NF PROJECT OPERATIONS")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(NFColor.muted)
                        .padding(.bottom, 16)
                    HStack(spacing: 4) {
                        setNFTitleView()
                        Text("Project Portal")
                    }
                        .font(.system(size: 31, weight: .heavy))
                        .foregroundStyle(NFColor.title)
                        .padding(.bottom, 22)
                    Text("Apple, Gmail 또는 Google Workspace 계정으로 가입할 수 있습니다. 계정별 데이터는 분리되며 상호 동의한 회원만 서로의 프로젝트를 볼 수 있습니다.")
                        .font(.system(size: 14, weight: .semibold))
                        .lineSpacing(6)
                        .foregroundStyle(NFColor.body)
                        .padding(.bottom, 38)
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: onAppleRequest,
                        onCompletion: onAppleCompletion
                    )
                    .signInWithAppleButtonStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .disabled(isProcessing)
                    .padding(.bottom, 12)
                    Button(action: onGoogleLogin) {
                        HStack {
                            if isProcessing {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isProcessing ? "로그인 정보 확인 중…" : "Google 계정으로 로그인")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(NFColor.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isProcessing)
                }
                .padding(28)
                .frame(width: cardWidth)
                .background(NFColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(NFColor.border, lineWidth: 1)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    NFColor.blue.opacity(0.2),
                                    NFColor.blue,
                                    .white,
                                    NFColor.blue,
                                    NFColor.blue.opacity(0.2),
                                ],
                                center: .center,
                                angle: .degrees(loginCardBorderRotation)
                            ),
                            lineWidth: 2
                        )
                        .padding(1)
                        .allowsHitTesting(false)
                }
                .onAppear {
                    updateLoginCardBorderAnimation(isProcessing: isProcessing)
                }
                .onChange(of: isProcessing) { _, processing in
                    updateLoginCardBorderAnimation(isProcessing: processing)
                }
                .onChange(of: accessibilityReduceMotion) { _, _ in
                    updateLoginCardBorderAnimation(isProcessing: isProcessing)
                }
                .shadow(color: .black.opacity(0.32), radius: 30, x: 0, y: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                Text(AppVersion.displayText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NFColor.muted)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                    .accessibilityLabel("앱 버전 \(AppVersion.number)")
            }
        }
    }

    private func updateLoginCardBorderAnimation(isProcessing: Bool) {
        guard isProcessing, !accessibilityReduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loginCardBorderRotation = 0
            }
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loginCardBorderRotation = 0
        }
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            loginCardBorderRotation = 360
        }
    }

    /**
     Login 카드 우측 상단에 NF 로고를 표시합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: `some View`

     [Note]
     - Intro의 중앙 로고와 같은 matchedGeometryEffect ID를 사용해 로고 이동·축소 애니메이션을 구성합니다.
     */
    @ViewBuilder
    private func setLogoView() -> some View {
        if let animationNamespace {
            NFLogoMark()
                .frame(width: 46, height: 46)
                .matchedGeometryEffect(id: "nf-portal-login-logo", in: animationNamespace, properties: .frame, anchor: .center)
        } else {
            NFLogoMark()
                .frame(width: 46, height: 46)
        }
    }

    /**
     Login 카드 제목의 NF 브랜드 문구를 표시합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: `some View`

     [Note]
     - Intro의 NF 문구와 같은 matchedGeometryEffect ID를 사용해 Intro 중앙에서 카드 제목 위치로 이동합니다.
     */
    @ViewBuilder
    private func setNFTitleView() -> some View {
        if let animationNamespace {
            Text("NF")
                .matchedGeometryEffect(id: "nf-portal-login-title", in: animationNamespace, properties: .frame, anchor: .center)
        } else {
            Text("NF")
        }
    }
}

#Preview {
    LoginView(
        isProcessing: false,
        onGoogleLogin: {},
        onAppleRequest: { _ in },
        onAppleCompletion: { _ in },
        animationNamespace: nil
    )
}
