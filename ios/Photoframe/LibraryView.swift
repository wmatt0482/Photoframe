import PhotosUI
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var editing: EditorModel?
    @State private var showingSettings = false
    @State private var loadingPhoto = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(FrameDescription.summary(model.state?.frame))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("frame-status")

                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }

                    if let state = model.state {
                        if state.photos.isEmpty {
                            ContentUnavailableView(
                                "No Photos Yet", systemImage: "photo.on.rectangle",
                                description: Text("Add one and it will appear on the frame the next time it checks in."))
                        } else {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(state.photos) { photo in
                                    NavigationLink(value: photo) {
                                        PhotoCell(photo: photo, badge: badge(for: photo, in: state))
                                    }
                                    .accessibilityIdentifier("photo-\(photo.id)")
                                }
                            }
                            .accessibilityIdentifier("grid")
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("Photoframe")
            .navigationDestination(for: Photo.self) { photo in
                PhotoDetailView(photo: photo)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if loadingPhoto {
                        ProgressView()
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                            Label("Add a Photo", systemImage: "plus")
                        }
                        .disabled(model.state == nil)
                        .accessibilityIdentifier("add-photo")
                    }
                }
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                // Pick up check-ins and other people's uploads, like the web page does.
                if phase == .active { Task { await model.refresh() } }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                Task { await open(item) }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .fullScreenCover(item: $editing) { editor in
                EditorView(editor: editor)
            }
        }
    }

    private func badge(for photo: Photo, in state: LibraryState) -> String? {
        if state.frame?.showing == photo.id { return "On the frame" }
        if state.nextId == photo.id { return "Up next" }
        if photo.shownCount == 0 { return "Waiting" }
        return nil
    }

    private func open(_ item: PhotosPickerItem) async {
        guard let settings = model.state?.settings else { return }
        loadingPhoto = true
        defer { loadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImagePipeline.Failure.unreadableImage
            }
            let image = try await Task.detached(priority: .userInitiated) {
                try ImagePipeline.loadImage(data: data)
            }.value
            let size = try await model.pipeline.viewSize(for: settings.orientation)
            editing = EditorModel(image: image, viewSize: size, pipeline: model.pipeline)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct PhotoCell: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let badge: String?

    var body: some View {
        AsyncImage(url: model.api?.previewURL(photoID: photo.id)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(5 / 3, contentMode: .fit)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityText: String {
        let added = photo.caption.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Photo added \(photo.createdDate.formatted(date: .abbreviated, time: .omitted))"
        return [added, badge].compactMap { $0 }.joined(separator: ", ")
    }
}

enum FrameDescription {
    static func summary(_ frame: FrameStatus?) -> String {
        guard let frame else { return "The frame has not checked in yet." }
        var parts = ["Frame last checked in \(ago(frame.seenDate))"]
        if frame.onUsb == true {
            parts.append("on USB power")
        } else if let pct = frame.batteryPct, pct >= 0 {
            parts.append("battery \(Int(pct))%")
        }
        return parts.joined(separator: ", ") + "."
    }

    static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
