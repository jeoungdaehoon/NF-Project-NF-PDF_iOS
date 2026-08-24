//
// PortalPDFToolbarPersistence.swift
// NF
//
// Persistent palette, toolbar layout, and viewport state.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

enum PortalPDFPenPaletteStore {
    /// 앱 업데이트 후에도 동일한 펜 팔레트 데이터를 찾기 위한 UserDefaults 키입니다.
    static let storageKey = "nf.pdf.pen.palette.v1"

    /**
     UserDefaults에 저장할 단일 펜 컬러 레코드입니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     */
    struct Record: Codable {
        /// 컬러 항목 식별자입니다.
        let id: String
        /// 컬러 항목 표시 이름입니다.
        let title: String
        /// 저장할 컬러의 빨강 구성 요소입니다.
        let red: Double
        /// 저장할 컬러의 초록 구성 요소입니다.
        let green: Double
        /// 저장할 컬러의 파랑 구성 요소입니다.
        let blue: Double
        /// 저장할 컬러의 투명도 구성 요소입니다.
        let alpha: Double
        /// 컬러에 연결된 PDF 펜 두께입니다.
        let lineWidth: Double
        /// 컬러에 연결된 압력 반응 강도입니다. 이전 저장 데이터는 1.0으로 복원합니다.
        let pressureStrength: Double?
        /// 컬러에 연결된 스트로크 끝 삐침 완화 강도입니다. 0~2 범위이며 이전 저장 데이터는 0.5로 복원합니다.
        let strokeSmoothingStrength: Double?

        /**
         현재 화면 컬러를 UserDefaults 저장 모델로 변환합니다.
         - Parameters:
            - penColor: 저장할 팔레트 컬러 항목입니다.
            - color: 사용자 지정 색상과 알파가 반영된 SwiftUI 컬러입니다.
            - lineWidth: 컬러에 연결된 PDF 펜 두께입니다.
         */
        init(
            penColor: PortalPDFPenColor,
            color: Color,
            lineWidth: CGFloat,
            pressureStrength: CGFloat = 1.0,
            strokeSmoothingStrength: CGFloat = 0.5
        ) {
            let uiColor = UIColor(color)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 1

            // 색상 공간 변환이 실패하는 시스템 색상은 안전한 검정색으로 저장합니다.
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                self.id = penColor.id
                self.title = penColor.title
                self.red = 0
                self.green = 0
                self.blue = 0
                self.alpha = 1
                self.lineWidth = Double(lineWidth)
                self.pressureStrength = Double(pressureStrength)
                self.strokeSmoothingStrength = Double(strokeSmoothingStrength)
                return
            }

            self.id = penColor.id
            self.title = penColor.title
            self.red = Double(red)
            self.green = Double(green)
            self.blue = Double(blue)
            self.alpha = Double(alpha)
            self.lineWidth = Double(lineWidth)
            self.pressureStrength = Double(pressureStrength)
            self.strokeSmoothingStrength = Double(strokeSmoothingStrength)
        }

        /// 저장된 RGBA 구성 요소를 다시 화면과 PDF에 사용할 펜 컬러 모델로 변환합니다.
        var penColor: PortalPDFPenColor {
            PortalPDFPenColor(
                id: id,
                title: title,
                color: Color(red: red, green: green, blue: blue, opacity: alpha)
            )
        }
    }

    /// UserDefaults에 저장된 펜 팔레트 레코드를 읽습니다.
    static func load() -> [Record]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode([Record].self, from: data)
    }

    /// 펜 팔레트 레코드를 JSON으로 변환해 UserDefaults에 저장합니다.
    static func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/**
 PDF 첨부 파일별 하단 편집 박스 상태를 UserDefaults에 저장·복원하는 로컬 저장소입니다.
 - Version: 1.0.0
 - Date: 2026.08.05
 - Note: PDF 주석 데이터가 아니라 편집 박스의 도구·방향·위치·크기 상태만 저장합니다.
 */
enum PortalPDFMarkupToolbarStore {
    /// UserDefaults에 저장할 하단 편집 박스 상태입니다.
    struct Record: Codable {
        /// ColorPicker에서 변경한 컬러와 알파값을 저장하는 RGBA 모델입니다.
        struct ColorValue: Codable {
            let red: Double
            let green: Double
            let blue: Double
            let alpha: Double

            init(color: Color) {
                let uiColor = UIColor(color)
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 1

                if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    self.red = Double(red)
                    self.green = Double(green)
                    self.blue = Double(blue)
                    self.alpha = Double(alpha)
                } else {
                    self.red = 0
                    self.green = 0
                    self.blue = 0
                    self.alpha = 1
                }
            }

            var color: Color {
                Color(red: red, green: green, blue: blue, opacity: alpha)
            }
        }

