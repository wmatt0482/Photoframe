import SwiftUI

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var editor: EditorModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CropView(editor: editor)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Drag to move, pinch to zoom. This is how it will look in the frame's six inks.")
                }

                Section {
                    LabeledContent("Zoom") {
                        Slider(value: $editor.geometry.slider, in: 0...1)
                            .accessibilityIdentifier("zoom")
                    }
                    LabeledContent("Contrast") {
                        Slider(value: stepBinding(\.contrastStep), in: range(Adjustments.contrastSteps), step: 1)
                            .accessibilityValue(String(format: "%.2f", editor.adjustments.contrast))
                    }
                    LabeledContent("Colour") {
                        Slider(value: stepBinding(\.saturationStep), in: range(Adjustments.saturationSteps), step: 1)
                            .accessibilityValue(String(format: "%.2f", editor.adjustments.saturation))
                    }
                    Toggle("Show original colours", isOn: $editor.showOriginal)
                }

                if let error = editor.error {
                    Section { Text("Could not send: \(error)").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Position Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(editor.sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editor.sending {
                        ProgressView()
                    } else {
                        Button("Send", action: send)
                            .disabled(editor.preview == nil)
                            .accessibilityLabel("Send to Frame")
                            .accessibilityIdentifier("send")
                    }
                }
            }
            .interactiveDismissDisabled(editor.sending)
        }
    }

    private func stepBinding(_ keyPath: WritableKeyPath<Adjustments, Int>) -> Binding<Double> {
        Binding(
            get: { Double(editor.adjustments[keyPath: keyPath]) },
            set: { editor.adjustments[keyPath: keyPath] = Int($0.rounded()) })
    }

    private func range(_ r: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(r.lowerBound)...Double(r.upperBound)
    }

    private func send() {
        // Packing uses the settings at the time of sending, as on the web page.
        guard let settings = model.state?.settings else { return }
        editor.sending = true
        editor.error = nil
        Task {
            do {
                let upload = try await editor.makeUpload(orientation: settings.orientation, flip: settings.flip)
                guard let api = model.api else { throw APIError.unauthorized }
                _ = try await api.upload(frame: upload.frame, previewJPEG: upload.previewJPEG)
                await model.refresh()
                dismiss()
            } catch APIError.unauthorized {
                dismiss()
                model.signOut(message: APIError.unauthorized.localizedDescription)
            } catch {
                editor.error = error.localizedDescription
            }
            editor.sending = false
        }
    }
}
