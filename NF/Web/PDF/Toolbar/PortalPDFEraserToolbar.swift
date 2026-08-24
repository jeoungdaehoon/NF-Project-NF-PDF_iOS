//
// PortalPDFEraserToolbar.swift
// NF
//
// Eraser toolbar panel and eraser-specific controls.
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
    var pdfEraserOptionPanel: some View {
        Group {
            if isMarkupToolbarVertical {
                VStack(spacing: 4) {
                    Text("\(Int(eraserSize.rounded()))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: $eraserSizeRaw, in: 12...64, step: 1)
                        .frame(width: max(80, verticalMarkupToolbarHeight - 36), height: 44)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: max(80, verticalMarkupToolbarHeight - 36))
                        .tint(.white)
                }
                .padding(.vertical, 10)
                .frame(width: 50, height: verticalMarkupToolbarHeight, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "eraser")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: $eraserSizeRaw, in: 12...64, step: 1)
                        .tint(.white)
                    Text("\(Int(eraserSize.rounded()))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(inverseEditorBlurBackground(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("지우개 크기 \(Int(eraserSize.rounded()))")
    }


    /// 펜 색상과 두께를 변경하기 위한 하단 상세 편집 박스입니다.
}
