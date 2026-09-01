//
// NFDesktopCommands.swift
// NF
//
// Mac Catalyst 메뉴와 SwiftUI 화면 사이의 느슨한 명령 연결입니다.
//

import Foundation

extension Notification.Name {
    /// Mac 메뉴에서 네이티브 PDF 문서 라이브러리를 엽니다.
    static let nfDesktopOpenPDFLibrary = Notification.Name("nf.desktop.openPDFLibrary")
    /// Mac 메뉴에서 시스템 PDF 파일 선택기를 엽니다.
    static let nfDesktopImportPDF = Notification.Name("nf.desktop.importPDF")
}
