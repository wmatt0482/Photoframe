import CoreGraphics
import Foundation
import Observation

/// The share sheet's one job: show the shared picture cropped for the frame,
/// dithered, and send it. It uses the sign-in the app saved (shared Keychain
/// access group) and never signs in itself.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        /// Nothing usable in the Keychain, or the saved password stopped working.
        case signedOut(String)
        case editing
        case sending
        case sent
        case failed(String)
    }

    static let signInFirst = "Open Photoframe and sign in first."

    private(set) var phase = Phase.loading
    private(set) var editor: EditorModel?
    private(set) var settings: FrameSettings?

    private let pipeline = ImagePipeline()
    private let store: CredentialStore
    private var api: PhotoframeAPI?
    private var items: [NSExtensionItem] = []
    /// true = finished (sent), false = cancelled.
    private let finish: (Bool) -> Void

    init(store: CredentialStore = CredentialStore(), finish: @escaping (Bool) -> Void) {
        self.store = store
        self.finish = finish
    }

    func start(items: [NSExtensionItem]) async {
        self.items = items
        await load()
    }

    private func load() async {
        phase = .loading
        guard let credentials = store.load() else {
            phase = .signedOut(Self.signInFirst)
            return
        }
        let api = PhotoframeAPI(credentials: credentials)
        self.api = api
        do {
            // The picture and the frame's settings are fetched side by side.
            async let image = SharedImageLoader.loadImage(from: items)
            let state = try await api.state()
            let picture = try await image
            let size = try await pipeline.viewSize(for: state.settings.orientation)
            settings = state.settings
            editor = EditorModel(image: picture, viewSize: size, pipeline: pipeline)
            phase = .editing
        } catch APIError.unauthorized {
            phase = .signedOut("Photoframe's saved password was not accepted. Open Photoframe and sign in again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func send() {
        guard let editor, let settings, let api else { return }
        phase = .sending
        Task {
            do {
                // Same defaults as the app's editor: Adjustments() and the
                // server's orientation and flip.
                let upload = try await editor.makeUpload(orientation: settings.orientation, flip: settings.flip)
                _ = try await api.upload(frame: upload.frame, previewJPEG: upload.previewJPEG)
                phase = .sent
                try? await Task.sleep(for: .seconds(1.2))
                finish(true)
            } catch APIError.unauthorized {
                phase = .signedOut("Photoframe's saved password was not accepted. Open Photoframe and sign in again.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// After a failure: send again if the picture is ready, otherwise start over.
    func retry() {
        if editor != nil, settings != nil {
            send()
        } else {
            Task { await load() }
        }
    }

    func cancel() {
        finish(false)
    }
}
