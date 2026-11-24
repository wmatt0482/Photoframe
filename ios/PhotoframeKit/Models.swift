import Foundation

// Shapes of the JSON the Worker returns (server/src/worker.js, getState).

public enum Orientation: String, Codable, CaseIterable, Sendable {
    case landscape, portrait
}

public enum PhotoOrder: String, Codable, CaseIterable, Sendable {
    case sequential, shuffle
}

public struct FrameSettings: Codable, Equatable, Sendable {
    public var orientation: Orientation
    public var flip: Bool
    /// How often the frame wakes to look for new pictures (5...1440).
    public var checkMinutes: Int
    /// How often it moves on when nothing is new; 0 = never.
    public var rotateMinutes: Int
    public var order: PhotoOrder
}

/// What the frame reported at its last check-in.
public struct FrameStatus: Codable, Equatable, Sendable {
    /// Milliseconds since 1970.
    public var seenAt: Double
    public var batteryMv: Double?
    public var batteryPct: Double?
    public var onUsb: Bool?
    public var rssi: Double?
    public var firmware: String?
    /// Id of the photo on the panel.
    public var showing: String?

    public var seenDate: Date { Date(timeIntervalSince1970: seenAt / 1000) }
}

public struct Photo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Double
    public var caption: String?
    public var source: String?
    public var shownCount: Int
    public var lastShownAt: Double?

    public var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var settings: FrameSettings
    public var frame: FrameStatus?
    public var currentId: String?
    public var nextId: String?
    public var photos: [Photo]
}

public struct UploadedPhoto: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Double
    public var caption: String?
}
