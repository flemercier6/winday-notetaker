import SwiftUI

/// Email one-time-code sign-in. No password, no deep links: Supabase emails a
/// 6-digit code, the user types it back. The resulting session is stored in the
/// Keychain by `SupabaseClient`.
struct SignInView: View {
    @EnvironmentObject private var client: SupabaseClient
    @EnvironmentObject private var model: AppViewModel

    private enum Step { case email, code }
    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Winday Notetaker").font(.title2.bold())
            Text("Sign in to record and summarize your meetings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            switch step {
            case .email:
                TextField("you@company.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button(action: send) {
                    Text(busy ? "Sending…" : "Email me a code")
                        .frame(width: 240)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !email.contains("@"))

            case .code:
                Text("Enter the code sent to \(email)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("123456", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button(action: verify) {
                    Text(busy ? "Verifying…" : "Verify & sign in")
                        .frame(width: 240)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || code.count < 6)
                Button("Use a different email") { step = .email; code = "" }
                    .buttonStyle(.link)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        busy = true; error = nil
        Task {
            do {
                try await client.sendOTP(email: email.trimmingCharacters(in: .whitespaces))
                step = .code
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func verify() {
        busy = true; error = nil
        Task {
            do {
                try await client.verifyOTP(email: email.trimmingCharacters(in: .whitespaces),
                                           code: code.trimmingCharacters(in: .whitespaces))
                await model.syncSettings()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
