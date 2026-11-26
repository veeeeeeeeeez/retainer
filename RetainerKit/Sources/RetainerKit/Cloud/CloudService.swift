import Foundation

/// Being signed in: the tokens, and who they are for.
public struct CloudSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// When the access token stops working. The refresh token gets another.
    public var expiresAt: Date
    /// The account's id, as the server writes it (a lowercase UUID).
    public var userID: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

/// One thing kept in the cloud: a note, a project, a canvas or a group.
public struct CloudRecord: Sendable, Equatable {

    public enum Kind: String, Sendable, CaseIterable {
        case note, project, canvas, group
    }

    public var kind: Kind
    public var id: UUID
    /// The thing itself, as JSON. Empty once it has been deleted.
    public var json: Data
    /// Deleted: the record stays, so that every Mac hears of it.
    public var deleted: Bool
    /// Which version of a note's picture goes with it (a hash of the file).
    public var blob: String?
    /// When the server last took a change to it.
    public var updatedAt: Date
    /// The server's count of changes: every change gets the next number.
    public var sequence: Int64

    public init(
        kind: Kind, id: UUID, json: Data, deleted: Bool = false, blob: String? = nil, updatedAt: Date = Date(),
        sequence: Int64 = 0
    ) {
        self.kind = kind
        self.id = id
        self.json = json
        self.deleted = deleted
        self.blob = blob
        self.updatedAt = updatedAt
        self.sequence = sequence
    }

    public var key: String { Self.key(kind, id) }

    public static func key(_ kind: Kind, _ id: UUID) -> String { "\(kind.rawValue):\(id.uuidString)" }
}

public enum CloudError: Error, Equatable, LocalizedError {
    /// The server said no to the session: signing in again is the only way on.
    case signedOut
    /// The server answered, but not with what was asked for.
    case server(status: Int, message: String)
    /// What came back could not be read.
    case unreadable
    case notFound

    public var errorDescription: String? {
        switch self {
        case .signedOut: "signed out"
        case .server(_, let message): message
        case .unreadable: "the server's answer could not be read"
        case .notFound: "not found"
        }
    }
}

/// Everything the app asks of the server. The app's own is `SupabaseService`;
/// tests have one that keeps everything in memory.
public protocol CloudService: Sendable {
    /// Turns the one-time code sign-in ended with into a session. `verifier`
    /// is the secret whose hash went out with the sign-in.
    func exchange(code: String, verifier: String) async throws -> CloudSession
    func refresh(_ refreshToken: String) async throws -> CloudSession
    func signOut(token: String) async

    /// The account's records changed since `sequence`, oldest change first.
    func pull(after sequence: Int64, limit: Int, token: String) async throws -> [CloudRecord]
    /// Writes records, replacing those already there.
    func push(_ records: [CloudRecord], token: String) async throws

    func upload(_ data: Data, to path: String, token: String) async throws
    func download(_ path: String, token: String) async throws -> Data
    func remove(_ paths: [String], token: String) async throws
}

/// The Supabase project, over plain HTTPS: its sign-in service, its table of
/// records and its bucket of pictures.
public struct SupabaseService: CloudService {

    public static let table = "records"
    public static let bucket = "images"

    private let config: CloudConfig
    private let session: URLSession

