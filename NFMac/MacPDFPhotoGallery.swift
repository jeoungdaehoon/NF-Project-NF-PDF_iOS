import AppKit
import Photos
import SwiftUI

struct MacPDFPhotoGallery: View {
    let onSelect: (NSImage) -> Void
    @State private var items: [Photo] = []
    @State private var message = "사진 보관함 접근을 허용하면 최근 사진을 표시합니다."
    @State private var loading = false
    private struct Photo: Identifiable { let id: String; let asset: PHAsset; let image: NSImage }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("최근 사진 불러오기") { Task { await load() } }.disabled(loading)
            if loading { ProgressView() }
            if items.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))]) {
                ForEach(items) { item in
                    Button {
                        let options = PHImageRequestOptions(); options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
                        PHImageManager.default().requestImageDataAndOrientation(for: item.asset, options: options) { data, _, _, _ in
                            DispatchQueue.main.async { if let data, let image = NSImage(data: data) { onSelect(image) } }
                        }
                    } label: { Image(nsImage: item.image).resizable().scaledToFill().frame(width: 64, height: 64).clipped() }.buttonStyle(.plain).accessibilityLabel("최근 사진 추가")
                }
            }
        }.task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited { await load() }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { message = "사진 접근이 허용되지 않았습니다. 사진 선택 또는 이미지 파일 가져오기를 이용해 주세요."; return }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = 30
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var result: [Photo] = []
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            let image: NSImage? = await withCheckedContinuation { continuation in
                let request = PHImageRequestOptions(); request.deliveryMode = .fastFormat; request.isNetworkAccessAllowed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 128, height: 128), contentMode: .aspectFill, options: request) { image, _ in continuation.resume(returning: image) }
            }
            if let image { result.append(Photo(id: asset.localIdentifier, asset: asset, image: image)) }
        }
        items = result; message = "표시할 최근 사진이 없습니다."
    }
}

/// Native macOS Preview edits a temporary PNG, never the user's original. Apply
/// is explicit and targets the captured object ID, not a changed selection.
struct MacPDFSystemImageEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var parent: MacPDFEditorState
    @State private var workingURL: URL?
    @State private var image: NSImage?
    @State private var message = "미리보기에서 편집 후 저장하고, 이 화면에서 적용하세요."
    private let targetID: UUID?
    init(parent: MacPDFEditorState) { self.parent = parent; targetID = parent.selected?.id }
    var body: some View {
        VStack(spacing: 14) {
            Text("macOS 시스템 이미지 편집").font(.headline)
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(height: 240) }
            Text(message).font(.caption)
            HStack {
                Button("취소") { dismiss() }
                Button("미리보기에서 편집") { openPreview() }.disabled(workingURL == nil)
                Button("편집 결과 적용") { apply() }.disabled(workingURL == nil)
            }
        }.padding(20).task { prepare() }
    }
    private func prepare() {
        guard let object = parent.objects.first(where: { $0.id == targetID }), let data = object.imageData, let source = NSImage(data: data), let tiff = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { message = "선택 이미지를 준비하지 못했습니다."; return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-system-image-edit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("편집 이미지.png"); try png.write(to: url, options: .atomic); workingURL = url; image = source
        } catch { message = error.localizedDescription }
    }
    private func openPreview() {
        guard let workingURL else { return }
        NSWorkspace.shared.open([workingURL], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { if let error { message = error.localizedDescription } }
        }
    }
    private func apply() {
        guard let url = workingURL, let result = NSImage(contentsOf: url), let data = result.tiffRepresentation else { message = "편집된 이미지를 읽지 못했습니다."; return }
        parent.change { if let index = parent.objects.firstIndex(where: { $0.id == targetID }) { parent.objects[index].imageData = data } }
        dismiss()
    }
}
