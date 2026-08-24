//
//  OnBoardingView.swift
//  NF
//
//  Created by hanwha on 7/29/26.
//

import SwiftUI

/**
 NoteFree 권한 안내 화면 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
struct OnBoardingView: View {
    /// 권한 안내 확인 후 LoginView로 이동하기 위한 이벤트 입니다.
    let onStartLogin: () -> Void
    /// 화면에 표시할 권한 안내 데이터 입니다.
    private let permissionItems = PermissionGuideItem.items

    /**
     최초 1회 권한 안내 화면을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        ZStack(alignment: .bottom) {
            /// NF 스타일 다크 배경을 전체 화면에 적용합니다.
            NFColor.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    setBrandView()
                        .padding(.top, 34)
                    Text("안전한 앱 사용을 위해\n아래의 권한 허용이 필요해요")
                        .font(.system(size: 30, weight: .heavy))
                        .lineSpacing(6)
                        .foregroundStyle(NFColor.title)
                        .padding(.top, 56)
                    VStack(spacing: 20) {
                        ForEach(permissionItems) { item in
                            PermissionGuideRow(item: item)
                        }
                    }
                    .padding(.top, 44)
                    setNoticeView()
                        .padding(.top, 40)
                        .padding(.bottom, 124)
                }
                .padding(.horizontal, 28)
            }
            setConfirmButton()
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
        }
    }
}

// MARK: - 권한 안내 관련 지원 유닛 ViewBuilder 입니다.
extension OnBoardingView {
    /**
     NoteFree 브랜드 영역 입니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    @ViewBuilder
    func setBrandView() -> some View {
        HStack(spacing: 12) {
            NFLogoMark()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("NoteFree")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(NFColor.title)
                Text("PROJECT OPERATIONS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(NFColor.muted)
            }
        }
    }

    /**
     권한 안내 하단 주의 문구 영역 입니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    @ViewBuilder
    func setNoticeView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionNoticeText(text: "접근 권한을 허용하지 않으면 일부 서비스 이용에 제한이 있을 수 있습니다.")
            PermissionNoticeText(text: "파일 추가를 선택하면 iOS 파일 선택창에서 허용한 파일을 첨부하고 필요할 때 삭제할 수 있습니다.")
            PermissionNoticeText(text: "PDF 파일은 선택 시 기기에 저장하면 빠르게 열어 편집할 수 있습니다.")
            PermissionNoticeText(text: "접근 권한 변경 방법: 휴대폰 설정 > NoteFree")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(NFColor.border, lineWidth: 1)
        )
    }

    /**
     권한 안내 확인 버튼 입니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    @ViewBuilder
    func setConfirmButton() -> some View {
        Button(action: onStartLogin) {
            Text("확인")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(NFColor.blue)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

/**
 권한 안내 항목 Row View 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
private struct PermissionGuideRow: View {
    /// 화면에 표시할 권한 안내 정보 입니다.
    let item: PermissionGuideItem

    /**
     권한 안내 항목을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        HStack(spacing: 18) {
            setIconView()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(NFColor.title)
                    Text("(\(item.requirement))")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(item.isRequired ? NFColor.mint : NFColor.muted)
                }
                Text(item.description)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(NFColor.body)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(NFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(NFColor.border, lineWidth: 1)
        )
    }

    /**
     권한 항목 좌측 아이콘을 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    @ViewBuilder
    private func setIconView() -> some View {
        ZStack {
            Circle()
                .fill(item.accentColor.opacity(0.16))
            Text(item.iconText)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(item.accentColor)
        }
        .frame(width: 58, height: 58)
    }
}

/**
 권한 안내 하단 Bullet 문구 View 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
private struct PermissionNoticeText: View {
    /// 화면에 표시할 안내 문구 입니다.
    let text: String

    /**
     Bullet 안내 문구를 표시합니다.
     - Version: 1.0.0
     - Date: 2026.07.29
     - Returns: `some View`
     */
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NFColor.muted)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(NFColor.muted)
        }
    }
}

/**
 권한 안내 화면에 표시할 단일 권한 데이터 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.29
 */
private struct PermissionGuideItem: Identifiable {
    /// 권한 고유 식별자 입니다.
    let id = UUID()
    /// 권한 아이콘에 표시할 심볼 입니다.
    let iconText: String
    /// 권한 이름 입니다.
    let title: String
    /// 필수/선택 구분 문구 입니다.
    let requirement: String
    /// 권한 사용 목적 설명 입니다.
    let description: String
    /// 권한 아이콘 포인트 색상 입니다.
    let accentColor: Color
    /// 필수 권한 여부 입니다.
    let isRequired: Bool

    /// NoteFree 권한 안내 화면에 노출할 항목 목록 입니다.
    static let items: [PermissionGuideItem] = [
        PermissionGuideItem(iconText: "↓", title: "저장공간", requirement: "필수", description: "PDF 파일을 기기에 저장하고 편집 사항을 빠르게 불러오기", accentColor: NFColor.mint, isRequired: true),
        PermissionGuideItem(iconText: "▤", title: "파일 첨부", requirement: "필수", description: "파일 선택창에서 파일을 추가·삭제하고 PDF 편집 시작", accentColor: NFColor.mint, isRequired: true),
        PermissionGuideItem(iconText: "◉", title: "카메라", requirement: "선택", description: "파일 첨부시 사진 전송", accentColor: NFColor.blue, isRequired: false),
        PermissionGuideItem(iconText: "▧", title: "사진", requirement: "선택", description: "파일 첨부시 사진 전송", accentColor: Color.orange, isRequired: false)
    ]
}

#Preview {
    OnBoardingView(onStartLogin: {})
}
