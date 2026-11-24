import Foundation
import Observation

/// App-wide state: who we are signed in as and the library the server returned.
@MainActor
@Observable
final class AppModel {
    private(set) var api: PhotoframeAPI?
    private(set) var state: LibraryState?
    var signInMessage: String?
    var errorMessage: String?

    let pipeline = ImagePipeline()
    private let store: CredentialStore

    init(store: CredentialStore = CredentialStore()) {
        self.store = store
        store.migrateLegacyItems()
        // UI tests start from a clean sign-in screen.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            try? store.forgetPassword()
        }
        if let saved = store.load() {
            api = PhotoframeAPI(credentials: saved)
        }
    }

    var isSignedIn: Bool { api != nil }
    var savedServerText: String { store.serverText ?? ServerCredentials.defaultServer }

    func signIn(server: String, password: String) async {
        guard let url = ServerCredentials.parseServer(server) else {
            signInMessage = "Enter the server address, starting with https://"
            return
        }
        let candidate = PhotoframeAPI(credentials: ServerCredentials(serverURL: url, password: password))
        do {
            state = try await candidate.state()
            try store.save(candidate.credentials)
            api = candidate
            signInMessage = nil
        } catch {
            signInMessage = error.localizedDescription
        }
    }

    func signOut(message: String? = nil) {
        try? store.forgetPassword()
        api = nil
        state = nil
        signInMessage = message
    }

    func refresh() async {
        guard let api else { return }
        do {
            state = try await api.state()
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    /// Runs an API call; a 401 sends the person back to sign in, like the web page.
    func perform(_ work: (PhotoframeAPI) async throws -> Void) async -> Bool {
        guard let api else { return false }
        do {
            try await work(api)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func saveSettings(_ settings: FrameSettings) async throws {
        guard let api else { return }
        do {
            let saved = try await api.updateSettings(settings)
            state?.settings = saved
        } catch APIError.unauthorized {
            signOut(message: APIError.unauthorized.localizedDescription)
            throw APIError.unauthorized
        }
    }

    private func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            signOut(message: error.localizedDescription)
        } else if !(error is CancellationError) {
            errorMessage = error.localizedDescription
        }
    }
}
