import SwiftUI
import UIKit

/// Principal class of the share extension (NSExtensionPrincipalClass in
/// Config/PhotoframeShare-Info.plist). It only hosts the SwiftUI view and
/// reports back to the share sheet.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel { [weak self] sent in
            guard let context = self?.extensionContext else { return }
            if sent {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.start(items: items) }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Photoframe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.phase != .sent {
                            Button("Cancel", action: model.cancel)
                                .disabled(model.phase == .sending)
                                .accessibilityIdentifier("share-cancel")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Preparing the picture...")
        case .signedOut(let text):
            message(text, systemImage: "person.crop.circle.badge.exclamationmark") {
                Button("Close", action: model.cancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("share-close")
            }
        case .editing, .sending:
            editing
        case .sent:
            message("Sent. The frame shows it at its next check-in.", systemImage: "checkmark.circle.fill") {}
        case .failed(let error):
            message("Could not send: \(error)", systemImage: "exclamationmark.triangle") {
                HStack {
                    Button("Cancel", action: model.cancel)
                        .buttonStyle(.bordered)
                    Button("Try Again", action: model.retry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("share-retry")
                }
            }
        }
    }

    @ViewBuilder
    private var editing: some View {
        if let editor = model.editor {
            VStack(spacing: 16) {
                CropView(editor: editor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(model.phase == .sending)
                Text("Drag to move, pinch to zoom. This is how it will look in the frame's six inks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                if model.phase == .sending {
                    ProgressView("Sending...")
                        .accessibilityIdentifier("share-sending")
                } else {
                    Button(action: model.send) {
                        Text("Send to frame").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(editor.preview == nil)
                    .accessibilityIdentifier("share-send")
                }
            }
        }
    }

    private func message<Actions: View>(_ text: String, systemImage: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("share-status")
            actions()
        }
    }
}
