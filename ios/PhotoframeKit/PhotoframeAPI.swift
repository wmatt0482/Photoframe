import Foundation

public struct ServerCredentials: Equatable, Sendable {
    public static let defaultServer = "https://photoframe.photoframe-server.workers.dev"

    public var serverURL: URL
    public var password: String

    public init(serverURL: URL, password: String) {
        self.serverURL = serverURL
        self.password = password
    }

    /// Accepts what a person types: trims spaces and a trailing slash, and
    /// insists on http(s) with a host.
    public static func parseServer(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

public enum APIError: LocalizedError, Equatable {
    case unauthorized
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "That password was not accepted."
        case .server(let message): return message
        case .invalidResponse: return "The server sent something unexpected."
        }
    }
}

/// The same HTTP API the web page uses, with the same auth: the upload
/// password as a bearer token.
public struct PhotoframeAPI: Sendable {
    public let credentials: ServerCredentials
    private let session: URLSession

    public init(credentials: ServerCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    public func state() async throws -> LibraryState {
        try await send(request("GET", "/api/state"), as: LibraryState.self)
    }

    public func updateSettings(_ settings: FrameSettings) async throws -> FrameSettings {
        var req = request("PUT", "/api/settings")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(settings)
        return try await send(req, as: FrameSettings.self)
    }

    /// `frame` must be the 192,000 packed bytes; `previewJPEG` the small thumbnail.
    public func upload(frame: Data, previewJPEG: Data, caption: String? = nil) async throws -> UploadedPhoto {
        var form = MultipartForm()
        form.addFile(name: "frame", filename: "frame.bin", type: "application/octet-stream", data: frame)
        form.addFile(name: "preview", filename: "preview.jpg", type: "image/jpeg", data: previewJPEG)
        if let caption, !caption.isEmpty { form.addField(name: "caption", value: caption) }
        var req = request("POST", "/api/photos")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finish()
        return try await send(req, as: UploadedPhoto.self)
    }

    public func delete(photoID: String) async throws {
        _ = try await send(request("DELETE", "/api/photos/\(photoID)"), as: OK.self)
    }

    /// "Show next": the frame shows this photo at its next check-in.
    public func showNext(photoID: String) async throws {
        _ = try await send(request("POST", "/api/photos/\(photoID)/next"), as: OK.self)
    }

    /// Previews need no password (they are protected by the 128-bit id).
    public func previewURL(photoID: String) -> URL {
        url("/api/photos/\(photoID)/preview")
    }

    // MARK: -

    private struct OK: Decodable {}
    private struct ErrorBody: Decodable { var error: String? }

    private func url(_ path: String) -> URL {
        URL(string: credentials.serverURL.absoluteString + path)!
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("Bearer \(credentials.password)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.server(message ?? "Request failed (\(http.statusCode))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}

struct MultipartForm {
    let boundary = "photoframe-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, type: String, data: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(type)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finish() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
