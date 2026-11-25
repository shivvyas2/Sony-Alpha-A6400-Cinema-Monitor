#if !os(macOS)
import SwiftUI
import Photos
import SonyCameraKit

/// Puts every captured JPEG into the Photos library, byte for byte, with add-only permission: the app never reads the library.
@MainActor
@Observable
public final class PhotoSaver {
    public enum Status: Equatable { case saving, saved, denied, failed(String) }
    public private(set) var status: [CapturedImage.ID: Status] = [:]
    /// Remembered across launches; on unless turned off in Settings.
    public var autoSave: Bool = UserDefaults.standard.object(forKey: "savePhotos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "savePhotos") }
    }
    public init() {}

    /// Call whenever the session's shots change; each file is saved once.
    public func sync(_ shots: [CapturedShot]) {
        guard autoSave else { return }
        for image in shots.compactMap(\.jpeg) where status[image.id] == nil { save(image) }
    }

    public func save(_ image: CapturedImage) {
        status[image.id] = .saving
        Task {
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else { status[image.id] = .denied; return }
            do {
                try await Self.add(image)
                status[image.id] = .saved
            } catch {
                status[image.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Photos runs the change block on its own queue, so it must not inherit the main actor.
    private nonisolated static func add(_ image: CapturedImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = image.filename
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = image.takenAt
            request.addResource(with: .photo, fileURL: image.url, options: options)
        }
    }
}

/// "In Photos" mark for the review header; tap to save or retry.
struct PhotoSaveMark: View {
    @Environment(PhotoSaver.self) private var saver
    @Environment(\.openURL) private var openURL
    let image: CapturedImage

    var body: some View {
        switch saver.status[image.id] {
        case .saving: ProgressView().controlSize(.mini)
        case .saved: label("IN PHOTOS", "checkmark", Theme.ok)
        case .denied:
            Button { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } } label: { label("ALLOW PHOTOS", "exclamationmark.triangle", Theme.warn) }.buttonStyle(.plain)
        case .failed:
            Button { saver.save(image) } label: { label("RETRY SAVE", "arrow.clockwise", Theme.warn) }.buttonStyle(.plain)
        case nil:
            Button { saver.save(image) } label: { label("SAVE", "square.and.arrow.down", Theme.text) }.buttonStyle(.plain)
        }
    }

    private func label(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(color).frame(height: 32).contentShape(Rectangle())
    }
}
#endif
