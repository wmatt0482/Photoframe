import SwiftUI

struct PhotoDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let photo: Photo
    @State private var confirmingDelete = false
    @State private var working = false

    var body: some View {
        List {
            Section {
                AsyncImage(url: model.api?.previewURL(photoID: photo.id)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(photo.caption ?? "Photo")
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(meta)
            }

            Section {
                Button("Show Next", systemImage: "forward") {
                    run { try await $0.showNext(photoID: photo.id) }
                }
                .accessibilityIdentifier("show-next")
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .accessibilityIdentifier("delete")
            } footer: {
                Text("“Show Next” puts this photo on the frame at its next check-in.")
            }
            .disabled(working)
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                run { try await $0.delete(photoID: photo.id) }
            }
        }
    }

    private var meta: String {
        let shown = photo.shownCount == 0
            ? "not shown yet"
            : "shown \(photo.shownCount) time\(photo.shownCount == 1 ? "" : "s")"
        return "Added \(photo.createdDate.formatted(date: .abbreviated, time: .omitted)), \(shown)."
    }

    private func run(_ work: @escaping (PhotoframeAPI) async throws -> Void) {
        working = true
        Task {
            let ok = await model.perform(work)
            working = false
            if ok {
                await model.refresh()
                dismiss()
            }
        }
    }
}
