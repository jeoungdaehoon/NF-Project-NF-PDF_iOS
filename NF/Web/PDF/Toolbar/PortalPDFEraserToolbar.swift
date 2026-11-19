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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("지우개 설정", systemImage: "eraser").font(.headline)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(portalTheme.foregroundColor.opacity(0.06))
                    Capsule().fill(portalTheme.mutedColor).frame(height: 3).padding(.horizontal, 14)
                    Circle()
                        .fill(portalTheme.surfaceColor)
                        .frame(width: min(38, eraserSize), height: min(38, eraserSize))
                        .overlay(Circle().strokeBorder(portalTheme.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .frame(height: 42)
                .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text("크기").font(.caption)
                    Slider(value: $eraserSizeRaw, in: 12...64, step: 1)
                        .accessibilityLabel("지우개 크기")
                    Text("\(Int(eraserSize.rounded())) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(portalTheme.mutedColor)
                        .fixedSize()
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach([12, 24, 40, 64], id: \.self) { size in
                            Button("\(size)") { eraserSizeRaw = Double(size) }
                                .buttonStyle(.bordered)
                                .accessibilityAddTraits(Int(eraserSize) == size ? [.isSelected] : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(portalTheme.foregroundColor)
        .tint(portalTheme.accentColor)
        .frame(width: markupOptionPanelWidth, height: markupOptionPanelHeightForOrientation)
        .padding(.horizontal, 5)
        .background(pdfEditorPanelBackground(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
