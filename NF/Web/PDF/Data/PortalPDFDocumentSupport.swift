//
// PortalPDFDocumentSupport.swift
// NF
//
// Document loading, downloading, save status, and preview errors.
//

import ImageIO
import CoreText
import PDFKit
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UIKit

enum PortalPDFSaveStatus {
    /// 저장 대기 상태입니다.
    case idle
    /// 저장 요청을 서버로 전송 중인 상태입니다.
    case saving
    /// 저장이 정상 완료된 상태입니다.
    case saved
    /// 저장에 실패한 상태입니다.
    case failed

    /// 저장 버튼 상태에 맞춰 표시할 SF Symbol 이름입니다.
    var systemImageName: String {
        switch self {
        case .idle:
            return "square.and.arrow.down"
        case .saving:
            return "arrow.triangle.2.circlepath"
        case .saved:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    /// VoiceOver에서 읽을 저장 버튼 상태 안내 문구입니다.
    var accessibilityLabel: String {
        switch self {
        case .idle:
            return "PDF 편집본 저장"
        case .saving:
            return "PDF 편집본 저장 중"
        case .saved:
            return "PDF 편집본 저장 완료"
        case .failed:
            return "PDF 편집본 저장 실패"
        }
    }
}

/// PDF 저장 API의 응답 상태를 사용자에게 안내하기 위한 오류입니다.
enum PortalPDFSaveError: LocalizedError {
    case httpStatus(Int?, message: String?)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode, let message):
            let serverError: String?
            if let message,
               let data = message.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                serverError = payload["error"] as? String
            } else {
                serverError = nil
            }
            if let serverError, !serverError.isEmpty {
                return serverError
            }
            if let statusCode {
                return "서버가 PDF 저장을 처리하지 못했습니다. (HTTP \(statusCode))"
            }
            return "서버 응답을 확인하지 못했습니다. 네트워크 연결을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

/** 로컬에 없는 PDF를 처음 열 때 설정 상태에 따라 표시하는 안내 유형입니다. */
enum PortalPDFInitialOpenPrompt: String, Identifiable {
    case localStorageEnabled
    case localStorageDisabled

    var id: String { rawValue }
}

/** URLSession 수신 바이트를 실제 다운로드 퍼센트로 전달하는 PDF 전용 Downloader입니다. */
final class PortalPDFProgressDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let progressHandler: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    var receivedData = Data()
    var receivedResponse: URLResponse?
    var expectedContentLength: Int64 = 0
    var dataTask: URLSessionDataTask?
    var session: URLSession?

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.default
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.dataTask = task
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.dataTask?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        receivedResponse = response
        expectedContentLength = response.expectedContentLength
        if expectedContentLength > 0, expectedContentLength <= Int64(Int.max) {
            receivedData.reserveCapacity(Int(expectedContentLength))
        }
        progressHandler(0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        guard expectedContentLength > 0 else { return }
        let progress = min(1, Double(receivedData.count) / Double(expectedContentLength))
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
            dataTask = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let receivedResponse else {
            continuation?.resume(throwing: PortalPDFPreviewError.downloadFailed)
            return
        }
        progressHandler(1)
        continuation?.resume(returning: (receivedData, receivedResponse))
    }
}

enum PortalPDFPreviewLoadState {
    /// PDF 파일을 다운로드하거나 확인 중인 상태입니다.
    case loading
    /// PDFKit에서 표시 가능한 문서가 준비된 상태입니다.
    case loaded(PDFDocument)
    /// PDF로 열 수 없거나 다운로드에 실패한 상태입니다.
    case failed(String)
}

/**
 PDF 내부 미리보기 실패 유형입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``
 */
enum PortalPDFPreviewError: LocalizedError {
    /// 첨부 파일 다운로드가 실패한 상태입니다.
    case downloadFailed
    /// PDF가 아닌 파일이 선택된 상태입니다.
    case unsupportedFile
    /// PDFKit이 문서를 해석하지 못한 상태입니다.
    case invalidPDF
    /// 편집된 PDF 저장 요청이 실패한 상태입니다.
    case saveFailed
    /// PDF를 로컬 저장소에 기록하거나 다시 읽지 못한 상태입니다.
    case localSaveFailed

    /// 사용자에게 표시할 오류 문구입니다.
    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "첨부 파일 다운로드에 실패했습니다."
        case .unsupportedFile:
            return "PDFView에서 지원하지 않는 파일 형식입니다."
        case .invalidPDF:
            return "PDF 문서가 손상되었거나 표시할 수 없습니다."
        case .saveFailed:
            return "PDF 편집본 저장에 실패했습니다."
        case .localSaveFailed:
            return "PDF를 기기에 저장하지 못했습니다. 저장 공간을 확인한 뒤 다시 시도해 주세요."
        }
    }
}


/// 이미지와 박스 도형이 공유하는 이동·크기·회전 편집 규약입니다.
