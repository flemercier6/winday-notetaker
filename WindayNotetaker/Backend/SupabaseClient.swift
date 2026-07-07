import Foundation
import Combine

/// Thin Supabase REST client: email-OTP auth, Storage upload, and Edge Function
/// invocation. No third-party secrets ever pass through here — the functions
/// hold those server-side.
@MainActor
final class SupabaseClient: ObservableObject {
    struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userId: String
        let email: String?
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case notAuthenticated
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Supabase URL/key missing from the app build."
            case .notAuthenticated: return "You need to sign in first."
            case let .http(code, body): return "Request failed (HTTP \(code)): \(body)"
            }
        }
    }

    static let shared = SupabaseClient()

    @Published private(set) var session: Session?

    private let baseURL: URL
    private let anonKey: String
    private let urlSession = URLSession.shared

    var isAuthenticated: Bool { session != nil }
    var userId: String? { session?.userId }
    var email: String? { session?.email }

    init(config: Config = .shared) {
        self.baseURL = URL(string: config.supabaseURL) ?? URL(string: "https://invalid.invalid")!
        self.anonKey = config.supabaseAnonKey
        self.session = Self.loadSession()
    }

    // MARK: - Auth (email + password)

    /// Creates an account. If email confirmation is disabled on the project
    /// (recommended for this desktop app), the response includes a session and
    /// the user is signed in immediately.
    func signUp(email: String, password: String) async throws {
        let data = try await request(
            path: "/auth/v1/signup",
            body: ["email": email, "password": password],
            authenticated: false
        )
        try storeSession(
            from: data,
            fallback: "Account created, but email confirmation is on. Disable it in Supabase (Authentication → Providers → Email → Confirm email) or confirm via the email, then sign in."
        )
    }

    /// Signs in with email + password.
    func signIn(email: String, password: String) async throws {
        let data = try await request(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": email, "password": password],
            authenticated: false
        )
        try storeSession(from: data, fallback: "Sign-in failed — check your email and password.")
    }

    /// Decodes a session from a GoTrue auth response and persists it. Throws a
    /// friendly error when the response carries no token (e.g. confirmation on).
    private func storeSession(from data: Data, fallback: String) throws {
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty else {
            throw ClientError.http(200, fallback)
        }
        let session = Session(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
            userId: token.user.id,
            email: token.user.email
        )
        self.session = session
        Self.saveSession(session)
    }

    func signOut() {
        session = nil
        Self.saveSession(nil)
    }

    private func refreshIfNeeded() async throws {
        guard let current = session else { throw ClientError.notAuthenticated }
        guard current.expiresAt.timeIntervalSinceNow < 60 else { return }

        let data = try await request(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": current.refreshToken],
            authenticated: false
        )
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let refreshed = Session(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
            userId: token.user.id,
            email: token.user.email
        )
        self.session = refreshed
        Self.saveSession(refreshed)
    }

    // MARK: - Storage

    /// Uploads a local file to the private `recordings` bucket at `path`
    /// (e.g. "<userId>/<meetingId>.caf").
    func uploadRecording(fileURL: URL, to path: String) async throws {
        try await refreshIfNeeded()
        guard let token = session?.accessToken else { throw ClientError.notAuthenticated }

        let url = endpoint("/storage/v1/object/recordings/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")

        let fileData = try Data(contentsOf: fileURL)
        let (data, response) = try await urlSession.upload(for: req, from: fileData)
        try Self.check(response, data)
    }

    // MARK: - Database (PostgREST)

    /// Inserts a meeting row so the Edge Functions can read its audio + write back.
    /// Writes to the Winday CRM's shared `meetings` table (non-secret per-user
    /// prefs like models / Notion db id are passed to the functions per request,
    /// so there's no separate settings table).
    func insertMeeting(_ payload: [String: Any]) async throws {
        try await postREST(path: "/rest/v1/meetings", body: payload, prefer: "return=minimal")
    }

    private func postREST(path: String, body: [String: Any], prefer: String) async throws {
        try await refreshIfNeeded()
        guard let token = session?.accessToken else { throw ClientError.notAuthenticated }

        let url = endpoint(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(prefer, forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        try Self.check(response, data)
    }

    // MARK: - Edge Functions

    /// Invokes an Edge Function and decodes its JSON response into `T`.
    func invoke<T: Decodable>(_ name: String, body: [String: Any], as type: T.Type) async throws -> T {
        let data = try await invokeRaw(name, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func invokeRaw(_ name: String, body: [String: Any]) async throws -> Data {
        try await refreshIfNeeded()
        guard let token = session?.accessToken else { throw ClientError.notAuthenticated }

        let url = endpoint("/functions/v1/\(name)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, response) = try await urlSession.data(for: req)
        try Self.check(response, data)
        return data
    }

    // MARK: - Low-level request (auth endpoints)

    @discardableResult
    private func request(path: String, body: [String: Any], authenticated: Bool) async throws -> Data {
        guard !anonKey.isEmpty else { throw ClientError.notConfigured }
        let url = endpoint(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = session?.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        try Self.check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Surface the function's {"error": "..."} message when present.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = obj["error"] as? String ?? obj["msg"] as? String ?? obj["message"] as? String {
                throw ClientError.http(http.statusCode, message)
            }
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Builds a full endpoint URL by plain concatenation. We deliberately avoid
    /// `URL.appendingPathComponent`, which percent-encodes "?" and thus breaks
    /// query strings like `?grant_type=refresh_token` (→ 404).
    private func endpoint(_ path: String) -> URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }

    // MARK: - Session persistence (Keychain)

    private static let sessionKey = "supabase_session"

    private static func saveSession(_ session: Session?) {
        guard let session, let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8) else {
            Keychain.set(nil, for: sessionKey)
            return
        }
        Keychain.set(json, for: sessionKey)
    }

    private static func loadSession() -> Session? {
        guard let json = Keychain.get(sessionKey), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    // Supabase GoTrue token response.
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let user: User
        struct User: Decodable { let id: String; let email: String? }
    }
}