        /// 마지막으로 선택한 편집 도구의 rawValue입니다.
        let selectedToolRaw: String
        /// 편집 박스의 세로 배치 여부입니다.
        let isVertical: Bool
        /// 편집 박스 위치 오프셋의 가로 값입니다.
        let offsetX: Double
        /// 편집 박스 위치 오프셋의 세로 값입니다.
        let offsetY: Double
        /// 편집 박스 외곽 크기의 가로 값입니다.
        let width: Double
        /// 편집 박스 외곽 크기의 세로 값입니다.
        let height: Double
        /// 펜 상세 편집창이 열린 상태인지 여부입니다.
        let isPenOptionPresented: Bool
        /// 박스 추가 편집창이 열린 상태인지 여부입니다.
        let isShapeOptionPresented: Bool
        /// 박스 선 ColorPicker의 컬러와 알파값입니다.
        let shapeLineColor: ColorValue?
        /// 박스 배경 ColorPicker의 컬러와 알파값입니다.
        let shapeFillColor: ColorValue?

        init(
            selectedTool: PortalPDFMarkupTool,
            isVertical: Bool,
            offset: CGSize,
            size: CGSize,
            isPenOptionPresented: Bool,
            isShapeOptionPresented: Bool,
            shapeLineColor: Color,
            shapeFillColor: Color
        ) {
            selectedToolRaw = selectedTool.rawValue
            self.isVertical = isVertical
            offsetX = Double(offset.width)
            offsetY = Double(offset.height)
            width = Double(size.width)
            height = Double(size.height)
            self.isPenOptionPresented = isPenOptionPresented
            self.isShapeOptionPresented = isShapeOptionPresented
            self.shapeLineColor = ColorValue(color: shapeLineColor)
            self.shapeFillColor = ColorValue(color: shapeFillColor)
        }

        /// 저장된 도구 rawValue를 현재 앱에서 사용할 도구로 변환합니다.
        var selectedTool: PortalPDFMarkupTool {
            PortalPDFMarkupTool(rawValue: selectedToolRaw) ?? .view
        }

        /// 저장된 위치를 SwiftUI CGSize로 변환합니다.
        var offset: CGSize {
            CGSize(width: offsetX, height: offsetY)
        }

        /// 저장된 크기를 SwiftUI CGSize로 변환합니다.
        var size: CGSize {
            CGSize(width: width, height: height)
        }
    }

    /// 첨부 URL별로 분리된 UserDefaults 키를 만듭니다.
    static func storageKey(for url: URL) -> String {
        "nf.pdf.markup.toolbar.v1.\(url.absoluteString)"
    }

    /// 첨부 파일 URL에 저장된 편집 박스 상태를 읽습니다.
    static func load(for url: URL) -> Record? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: url)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// 첨부 파일 URL에 편집 박스 상태를 저장합니다.
    static func save(_ record: Record, for url: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: url))
    }

    static func remove(for url: URL) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: url))
    }
}

/// PDF 문서별 마지막 확대 배율과 스크롤 위치를 앱 재실행 후에도 복원하는 저장소입니다.
enum PortalPDFViewportStore {
    struct Record: Codable {
        let scaleFactor: Double
        let contentOffsetX: Double
        let contentOffsetY: Double
        /// PDFView 내부 여백이나 문서 레이아웃이 다시 계산되어도 같은 위치를 찾기 위한 페이지 번호입니다.
        let pageIndex: Int?
        /// 저장 당시 화면 중앙에 있던 PDF 페이지 좌표입니다.
        let pagePointX: Double?
        let pagePointY: Double?
    }

    static let storageKey = "nf.pdf.viewport.records.v1"

    static func load(for identifier: String, userDefaults: UserDefaults = .standard) -> Record? {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return nil }
        return records[identifier]
    }

    static func save(
        _ record: Record,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) {
        var records: [String: Record] = [:]
        if let data = userDefaults.data(forKey: storageKey),
           let savedRecords = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = savedRecords
        }
        records[identifier] = record
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    static func remove(for identifier: String, userDefaults: UserDefaults = .standard) {
        guard let data = userDefaults.data(forKey: storageKey),
              var records = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records.removeValue(forKey: identifier)
        guard let updatedData = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(updatedData, forKey: storageKey)
    }
}

/// PDF 문서별 즐겨찾기 페이지 번호를 저장·복원합니다.
enum PortalPDFFavoritePageStore {
    static let storageKey = "nf.pdf.favorite.pages.v1"

    static func load(
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) -> Set<Int> {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([String: [Int]].self, from: data) else {
            return []
        }
        return Set(records[identifier] ?? [])
    }

    static func save(
        _ pageIndexes: Set<Int>,
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) {
        var records: [String: [Int]] = [:]
        if let data = userDefaults.data(forKey: storageKey),
           let savedRecords = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            records = savedRecords
        }
        if pageIndexes.isEmpty {
            records.removeValue(forKey: identifier)
        } else {
            records[identifier] = pageIndexes.sorted()
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    static func remove(
        for identifier: String,
        userDefaults: UserDefaults = .standard
    ) {
        save([], for: identifier, userDefaults: userDefaults)
    }
}

/**
 PDF 편집 화면에서 사용할 편집 도구입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
