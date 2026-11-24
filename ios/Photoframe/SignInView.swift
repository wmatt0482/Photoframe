import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var password = ""
    @State private var working = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("server")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($passwordFocused)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                        .accessibilityIdentifier("password")
                } footer: {
                    Text("Enter the password to add pictures.")
                }

                if let message = model.signInMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("sign-in-error")
                    }
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working || password.isEmpty || server.isEmpty)
                    .accessibilityIdentifier("sign-in")
                }
            }
            .navigationTitle("Photoframe")
            .onAppear {
                // A clear button makes replacing the prefilled address one tap.
                UITextField.appearance().clearButtonMode = .whileEditing
                if server.isEmpty { server = model.savedServerText }
                passwordFocused = true
            }
        }
    }

    private func signIn() {
        guard !working, !password.isEmpty else { return }
        working = true
        Task {
            await model.signIn(server: server, password: password)
            working = false
            if model.isSignedIn { password = "" }
        }
    }
}
