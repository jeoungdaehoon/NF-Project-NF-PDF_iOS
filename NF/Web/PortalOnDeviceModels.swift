import Foundation
import Speech
import Network
#if canImport(FoundationModels)
import FoundationModels
#endif

/// No cloud model or paid API fallback. Apple owns installation of its
/// Intelligence model; Speech assets can be requested explicitly by the user.
@MainActor
enum PortalOnDeviceModels {
    struct Status {
        var ready: Bool
        var reason: String
        var state: String
    }

    static func summaryStatus() -> Status {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                guard SystemLanguageModel.default.supportsLocale(Locale(identifier: "ko-KR")) else {
                    return Status(ready: false, reason: "이 기기의 Apple Intelligence 모델은 한국어를 지원하지 않습니다.", state: "UNSUPPORTED_LANGUAGE")
                }
                return Status(ready: true, reason: "", state: "AVAILABLE")
            case .unavailable(.deviceNotEligible):
                return Status(ready: false, reason: "이 기기는 Apple Intelligence를 지원하지 않습니다. 녹음·재생과 일반 검색은 사용할 수 있습니다.", state: "UNAVAILABLE")
            case .unavailable(.appleIntelligenceNotEnabled):
                return Status(ready: false, reason: "설정 → Apple Intelligence 및 Siri에서 Apple Intelligence를 켜고 지원 언어를 확인해 주세요.", state: "SETUP_REQUIRED")
            case .unavailable(.modelNotReady):
                return Status(ready: false, reason: "Apple Intelligence 모델이 아직 준비되지 않았습니다. 시스템 설정에서 상태를 확인하고 Wi-Fi·전원을 연결한 뒤 다시 확인해 주세요. NF는 이 모델을 직접 다운로드할 수 없습니다.", state: "MODEL_NOT_READY")
            @unknown default: break
            }
        }
#endif
        return Status(ready: false, reason: "기기 내 AI 검색·요약에는 iOS 26 이상과 한국어를 지원하는 Apple Intelligence가 필요합니다.", state: "UNAVAILABLE")
    }

    static func searchStatus() -> [String: Any] {
        let state = summaryStatus()
        return ["answer": state.ready, "downloadable": false, "reason": state.reason, "state": state.state]
    }

    static func prepareSearch() -> [String: Any] {
        let state = summaryStatus()
#if canImport(FoundationModels)
        if #available(iOS 26.0, *), state.ready {
            LanguageModelSession(model: .default).prewarm()
        }
#endif
        return searchStatus()
    }

    static func prepareSpeech(consent: Bool, progress: @escaping (Int, Int) -> Void) async throws {
        guard consent else { throw failure("한국어 전사 모델 다운로드 동의를 확인해 주세요.") }
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
            throw failure("이 기기는 기본 한국어 전사 모델을 지원하지 않습니다.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        guard await wifiConnected() else { throw failure("전사 모델은 Wi-Fi에 연결한 뒤 준비해 주세요.") }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            guard await AssetInventory.status(forModules: [module]) == .installed else { throw failure("전사 모델 준비 상태를 다시 확인해 주세요.") }
            return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            let fraction = value.fractionCompleted
            guard fraction.isFinite else { return }
            Task { @MainActor in progress(Int(max(0, min(1, fraction)) * 100), 100) }
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw failure("전사 모델 준비가 완료되지 않았습니다.") }
        progress(100, 100)
    }

    private static func wifiConnected() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
            }
            monitor.start(queue: DispatchQueue(label: "nf.speech.model.network"))
        }
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "NFModels", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
