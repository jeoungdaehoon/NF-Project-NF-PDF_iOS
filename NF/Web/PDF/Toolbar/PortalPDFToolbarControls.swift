//
// PortalPDFToolbarControls.swift
// NF
//
// Shared toolbar controls and command buttons.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

extension PortalPDFPreviewView {
    func pdfMarkupToolbar(moveGesture: AnyGesture<DragGesture.Value>) -> some View {
        Group {
            // 이동 버튼을 그리드의 첫 항목으로 넣어 항상 0번째 위치에 표시합니다.
            if isMarkupToolbarVertical {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 6)],
                        spacing: 6
                    ) {
                        pdfMarkupMoveButton(moveGesture: moveGesture)
                        pdfHistoryButton(.undo)
                        pdfHistoryButton(.redo)
                        pdfFullscreenModeButton
                        ForEach(PortalPDFMarkupTool.visibleTools) { tool in
                            pdfMarkupToolButton(tool)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 6)],
                        spacing: 6
                    ) {
                        pdfMarkupMoveButton(moveGesture: moveGesture)
                        pdfHistoryButton(.undo)
                        pdfHistoryButton(.redo)
                        pdfFullscreenModeButton
                        ForEach(PortalPDFMarkupTool.visibleTools) { tool in
                            pdfMarkupToolButton(tool)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 알약 외곽 크기만 변경하고 내부 버튼은 항상 40pt 크기를 유지합니다.
        .padding(4)
        .frame(width: currentMarkupToolbarSize.width, height: currentMarkupToolbarSize.height)
        .background(inverseEditorBlurBackground(cornerRadius: 18))
        // 작은 크기에서 스크롤 영역의 버튼이 알약 외부로 그려지지 않도록 마스킹합니다.
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        // 세로 모드에서는 왼쪽 상단, 가로 모드에서는 기존 오른쪽 상단에 크기 조절 핸들을 표시합니다.
        .overlay(alignment: isMarkupToolbarVertical ? .topLeading : .topTrailing) {
            pdfMarkupResizeButton
                .offset(x: isMarkupToolbarVertical ? -8 : 8, y: -15)
                .zIndex(4)
        }
    }

    /// 기본 편집 박스의 실행 취소·다시 실행 버튼입니다.
    func pdfHistoryButton(_ operation: PortalPDFHistoryCommand.Operation) -> some View {
        let isEnabled = operation == .undo ? canUndoPDFEdit : canRedoPDFEdit
        return Button {
            pendingHistoryCommand = PortalPDFHistoryCommand(operation: operation)
        } label: {
            Image(systemName: operation == .undo ? "arrow.uturn.backward" : "arrow.uturn.forward")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.32))
                .background(Color.white.opacity(isEnabled ? 0.12 : 0.06))
                .clipShape(Capsule())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(operation == .undo ? "편집 이전으로 돌리기" : "편집 앞으로 돌리기")
    }

    /// 편집 알약 상단의 가로·세로 크기 조절 핸들입니다.
    var pdfMarkupResizeButton: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 24, height: 24)
            .foregroundStyle(Color.gray)
            .contentShape(Rectangle())
            .gesture(
                // 크기가 변경되는 핸들 자체의 로컬 좌표를 사용하면 드래그 중 좌표 원점도 함께
                // 이동하여 translation 값이 앞뒤로 흔들릴 수 있으므로 고정된 전역 좌표를 사용합니다.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($markupToolbarResizeTranslation) { value, translation, _ in
                        // 세로 모드의 왼쪽 핸들은 좌측 이동, 가로 모드의 오른쪽 핸들은 우측 이동 시
                        // 폭이 늘어나도록 가로 방향을 보정하고 위쪽 이동은 높이를 늘립니다.
                        translation = CGSize(
                            width: isMarkupToolbarVertical
                                ? -value.translation.width
                                : value.translation.width,
                            height: -value.translation.height
                        )
                    }
                    .onChanged { value in
                        if !isMarkupToolbarResizing {
                            isMarkupToolbarResizing = true
                            markupToolbarResizeStartSize = markupToolbarSize
                        }
                    }
                    .onEnded { value in
                        let finalSize = CGSize(
                            width: markupToolbarResizeStartSize.width
                                + (isMarkupToolbarVertical
                                    ? -value.translation.width
                                    : value.translation.width),
                            height: markupToolbarResizeStartSize.height - value.translation.height
                        )
                        markupToolbarSize = clampedMarkupToolbarSize(
                            finalSize,
                            in: markupToolbarContainerSize
                        )
                        isMarkupToolbarResizing = false
                    }
            )
            .accessibilityLabel("편집 알약 크기 조절")
            .accessibilityHint("드래그하면 편집 알약의 가로와 세로 크기를 변경합니다. 화면 사방 20포인트 안에서 조절됩니다.")
    }

    /// 편집 알약의 가장 오른쪽(세로 배치에서는 가장 아래)에 고정되는 이동/방향 전환 버튼입니다.
    ///
    /// 클릭만 하면 가로·세로 방향을 바꾸고, 손가락이 움직이는 즉시 도구 알약 전체가
    /// 손가락을 따라 이동합니다. 별도의 LongPress 대기 시간을 두지 않아 빠른 이동이
    /// 가능하며, DragGesture의 @GestureState를 사용해 이동 중 화면 버벅임을 줄입니다.
    func pdfMarkupMoveButton(moveGesture: AnyGesture<DragGesture.Value>) -> some View {
        Image(systemName: isMarkupToolbarVertical ? "arrow.left.and.right" : "arrow.up.and.down")
            .font(.system(size: 18, weight: .semibold))
            // 알약 외곽 크기와 관계없이 이동 버튼의 터치 영역은 항상 40pt로 고정합니다.
            .frame(width: 40, height: 40)
            .foregroundStyle(Color.white)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            .contentShape(Capsule())
            // 이동 제스처 상태는 전용 하위 컨테이너가 소유해 상위 PDF 화면 갱신을 차단합니다.
            .highPriorityGesture(moveGesture)
            .accessibilityLabel("편집 도구 배치 변경")
            .accessibilityHint("클릭하면 가로와 세로 방향을 바꾸고, 손가락을 움직이면 즉시 편집 알약을 이동합니다.")
    }

    /// 상단 타이틀 바를 숨기고 문서 탭바만 남기는 편집 화면 전체화면 토글입니다.
    var pdfFullscreenModeButton: some View {
        Button {
            togglePDFEditorFullscreenMode()
        } label: {
            Image(systemName: isPDFEditorFullscreenModeEnabled
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.white)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .accessibilityLabel(isPDFEditorFullscreenModeEnabled ? "전체화면 모드 종료" : "전체화면 모드 실행")
        .accessibilityHint("상단 타이틀 바를 표시하거나 숨깁니다.")
    }

    /// 단일 PDF 편집 도구 아이콘을 공통 스타일과 동작으로 생성합니다.
    func pdfMarkupToolButton(_ tool: PortalPDFMarkupTool) -> some View {
        Button {
            selectMarkupTool(tool)
        } label: {
            // 하단 편집 도구는 아이콘만 표시해 PDF 화면을 가리지 않도록 구성합니다.
            Image(systemName: tool.systemImageName)
                .font(.system(size: 20, weight: .semibold))
                // 알약 크기가 변경되어도 개별 도구 버튼의 가로·세로 크기는 40pt를 유지합니다.
                .frame(width: 40, height: 40)
                .foregroundStyle(selectedTool == tool ? Color.black : Color.white)
                .background(selectedTool == tool ? Color.white : Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .accessibilityLabel(tool.accessibilityLabel)
        .accessibilityHint("\(tool.title) 도구")
    }

    /// 지우개 크기를 조정하는 하단 상세 편집 박스입니다.
}
