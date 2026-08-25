//
// PortalPDFPenToolbar.swift
// NF
//
// Pen and highlighter palette, detail controls, resizing, and movement.
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
    var pdfPenOptionPanel: some View {
        ZStack {
            Group {
                if penOptionPanelScrollIsVertical {
                    ScrollView(.vertical, showsIndicators: false) {
                        pdfPenEditorContent
                            .frame(width: max(0, currentPenOptionPanelSize.width - 10))
                    }
                    .scrollIndicators(.hidden)
                } else {
                    pdfPenEditorContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(width: currentPenOptionPanelSize.width, height: currentPenOptionPanelSize.height)
        .padding(.horizontal, 5)
        .background(inverseEditorBlurBackground(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
                    Button {
                        if penOptionPanelLocked, !penOptionPanelDetached {
                            let initialSize = penOptionPanelBaseSize
                            let initialOffset = penOptionPanelStoredOffset
                            penOptionPanelDetachedWidthRaw = Double(initialSize.width)
                            penOptionPanelDetachedHeightRaw = Double(initialSize.height)
                            penOptionPanelDetachedOffsetXRaw = Double(initialOffset.width)
                            penOptionPanelDetachedOffsetYRaw = Double(initialOffset.height)
                            penOptionPanelDetachedVerticalRaw = isMarkupToolbarVertical
                            penOptionPanelDetachedScrollVerticalRaw = isMarkupToolbarVertical
                            penOptionPanelDetached = true
                            penOptionPanelDetachedToolbarOffsetXRaw = Double(markupToolbarLiveOffset.width)
                            penOptionPanelDetachedToolbarOffsetYRaw = Double(markupToolbarLiveOffset.height)
                            penOptionPanelDetachedPlacementRaw = (isMarkupToolbarVertical
                        ? (shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize) ? PenEditingPanelPlacement.left : .right)
                        : (shouldPlaceMarkupPanelBelow(in: markupToolbarContainerSize) ? .bottom : .top)
                    ).rawValue
                }
                penOptionPanelLocked.toggle()
            } label: {
                Image(systemName: penOptionPanelLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.gray)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .offset(x: -22, y: -10)
            .accessibilityLabel(penOptionPanelLocked ? "펜 팔레트 잠금 해제" : "펜 팔레트 잠금")
        }
        .overlay(alignment: .topTrailing) {
            if !penOptionPanelLocked {
                penOptionPanelResizeButton
                    .offset(x: 22, y: -10)
            }
        }
        .overlay(alignment: .top) {
            if !penOptionPanelLocked {
                penOptionPanelMoveHandle
                    // 이동 라인이 팝업 외곽에 붙어 보이지 않도록 기존 위치에서 5pt 위로 띄웁니다.
                    .offset(y: -14)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !penOptionPanelLocked {
                Button {
                    penOptionPanelDetachedScrollVerticalRaw.toggle()
                } label: {
                    Image(systemName: penOptionPanelScrollIsVertical ? "arrow.left.and.right" : "arrow.up.and.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gray)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .offset(x: 22, y: 22)
                .accessibilityLabel(penOptionPanelScrollIsVertical ? "팔레트 좌우 스크롤로 변경" : "팔레트 상하 스크롤로 변경")
            }
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.52, blendDuration: 0.05).delay(0.08),
            value: editingPenColor
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("펜 팔레트, 컬러 선택과 선택 컬러의 값·두께 변경")
    }

    /// 잠금 해제된 펜 팔레트 오른쪽 상단의 크기 조절 핸들입니다.
    var penOptionPanelResizeButton: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 24, height: 24)
            .foregroundStyle(Color.gray)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($penOptionPanelResizeTranslation) { value, translation, _ in
                        translation = CGSize(
                            width: value.translation.width,
                            height: -value.translation.height
                        )
                    }
                    .onChanged { value in
                        if !isPenOptionPanelResizing {
                            isPenOptionPanelResizing = true
                            penOptionPanelResizeStartSize = penOptionPanelBaseSize
                        }
                        penOptionPanelLiveSize = clampedPenOptionPanelSize(
                            CGSize(
                                width: penOptionPanelResizeStartSize.width + value.translation.width,
                                height: penOptionPanelResizeStartSize.height - value.translation.height
                            )
                        )
                    }
                    .onEnded { value in
                        let finalSize = clampedPenOptionPanelSize(
                            penOptionPanelLiveSize.width > 0 && penOptionPanelLiveSize.height > 0
                                ? penOptionPanelLiveSize
                                : CGSize(
                                    width: penOptionPanelResizeStartSize.width + value.translation.width,
                                    height: penOptionPanelResizeStartSize.height - value.translation.height
                                )
                        )
                        penOptionPanelCommittedSize = finalSize
                        penOptionPanelCommittedIsVertical = isMarkupToolbarVertical
                            if penOptionPanelDetached {
                                penOptionPanelDetachedWidthRaw = Double(finalSize.width)
                                penOptionPanelDetachedHeightRaw = Double(finalSize.height)
                            } else if isMarkupToolbarVertical {
                                penOptionPanelVerticalWidthRaw = Double(finalSize.width)
                                penOptionPanelVerticalHeightRaw = Double(finalSize.height)
                            } else {
                            penOptionPanelHorizontalWidthRaw = Double(finalSize.width)
                            penOptionPanelHorizontalHeightRaw = Double(finalSize.height)
                        }
                        penOptionPanelLiveSize = .zero
                        isPenOptionPanelResizing = false
                    }
            )
            .accessibilityLabel("펜 팔레트 크기 조절")
            .accessibilityHint("드래그하면 펜 팔레트의 가로와 세로 크기를 변경합니다.")
    }

    /// 잠금 해제된 펜 팔레트 위에서 팔레트 위치를 이동하는 핸들입니다.
    var penOptionPanelMoveHandle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: penOptionPanelMoveHandleWidth, height: 4)
        }
            .frame(width: penOptionPanelMoveHandleWidth, height: 15)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($penOptionPanelMoveTranslation) { value, translation, _ in
                        translation = value.translation
                    }
                    .onChanged { _ in
                        if !isPenOptionPanelMoving {
                            isPenOptionPanelMoving = true
                            penOptionPanelMoveStartOffset = penOptionPanelStoredOffset
                        }
                    }
                    .onEnded { value in
                        let proposedOffset = CGSize(
                            width: penOptionPanelMoveStartOffset.width + value.translation.width,
                            height: penOptionPanelMoveStartOffset.height + value.translation.height
                        )
                        let finalOffset: CGSize
                        if penOptionPanelDetached {
                            let absoluteOffset = clampedDetachedPenOptionPanelAbsoluteOffset(
                                CGSize(
                                    width: penOptionPanelDetachedToolbarOffset.width
                                        + penOptionPanelDetachedPlacementOffset.width
                                        + proposedOffset.width,
                                    height: penOptionPanelDetachedToolbarOffset.height
                                        + penOptionPanelDetachedPlacementOffset.height
                                        + proposedOffset.height
                                ),
                                in: markupToolbarContainerSize
                            )
                            finalOffset = CGSize(
                                width: absoluteOffset.width
                                    - penOptionPanelDetachedToolbarOffset.width
                                    - penOptionPanelDetachedPlacementOffset.width,
                                height: absoluteOffset.height
                                    - penOptionPanelDetachedToolbarOffset.height
                                    - penOptionPanelDetachedPlacementOffset.height
                            )
                        } else {
                            finalOffset = clampedPenOptionPanelOffset(
                                proposedOffset,
                                in: markupToolbarContainerSize
                            )
                        }
                            if penOptionPanelDetached {
                                penOptionPanelDetachedOffsetXRaw = Double(finalOffset.width)
                                penOptionPanelDetachedOffsetYRaw = Double(finalOffset.height)
                            } else if isMarkupToolbarVertical {
                                penOptionPanelVerticalOffsetXRaw = Double(finalOffset.width)
                                penOptionPanelVerticalOffsetYRaw = Double(finalOffset.height)
                            } else {
                            penOptionPanelHorizontalOffsetXRaw = Double(finalOffset.width)
                            penOptionPanelHorizontalOffsetYRaw = Double(finalOffset.height)
                        }
                        isPenOptionPanelMoving = false
                    }
            )
            .accessibilityLabel("펜 팔레트 이동")
            .accessibilityHint("드래그하면 펜 팔레트 위치를 변경하고 저장합니다.")
    }

    /// 펜 팔레트와 선택 컬러의 값·두께 변경을 한 화면에서 제공하는 편집 콘텐츠입니다.
    var pdfPenEditorContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if penOptionPanelScrollIsVertical {
                VStack(alignment: .center, spacing: 4) {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 32, maximum: 42), spacing: 12)],
                            spacing: 12
                        ) {
                            penColorPaletteItems
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [GridItem(.adaptive(minimum: 42, maximum: 42), spacing: 12)],
                        spacing: 12
                    ) {
                        penColorPaletteItems
                    }
                    .frame(minHeight: 42)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
            }

        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 세로 편집창에서 컬러 팔레트 오른쪽에 표시할 컬러·두께·타입 상세 편집입니다.
    func pdfPenEditingDetails(for editingPenColor: PortalPDFPenColor) -> some View {
        VStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ColorPicker(
                    "\(editingPenColor.title) 컬러 값 변경",
                    selection: $editingPenColorValue,
                    supportsOpacity: true
                )
                .labelsHidden()
                .onChange(of: editingPenColorValue) { _, _ in
                    updatePenColorEditingImmediately()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Slider(
                        value: $editingPenLineWidth,
                        in: selectedTool == .highlighter ? 18...48 : 0.3...8.0,
                        step: selectedTool == .highlighter ? 1 : 0.1
                    )
                    .tint(editingPenColorValue)
                    .frame(maxWidth: .infinity)
                    .onChange(of: editingPenLineWidth) { _, _ in
                        updatePenColorEditingImmediately()
                    }
                    Text(String(format: "%.1f", editingPenLineWidth))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    Capsule(style: .continuous)
                        .fill(editingPenColorValue)
                        .frame(width: 20, height: max(2, editingPenLineWidth))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(editingPenColor.title) 펜 두께 \(String(format: "%.1f", editingPenLineWidth))")

            if selectedTool == .pen {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("라인 보정")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("\(Int((editingPenStrokeSmoothingStrength * 100).rounded()))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $editingPenStrokeSmoothingStrength,
                        in: 0...2,
                        step: 0.05
                    )
                    .tint(editingPenColorValue)
                    .onChange(of: editingPenStrokeSmoothingStrength) { _, _ in
                        updatePenColorEditingImmediately()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "라인 보정 \(Int((editingPenStrokeSmoothingStrength * 100).rounded()))퍼센트"
                )
            }

            if selectedTool == .highlighter {
                VStack(alignment: .leading, spacing: 4) {
                    Text("끝모양")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("형광펜 끝모양", selection: $selectedHighlighterCapRawValue) {
                        ForEach(PortalPDFHighlighterCap.allCases) { cap in
                            Text(cap.title)
                                .tag(cap.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("형광펜 끝모양 \(selectedHighlighterCap.title)")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("팬슬 타입", selection: $selectedPenTypeRawValue) {
                        ForEach(PortalPDFPenType.allCases) { penType in
                            Text(penType.title)
                                .tag(penType.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("팬슬 타입 \(selectedPenType.title)")

                if selectedTool == .pen && selectedPenType == .pressure {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("압력 강도")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text("\(Int((editingPenPressureStrength * 100).rounded()))%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $editingPenPressureStrength,
                            in: 0...2,
                            step: 0.05
                        )
                        .tint(editingPenColorValue)
                        .onChange(of: editingPenPressureStrength) { _, _ in
                            updatePenColorEditingImmediately()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "압력 강도 \(Int((editingPenPressureStrength * 100).rounded()))퍼센트"
                    )
                }
            }
        }
        .padding(8)
    }

    /// 컬러 팔레트와 독립적으로 표시되는 컬러·두께·타입 팝업입니다.
    @ViewBuilder
    var activePenEditingPanel: some View {
        if isPenEditingPanelPresented, let editingPenColor {
            ScrollView(.vertical, showsIndicators: false) {
                pdfPenEditingDetails(for: editingPenColor)
                    .frame(maxWidth: .infinity, minHeight: penEditingPanelHeight, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .frame(width: penEditingPanelWidth, height: penEditingPanelHeight)
            .background(inverseEditorBlurBackground(cornerRadius: 14))
            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(editingPenColor.title) 상세 편집")
        }
    }

    /// 팬슬 컬러 항목을 방향과 관계없이 동일하게 재사용하는 팔레트 콘텐츠입니다.
    @ViewBuilder
    var penColorPaletteItems: some View {
        ForEach(penColors) { penColor in
            Button {
                if selectedPenColor == penColor {
                    // 현재 선택된 컬러를 한 번 더 누르면 컬러·두께 편집창을 토글합니다.
                    if editingPenColor == penColor {
                        editingPenColor = nil
                    } else {
                        beginPenColorEditing(penColor)
                    }
                } else {
                    selectPenColor(penColor)
                }
            } label: {
                VStack(alignment: .center, spacing: 2) {
                    Circle()
                        .fill(displayColor(for: penColor))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle()
                                .stroke(selectedPenColor == penColor ? Color.white : Color.clear, lineWidth: 3)
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        }
                    Text(String(format: "%.1f", penLineWidth(for: penColor)))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 42, alignment: .center)
            }
            .accessibilityLabel("펜 색상 \(penColor.title) 선택")
            .accessibilityHint(selectedPenColor == penColor ? "한 번 더 누르면 컬러와 두께 편집창을 엽니다." : "선택하면 현재 펜 컬러로 적용합니다.")
        }

        if penColors.count < 30 {
            Button(action: addPenColor) {
                VStack(spacing: 2) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 26, height: 26)
                    Text("추가")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 32, height: 42, alignment: .center)
            }
            .accessibilityLabel("컬러 추가")
            .accessibilityHint("최대 30개까지 컬러를 추가하고 편집창을 엽니다.")
        }
    }

    /// 현재 선택된 팔레트 색상을 PDF 주석에 적용할 실제 펜 색상으로 반환합니다.
    var activePenColor: Color {
        if selectedTool == .highlighter {
            return highlighterColor(for: selectedPenColor)
        }
        return basePenColor(for: selectedPenColor)
    }

    /// 형광펜은 일반 펜보다 넓은 반투명 선으로 표시합니다.
    var activePenLineWidth: CGFloat {
        selectedTool == .highlighter
            ? highlighterLineWidth(for: selectedPenColor)
            : selectedPenLineWidth
    }

    /// 형광펜은 압력에 따른 분할 저장이 아닌 단일 고정 굵기 선으로 처리합니다.
    var activePenType: PortalPDFPenType {
        selectedTool == .highlighter || selectedTool == .neon ? .fixed : selectedPenType
    }

    /// 현재 선택 컬러에 저장된 압력 반응 강도를 실제 펜 입력에 적용합니다.
    var activePenPressureStrength: CGFloat {
        guard activePenType == .pressure else { return 1.0 }
        return penPressureStrength(for: selectedPenColor)
    }

    /// 현재 선택 컬러에 저장된 스트로크 끝 삐침 완화 강도를 실제 펜 입력에 적용합니다.
    var activePenStrokeSmoothingStrength: CGFloat {
        guard selectedTool == .pen else { return 0 }
        return penStrokeSmoothingStrength(for: selectedPenColor)
    }

    /// 팔레트 원에 표시할 사용자 지정 색상을 반환합니다.
    func displayColor(for penColor: PortalPDFPenColor) -> Color {
        selectedTool == .highlighter
            ? highlighterColor(for: penColor)
            : basePenColor(for: penColor)
    }

    /// 사용자 지정 값이 있으면 해당 값을, 없으면 기본 팔레트 색상을 반환합니다.
    func basePenColor(for penColor: PortalPDFPenColor) -> Color {
        customizedPenColors[penColor.id] ?? penColor.color
    }

    /// 컬러별로 저장된 펜 두께를 반환하며, 설정하지 않은 컬러는 기본 두께를 사용합니다.
    func penLineWidth(for penColor: PortalPDFPenColor) -> CGFloat {
        selectedTool == .highlighter
            ? highlighterLineWidth(for: penColor)
            : customizedPenLineWidths[penColor.id] ?? 2.4
    }

    /// 컬러별 압력 반응 강도를 0~2 범위로 반환합니다.
    func penPressureStrength(for penColor: PortalPDFPenColor) -> CGFloat {
        min(2, max(0, customizedPenPressureStrengths[penColor.id] ?? 1.0))
    }

    /// 컬러별 스트로크 끝 삐침 완화 강도를 0~2 범위로 반환합니다.
    func penStrokeSmoothingStrength(for penColor: PortalPDFPenColor) -> CGFloat {
        min(2, max(0, customizedPenStrokeSmoothingStrengths[penColor.id] ?? 0.5))
    }

    /// 저장된 팬슬 타입을 안전하게 열거형으로 변환합니다.
    var selectedPenType: PortalPDFPenType {
        PortalPDFPenType(rawValue: selectedPenTypeRawValue) ?? .fixed
    }

    var highlighterLineWidth: CGFloat {
        get { max(18, CGFloat(highlighterLineWidthRaw)) }
        set { highlighterLineWidthRaw = Double(max(18, newValue)) }
    }

    func highlighterColor(for penColor: PortalPDFPenColor) -> Color {
        customizedHighlighterColors[penColor.id] ?? .yellow.opacity(0.42)
    }

    func highlighterLineWidth(for penColor: PortalPDFPenColor) -> CGFloat {
        customizedHighlighterLineWidths[penColor.id] ?? highlighterLineWidth
    }

    var selectedHighlighterCap: PortalPDFHighlighterCap {
        PortalPDFHighlighterCap(rawValue: selectedHighlighterCapRawValue) ?? .round
    }

    /// 컬러 팔레트 오른쪽의 추가 버튼을 눌렀을 때 새 컬러를 만들고 즉시 편집 상태로 전환합니다.
    func addPenColor() {
        guard penColors.count < 30 else { return }
        let newColor = PortalPDFPenColor.custom(index: penColors.count + 1)
        penColors.append(newColor)
        savePenPalette()
        beginPenColorEditing(newColor)
    }

    /// 팔레트 컬러를 선택하고 해당 컬러에 저장된 펜 두께를 현재 펜에 적용합니다.
    func selectPenColor(_ penColor: PortalPDFPenColor) {
        selectedPenColor = penColor
        selectedPenLineWidth = penLineWidth(for: penColor)
        editingPenColor = nil
    }

    /// 선택된 팔레트 컬러를 다시 눌렀을 때 컬러 값과 두께를 함께 편집할 임시 상태를 준비합니다.
    func beginPenColorEditing(_ penColor: PortalPDFPenColor) {
        selectedPenColor = penColor
        editingPenColor = penColor
        editingPenColorValue = selectedTool == .highlighter
            ? highlighterColor(for: penColor)
            : basePenColor(for: penColor)
        editingPenLineWidth = selectedTool == .highlighter
            ? highlighterLineWidth(for: penColor)
            : penLineWidth(for: penColor)
        editingPenPressureStrength = penPressureStrength(for: penColor)
        editingPenStrokeSmoothingStrength = penStrokeSmoothingStrength(for: penColor)
    }

    /// 컬러 팝업 또는 두께 슬라이더 조작 즉시 현재 편집 컬러에 값을 반영합니다.
    func updatePenColorEditingImmediately() {
        guard let editingPenColor else { return }
        if selectedTool == .highlighter {
            customizedHighlighterColors[editingPenColor.id] = editingPenColorValue
            customizedHighlighterLineWidths[editingPenColor.id] = max(18, editingPenLineWidth)
        } else {
            customizedPenColors[editingPenColor.id] = editingPenColorValue
            customizedPenLineWidths[editingPenColor.id] = editingPenLineWidth
            customizedPenPressureStrengths[editingPenColor.id] = min(
                2,
                max(0, editingPenPressureStrength)
            )
            customizedPenStrokeSmoothingStrengths[editingPenColor.id] = min(
                2,
                max(0, editingPenStrokeSmoothingStrength)
            )
        }
        selectedPenColor = editingPenColor
        selectedPenLineWidth = editingPenLineWidth
        if selectedTool != .highlighter {
            savePenPalette()
        }
    }

    /**
     앱 실행 시 로컬에 저장한 펜 팔레트를 복원합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Note: 저장값이 없거나 손상된 경우 기본 팔레트를 화면에 표시하고 즉시 저장합니다.
     */
    func loadPenPalette() {
        guard !didLoadPenPalette else { return }
        didLoadPenPalette = true

        guard let records = PortalPDFPenPaletteStore.load(), !records.isEmpty else {
            // 최초 실행은 기본 컬러를 그대로 보여주고 다음 실행에서 재사용할 수 있도록 저장합니다.
            savePenPalette()
            return
        }

        let restoredColors = records.prefix(30).map(\.penColor)
        guard !restoredColors.isEmpty else {
            savePenPalette()
            return
        }

        penColors = restoredColors
        customizedPenColors = Dictionary(uniqueKeysWithValues: restoredColors.map { ($0.id, $0.color) })
        customizedPenLineWidths = Dictionary(
            uniqueKeysWithValues: records.prefix(30).map { ($0.id, CGFloat($0.lineWidth)) }
        )
        customizedPenPressureStrengths = Dictionary(
            uniqueKeysWithValues: records.prefix(30).map {
                ($0.id, min(2, max(0, CGFloat($0.pressureStrength ?? 1.0))))
            }
        )
        customizedPenStrokeSmoothingStrengths = Dictionary(
            uniqueKeysWithValues: records.prefix(30).map {
                ($0.id, min(2, max(0, CGFloat($0.strokeSmoothingStrength ?? 0.5))))
            }
        )

        let restoredSelectedColor = restoredColors.first ?? PortalPDFPenColor.defaults[0]
        selectedPenColor = restoredSelectedColor
        selectedPenLineWidth = penLineWidth(for: restoredSelectedColor)
    }

    func migrateDetachedPenOptionPanelStateIfNeeded() {
        guard !penOptionPanelLocked, !penOptionPanelDetached else { return }
        let initialSize = penOptionPanelBaseSize
        let initialOffset = penOptionPanelStoredOffset
        penOptionPanelDetachedWidthRaw = Double(initialSize.width)
        penOptionPanelDetachedHeightRaw = Double(initialSize.height)
        penOptionPanelDetachedOffsetXRaw = Double(initialOffset.width)
        penOptionPanelDetachedOffsetYRaw = Double(initialOffset.height)
        penOptionPanelDetachedVerticalRaw = isMarkupToolbarVertical
        penOptionPanelDetachedScrollVerticalRaw = isMarkupToolbarVertical
        penOptionPanelDetachedToolbarOffsetXRaw = Double(markupToolbarOffset.width)
        penOptionPanelDetachedToolbarOffsetYRaw = Double(markupToolbarOffset.height)
        penOptionPanelDetachedPlacementRaw = (isMarkupToolbarVertical
            ? (shouldPlaceMarkupPanelOnLeft(in: markupToolbarContainerSize) ? PenEditingPanelPlacement.left : .right)
            : (shouldPlaceMarkupPanelBelow(in: markupToolbarContainerSize) ? .bottom : .top)
        ).rawValue
        penOptionPanelDetached = true
    }

    /**
     현재 펜 팔레트와 컬러별 두께를 로컬에 저장합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Note: 컬러 팝업 또는 두께 슬라이더가 변경될 때마다 호출해 앱 재실행 후에도 유지합니다.
     */
    func savePenPalette() {
        let records = penColors.map { penColor in
            PortalPDFPenPaletteStore.Record(
                penColor: penColor,
                color: basePenColor(for: penColor),
                lineWidth: customizedPenLineWidths[penColor.id] ?? 2.4,
                pressureStrength: customizedPenPressureStrengths[penColor.id] ?? 1.0,
                strokeSmoothingStrength: customizedPenStrokeSmoothingStrengths[penColor.id] ?? 0.5
            )
        }
        PortalPDFPenPaletteStore.save(records)
    }

    /// 박스 도구에서 사용할 도형을 한 줄 가로 스크롤로 선택하는 상세 패널입니다.
}
