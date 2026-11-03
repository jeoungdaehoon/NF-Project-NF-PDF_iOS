import AVFoundation
import AVKit
import UIKit

/// Native file streaming avoids the compatibility preview's 64MiB base64 limit.
/// Enhancement creates a disposable local copy, never overwriting the original.
@MainActor
final class PortalMeetingPlayback: UIViewController {
    private let viewer = AVPlayerViewController()
    private var player: AVPlayer? { get { viewer.player } set { viewer.player = newValue } }
    private let source: URL
    private var derived: URL?
    private var preparing = false
    private var closed = false
    init(source: URL) { self.source = source; super.init(nibName: nil, bundle: nil); player = AVPlayer(url: source) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let button = UIButton(type: .system)
        button.setTitle("작은 목소리 보강 · 원본 유지", for: .normal)
        button.setTitleColor(.white, for: .normal); button.backgroundColor = .darkGray; button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(toggleEnhancement(_:)), for: .touchUpInside)
        let dismiss = UIButton(type: .system); dismiss.setTitle("닫기", for: .normal); dismiss.addTarget(self, action: #selector(closePlayback), for: .touchUpInside)
        let toolbar = UIStackView(arrangedSubviews: [button, dismiss]); toolbar.spacing = 12; toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar); addChild(viewer); view.addSubview(viewer.view); viewer.didMove(toParent: self); viewer.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44), dismiss.widthAnchor.constraint(greaterThanOrEqualToConstant: 44), viewer.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8), viewer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), viewer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), viewer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        player?.play()
    }
    @objc private func closePlayback() { close() }
    @objc private func toggleEnhancement(_ button: UIButton) {
        guard !preparing, !closed else { return }
        if player?.currentItem?.asset as? AVURLAsset != nil, let derived, (player?.currentItem?.asset as? AVURLAsset)?.url == derived {
            replace(with: source); button.setTitle("작은 목소리 보강 · 원본 유지", for: .normal); return
        }
        if let derived { replace(with: derived); button.setTitle("원본 음량으로 듣기", for: .normal); return }
        preparing = true; button.isEnabled = false; button.setTitle("단말 보정본 준비 중…", for: .normal)
        let url = source
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) { try PortalMeetingAudioQuality.transcriptionCopy(url) }.value
                guard let self, !self.closed else { try? FileManager.default.removeItem(at: result); return }
                self.derived = result; self.replace(with: result); button.setTitle("원본 음량으로 듣기", for: .normal)
            } catch { button.setTitle("보정 불가 · 원본 재생 유지", for: .normal) }
            self?.preparing = false; button.isEnabled = true
        }
    }
    private func replace(with url: URL) {
        let current = player?.currentTime() ?? .zero
        let time = current.isValid && current.seconds.isFinite ? current : .zero, playing = player?.rate != 0
        player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        player?.seek(to: time)
        if playing { player?.play() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { close() }
    }
    func close() {
        closed = true; player?.pause(); player = nil
        if let derived { try? FileManager.default.removeItem(at: derived); self.derived = nil }
        if presentingViewController != nil { dismiss(animated: true) }
    }
}
