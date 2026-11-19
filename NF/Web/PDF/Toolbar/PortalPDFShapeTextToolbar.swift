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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("도형 설정", systemImage: "square.on.circle").font(.headline)
                Rectangle().fill(portalTheme.borderColor).frame(height: 1)
                Image(systemName: selectedShapeType.systemImageName)
                    .font(.system(size: 25))
                    .foregroundStyle(selectedShapeLineColor)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(selectedShapeFillColor, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        shapeColorPicker(title: "선", selection: $selectedShapeLineColor)
                        shapeColorPicker(title: "배경", selection: $selectedShapeFillColor)
                    }
                    VStack(alignment: .leading) {
                        shapeColorPicker(title: "선", selection: $selectedShapeLineColor)
                        shapeColorPicker(title: "배경", selection: $selectedShapeFillColor)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 4)], spacing: 4) {
                    ForEach(PortalPDFShapeType.allCases) { shape in
                        Button {
                            selectedShapeType = shape
                            pendingShapeAnnotation = PortalPDFPendingShape(shapeType: shape)
                        } label: {
                            Image(systemName: shape.systemImageName)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(shape == selectedShapeType ? portalTheme.accentColor : portalTheme.foregroundColor)
                                .background(portalTheme.foregroundColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(shape.title)
                        .accessibilityAddTraits(shape == selectedShapeType ? [.isSelected] : [])
                    }
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(portalTheme.foregroundColor)
        .tint(portalTheme.accentColor)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(pdfEditorPanelBackground(cornerRadius: 10))
    }

    /// 텍스트 박스의 배경·테두리 컬러와 명시적 추가 기능을 제공하는 상세 패널입니다.
    var pdfTextOptionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("텍스트 설정", systemImage: "textbox").font(.headline)
                Text("텍스트 박스")
                    .font(.caption)
                    .foregroundStyle(selectedTextColor)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(selectedTextFillColor, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selectedTextBorderColor, lineWidth: 1))
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    compactTextColorPicker(title: "문자", selection: $selectedTextColor)
                    compactTextColorPicker(title: "테두리", selection: $selectedTextBorderColor)
                    compactTextColorPicker(title: "배경", selection: $selectedTextFillColor)
                }
                addTextAnnotationButton
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(portalTheme.foregroundColor)
        .tint(portalTheme.accentColor)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(pdfEditorPanelBackground(cornerRadius: 10))
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
            Label("텍스트 박스 추가", systemImage: "plus.rectangle.on.rectangle")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(portalTheme.accentColor)
                .background(portalTheme.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("텍스트 박스 주석 추가")
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
