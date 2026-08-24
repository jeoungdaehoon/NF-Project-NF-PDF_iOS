//
// PortalPDFShapeTextToolbar.swift
// NF
//
// Shape and text annotation toolbar panels.
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
    var pdfShapeOptionPanel: some View {
        VStack(alignment: isMarkupToolbarVertical ? .center : .leading, spacing: 6) {
            if isMarkupToolbarVertical {
                VStack(alignment: .center, spacing: 6) {
                    shapeColorPicker(title: "선", selection: $selectedShapeLineColor)
                    shapeColorPicker(title: "배경", selection: $selectedShapeFillColor)
                }
            } else {
                HStack(spacing: 14) {
                    shapeColorPicker(title: "선", selection: $selectedShapeLineColor)
                    shapeColorPicker(title: "배경", selection: $selectedShapeFillColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isMarkupToolbarVertical {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(PortalPDFShapeType.allCases) { shapeType in
                            shapeTypeButton(shapeType)
                        }
                    }
                    .padding(.top, 2)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PortalPDFShapeType.allCases) { shapeType in
                            shapeTypeButton(shapeType)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(inverseEditorBlurBackground(cornerRadius: 18))
    }

    /// 텍스트 박스의 배경·테두리 컬러와 명시적 추가 기능을 제공하는 상세 패널입니다.
    var pdfTextOptionPanel: some View {
        Group {
            if isMarkupToolbarVertical {
                VStack(spacing: 8) {
                    compactTextColorPicker(title: "문자", selection: $selectedTextColor)
                    compactTextColorPicker(title: "라인", selection: $selectedTextBorderColor)
                    compactTextColorPicker(title: "배경", selection: $selectedTextFillColor)
                    addTextAnnotationButton
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    compactTextColorPicker(title: "문자", selection: $selectedTextColor)
                    compactTextColorPicker(title: "라인", selection: $selectedTextBorderColor)
                    compactTextColorPicker(title: "배경", selection: $selectedTextFillColor)
                    addTextAnnotationButton
                }
            }
        }
        .padding(10)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(inverseEditorBlurBackground(cornerRadius: 18))
    }

    /// 문자 패널 폭을 유지하면서 문자·라인·배경 컬러를 구분해 선택합니다.
    func compactTextColorPicker(title: String, selection: Binding<Color>) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ColorPicker("\(title) 컬러 값 변경", selection: selection, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 28, height: 28)
        }
        .frame(width: 36, height: 46)
    }

    /// 현재 보이는 PDF 페이지 중앙에 텍스트 박스 주석을 추가하도록 요청합니다.
    var addTextAnnotationButton: some View {
        Button {
            pendingTextAnnotation = PortalPDFPendingText(
                occludedViewRect: currentMarkupToolbarFrame
            )
            isTextOptionPresented = false
        } label: {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(Color.white)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("텍스트 박스 주석 추가")
    }

    /// 박스 상세 편집창에서 도형 종류를 선택하는 공통 버튼입니다.
    func shapeTypeButton(_ shapeType: PortalPDFShapeType) -> some View {
        Button {
            selectedShapeType = shapeType
            pendingShapeAnnotation = PortalPDFPendingShape(shapeType: shapeType)
            // 도형 종류를 선택하면 화면 중앙에 즉시 추가하고 바로 편집할 수 있게 합니다.
            isShapeOptionPresented = false
        } label: {
            Image(systemName: shapeType.systemImageName)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(selectedShapeType == shapeType ? Color.black : Color.white.opacity(0.86))
                .background(selectedShapeType == shapeType ? Color.white : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityLabel("\(shapeType.title) 도형 선택")
    }

    /// 팬슬 컬러 값 변경과 동일한 방식으로 박스 선·배경 컬러를 변경합니다.
    func shapeColorPicker(
        title: String,
        selection: Binding<Color>
    ) -> some View {
        Group {
            if isMarkupToolbarVertical {
                VStack(alignment: .center, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker(
                        "\(title) 컬러 값 변경",
                        selection: selection,
                        supportsOpacity: true
                    )
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker(
                        "\(title) 컬러 값 변경",
                        selection: selection,
                        supportsOpacity: true
                    )
                    .labelsHidden()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 실제 기기 사진첩의 최근 사진을 Grid로 표시하는 사진 선택 팝업입니다.
}