    public init(config: CloudConfig = .standard) {
        self.config = config
        // Nothing is kept on disk: a picture replaced in the cloud must not
        // come back as the one before it.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Requests

    private func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [], token: String? = nil,
        headers: [String: String] = [:], body: Data? = nil, type: String = "application/json"
    ) -> URLRequest {
        var parts = URLComponents(url: config.server, resolvingAgainstBaseURL: false)!
        parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: data)
        }
        return data
    }

    static func failure(status: Int, body: Data) -> CloudError {
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let message =
            ["msg", "error_description", "message", "error"].lazy.compactMap { fields[$0] as? String }.first
            ?? "the server answered \(status)"
        // An expired or withdrawn session, from the table and the bucket alike.
        if status == 401 || (status == 403 && message.localizedCaseInsensitiveContains("jwt")) {
            return .signedOut
        }
        if status == 404 || (status == 400 && message.localizedCaseInsensitiveContains("not found")) {
            return .notFound
        }
        return .server(status: status, message: message)
    }

    // MARK: Sign-in

    public func exchange(code: String, verifier: String) async throws -> CloudSession {
        let body = try JSONSerialization.data(withJSONObject: ["auth_code": code, "code_verifier": verifier])
        let data = try await send(
            request("POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "pkce")], body: body))
        return try Self.session(from: data)
    }

    public func refresh(_ refreshToken: String) async throws -> CloudSession {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        do {
            let data = try await send(
                request(
                    "POST", "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                    body: body))
            return try Self.session(from: data)
        } catch CloudError.server(let status, _) where status == 400 || status == 403 {
            // The refresh token has been used up or withdrawn.
            throw CloudError.signedOut
        }
    }

    public func signOut(token: String) async {
        // This Mac's session only; others stay signed in.
        _ = try? await send(
            request("POST", "/auth/v1/logout", query: [URLQueryItem(name: "scope", value: "local")], token: token))
    }

    static func session(from data: Data, now: Date = Date()) throws -> CloudSession {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = fields["access_token"] as? String, let refresh = fields["refresh_token"] as? String,
            let user = fields["user"] as? [String: Any], let id = user["id"] as? String
        else { throw CloudError.unreadable }
        let seconds = (fields["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return CloudSession(
            accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(seconds),
            userID: id.lowercased(), email: user["email"] as? String)
    }

    // MARK: Records

    public func pull(after sequence: Int64, limit: Int, token: String) async throws -> [CloudRecord] {
        let data = try await send(
            request(
                "GET", "/rest/v1/\(Self.table)",
                query: [
                    URLQueryItem(name: "select", value: "kind,id,data,deleted,blob,updated_at,seq"),
                    URLQueryItem(name: "seq", value: "gt.\(sequence)"),
                    URLQueryItem(name: "order", value: "seq.asc"),
                    URLQueryItem(name: "limit", value: String(limit)),
                ], token: token))
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CloudError.unreadable
        }
        return rows.compactMap(Self.record(from:))
    }

    static func record(from row: [String: Any]) -> CloudRecord? {
        guard let kind = (row["kind"] as? String).flatMap(CloudRecord.Kind.init(rawValue:)),
            let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
            let sequence = (row["seq"] as? NSNumber)?.int64Value
        else { return nil }
        let content = row["data"] as? [String: Any] ?? [:]
        return CloudRecord(
            kind: kind, id: id, json: (try? JSONSerialization.data(withJSONObject: content)) ?? Data("{}".utf8),
            deleted: row["deleted"] as? Bool ?? false, blob: row["blob"] as? String,
            updatedAt: (row["updated_at"] as? String).flatMap(Self.date(from:)) ?? .distantPast, sequence: sequence)
    }

    /// Reads the server's timestamps ("2026-11-25T17:01:02.123456+00:00"), to the second.
    static func date(from text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }

    public func push(_ records: [CloudRecord], token: String) async throws {
        guard !records.isEmpty else { return }
        let rows: [[String: Any]] = records.map { record in
            [
                "kind": record.kind.rawValue,
                "id": record.id.uuidString.lowercased(),
                "data": (try? JSONSerialization.jsonObject(with: record.json)) ?? [String: Any](),
                "deleted": record.deleted,
                "blob": record.blob ?? NSNull(),
            ]
        }
        try await send(
            request(
                "POST", "/rest/v1/\(Self.table)",
                query: [URLQueryItem(name: "on_conflict", value: "user_id,kind,id")], token: token,
                headers: ["Prefer": "resolution=merge-duplicates,return=minimal"],
                body: try JSONSerialization.data(withJSONObject: rows)))
    }

    // MARK: Pictures

    public func upload(_ data: Data, to path: String, token: String) async throws {
        try await send(
            request(
                "POST", "/storage/v1/object/\(Self.bucket)/\(path)", token: token, headers: ["x-upsert": "true"],
                body: data, type: "image/png"))
    }

    public func download(_ path: String, token: String) async throws -> Data {
        try await send(request("GET", "/storage/v1/object/authenticated/\(Self.bucket)/\(path)", token: token))
    }

    public func remove(_ paths: [String], token: String) async throws {
        guard !paths.isEmpty else { return }
        try await send(
            request(
                "DELETE", "/storage/v1/object/\(Self.bucket)", token: token,
                body: try JSONSerialization.data(withJSONObject: ["prefixes": paths])))
    }
}
