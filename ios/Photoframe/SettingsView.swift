import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FrameSettings?
    @State private var saving = false
    @State private var error: String?

    // Same presets as the web page's selects.
    private static let checkOptions: [(Int, String)] = [
        (15, "Every 15 minutes"), (30, "Every 30 minutes"), (60, "Every hour"),
        (180, "Every 3 hours"), (720, "Every 12 hours"),
    ]
    private static let rotateOptions: [(Int, String)] = [
        (0, "Never"), (60, "Every hour"), (360, "Every 6 hours"), (1440, "Every day"), (10080, "Every week"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($draft) {
                    frameSection
                    pictureSection(binding)
                    scheduleSection(binding)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    LabeledContent("Server", value: model.api?.credentials.serverURL.host() ?? "")
                    Button("Sign Out", role: .destructive) {
                        dismiss()
                        model.signOut()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(draft == nil || draft == model.state?.settings)
                            .accessibilityIdentifier("save-settings")
                    }
                }
            }
            .onAppear { draft = model.state?.settings }
        }
    }

    @ViewBuilder private var frameSection: some View {
        Section("Frame") {
            if let frame = model.state?.frame {
                LabeledContent("Last check-in", value: FrameDescription.ago(frame.seenDate))
                if frame.onUsb == true {
                    LabeledContent("Power", value: "USB")
                }
                if let pct = frame.batteryPct, pct >= 0 {
                    LabeledContent("Battery", value: "\(Int(pct))%")
                }
                if let mv = frame.batteryMv, mv > 0 {
                    LabeledContent("Battery voltage", value: String(format: "%.2f V", mv / 1000))
                }
                if let rssi = frame.rssi {
                    LabeledContent("Wi-Fi signal", value: "\(Int(rssi)) dBm")
                }
                if let fw = frame.firmware, !fw.isEmpty {
                    LabeledContent("Firmware", value: fw)
                }
            } else {
                Text("The frame has not checked in yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func pictureSection(_ s: Binding<FrameSettings>) -> some View {
        Section {
            Picker("Frame orientation", selection: s.orientation) {
                Text("Landscape").tag(Orientation.landscape)
                Text("Portrait").tag(Orientation.portrait)
            }
            Toggle("Pictures appear upside down, flip them", isOn: s.flip)
        } footer: {
            Text("Orientation changes apply to photos you add from now on.")
        }
    }

    private func scheduleSection(_ s: Binding<FrameSettings>) -> some View {
        Section {
            Picker("Check for new photos", selection: s.checkMinutes) {
                ForEach(Self.options(Self.checkOptions, including: s.wrappedValue.checkMinutes), id: \.0) {
                    Text($0.1).tag($0.0)
                }
            }
            Picker("Change picture when nothing is new", selection: s.rotateMinutes) {
                ForEach(Self.options(Self.rotateOptions, including: s.wrappedValue.rotateMinutes), id: \.0) {
                    Text($0.1).tag($0.0)
                }
            }
            Picker("Order", selection: s.order) {
                Text("In turn").tag(PhotoOrder.sequential)
                Text("Shuffle").tag(PhotoOrder.shuffle)
            }
        } footer: {
            Text("Checking more often uses more battery.")
        }
    }

    /// A value set elsewhere may not be a preset; show it so saving does not
    /// silently change it (the web page does the same).
    private static func options(_ presets: [(Int, String)], including value: Int) -> [(Int, String)] {
        presets.contains { $0.0 == value } ? presets : presets + [(value, "Every \(value) minutes")]
    }

    private func save() {
        guard let draft else { return }
        saving = true
        error = nil
        Task {
            do {
                try await model.saveSettings(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
