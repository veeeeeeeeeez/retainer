import AppKit
import CryptoKit
import Foundation
import Observation
import os

/// Who is signed in on this Mac, and how they got there.
///
/// Signing in happens on the website, in the browser, where the person's
/// Google account and email already are. The app sends them there with the
/// hash of a secret it has just made up; the website sends them back with a
/// one-time code (`retainer://auth?code=…`); the code and the secret
/// together become a session. A code caught by anything else on the way is
/// worth nothing without the secret, which never leaves the app.
///
/// The session is kept in a file only this user can read, beside the notes.
/// (Not the keychain: a downloaded build is signed afresh every release, and
/// the keychain would ask for the Mac's password after each update.)
@MainActor
@Observable
public final class Account {

    public enum Phase: Equatable {
        case idle
        /// The browser has been opened; the app is waiting to be called back.
        case waiting
        /// The code has come back and is being turned into a session.
        case finishing
        case failed(String)
    }

    public private(set) var session: CloudSession?
    public private(set) var phase: Phase = .idle

    public var isSignedIn: Bool { session != nil }
    public var email: String? { session?.email }

    /// Called when someone has just signed in, or been signed out.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let service: any CloudService
    @ObservationIgnored private let config: CloudConfig
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private var refreshing: Task<CloudSession, any Error>?
    private static let verifierKey = "signInVerifier"
    private static let log = Logger(subsystem: "blog.terminal.app", category: "account")

    public init(
        directory: URL, service: any CloudService, config: CloudConfig = .standard,
        defaults: UserDefaults = .standard, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.service = service
        self.config = config
        self.defaults = defaults
        self.open = open
        fileURL = directory.appendingPathComponent("account.json")
        if let data = try? Data(contentsOf: fileURL) {
            session = try? Self.decoder.decode(CloudSession.self, from: data)
        }
    }

    // MARK: Signing in

    /// Opens the website's sign-in page in the browser.
    public func beginSignIn() {
        let verifier = Self.makeVerifier()
        // Kept across a quit: the browser may bring the app back from cold.
        defaults.set(verifier, forKey: Self.verifierKey)
        phase = .waiting
        open(config.signInPage(challenge: Self.challenge(for: verifier)))
    }

    /// Stops waiting for the browser.
    public func cancelSignIn() {
        guard phase != .finishing else { return }
        phase = .idle
    }

    /// Whether an address the app was opened with is the end of a sign-in.
    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == CloudConfig.callbackScheme && url.host?.lowercased() == "auth"
    }

    /// Finishes a sign-in from the address the browser opened the app with.
    public func finishSignIn(with url: URL) async {
        guard Self.isCallback(url) else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            phase = .failed("That sign-in link had nothing in it. Try again.")
            return
        }
        guard let verifier = defaults.string(forKey: Self.verifierKey) else {
            // Not a sign-in this copy of the app began.
            if !isSignedIn { phase = .failed("That sign-in was started somewhere else. Try again from here.") }
            return
        }
        phase = .finishing
        do {
            let session = try await service.exchange(code: code, verifier: verifier)
            defaults.removeObject(forKey: Self.verifierKey)
            keep(session)
            phase = .idle
            onChange?()
        } catch {
            Self.log.error("sign-in failed: \(String(describing: error), privacy: .public)")
            phase = .failed(Self.explain(error))
        }
    }

    static func explain(_ error: any Error) -> String {
        if error is URLError { return "Couldn’t reach the server. Check the connection and try again." }
        return "That sign-in didn’t go through. Try again."
    }

    // MARK: Signed in

    /// A token the server will take right now, refreshed first if it is about to lapse.
    public func token() async throws -> String {
        guard let session else { throw CloudError.signedOut }
        if session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        return try await refreshed().accessToken
    }

    /// Gets a new session with the refresh token. Asked for twice at once, it is done once.
    @discardableResult
    public func refreshed() async throws -> CloudSession {
        if let refreshing { return try await refreshing.value }
        guard let session else { throw CloudError.signedOut }
        let service = self.service
        let task = Task { try await service.refresh(session.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            var fresh = try await task.value
            if fresh.email == nil { fresh.email = session.email }
            // Signed out, or in as someone else, while this was on its way.
            guard self.session?.userID == session.userID else { throw CloudError.signedOut }
            keep(fresh)
            return fresh
        } catch CloudError.signedOut {
            // The server no longer knows the session: there is nothing to keep.
            forget()
            throw CloudError.signedOut
        }
    }

    public func signOut() {
        guard let session else { return }
        let service = self.service
        Task { await service.signOut(token: session.accessToken) }
        forget()
    }

    private func forget() {
        guard session != nil else { return }
        session = nil
        try? FileManager.default.removeItem(at: fileURL)
        phase = .idle
        onChange?()
    }

    private func keep(_ session: CloudSession) {
        self.session = session
        do {
            let data = try Self.encoder.encode(session)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Made closed, then filled: never readable by anyone else, even for a moment.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try data.write(to: fileURL, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.log.error("session not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    // MARK: The secret and its hash

    /// 32 random bytes, as 43 URL-safe characters.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// What goes out with the sign-in: the SHA-256 of the secret.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
