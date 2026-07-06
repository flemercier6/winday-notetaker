import SwiftUI

/// Email + password sign-in / sign-up. Simple and reliable for a desktop app —
/// no magic links, no email round-trip. The session is stored in the Keychain
/// by `SupabaseClient`.
struct SignInView: View {
    @EnvironmentObject private var client: SupabaseClient
    @EnvironmentObject private var model: AppViewModel

    private enum Mode { case signIn, signUp }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    private var title: String { mode == .signIn ? "Sign in" : "Create account" }
    private var canSubmit: Bool { email.contains("@") && password.count >= 6 && !busy }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Winday Notetaker").font(.title2.bold())
            Text("Record and summarize your meetings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("", selection: $mode) {
                Text("Sign in").tag(Mode.signIn)
                Text("Create account").tag(Mode.signUp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            VStack(spacing: 8) {
                TextField("you@company.com", text: $email)
                    .textContentType(.username)
                SecureField("Password (min. 6 characters)", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 260)
            .onSubmit(submit)

            Button(action: submit) {
                Text(busy ? "Please wait…" : title).frame(width: 240)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 300)
            }
        }
        .padding(8)
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true; error = nil
        let email = self.email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                switch mode {
                case .signIn: try await client.signIn(email: email, password: password)
                case .signUp: try await client.signUp(email: email, password: password)
                }
                await model.syncSettings()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
