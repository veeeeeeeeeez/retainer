import CryptoKit
import Foundation
import Observation
import os

/// Cloud mode: keeps the notes on this Mac and the account's copy in the
/// cloud the same, in both directions.
///
/// Everything saved is a record: each note, project, canvas and group, as
/// the JSON the index holds for it, and each note's picture as a file in the
/// account's folder of the bucket. The server numbers every change it takes,
/// so "what is new" is "everything after the last number seen".
///
/// The engine remembers, for each record, the version this Mac and the
/// server last agreed on. One round of syncing:
///
/// 1. looks for records that differ from that here (changes made on this
///    Mac, noted with the time they were found);
/// 2. asks the server for what changed there, and fetches the pictures of
///    notes that are new or have a new picture;
/// 3. takes each of the server's changes, unless the same record was changed
///    here more recently, in which case this Mac's version stands;
/// 4. sends this Mac's changes, pictures first, so that no other Mac is ever
///    told of a note whose picture is not there to fetch.
///
/// The later change to a record wins, whole: a card moved on one Mac and
/// reworded on another, between two syncs, keeps only the later of the two.
/// A deletion is a change like any other, kept on the server as a record
/// marked deleted so that every Mac hears of it.
@MainActor
@Observable
public final class CloudSync {

    public enum Status: Equatable {
        case off
        /// Nothing in progress. `lastSynced` says when it last went through.
        case idle
        case syncing
        /// Sending pictures: how many have gone, of how many.
        case sending(Int, of: Int)
        case failed(String)
    }

    public private(set) var status: Status
    public private(set) var lastSynced: Date?

    /// Cloud mode, as switched in the settings. Off until someone turns it on.
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Self.onKey)
            status = isOn ? .idle : .off
            if isOn { lastAttempt = .distantPast }
        }
    }

    /// Called when a note's picture has been replaced by one from the cloud.
    @ObservationIgnored public var onPictureChange: ((UUID) -> Void)?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let account: Account
    @ObservationIgnored private let service: any CloudService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var state = SyncState()
    /// Whose `state` is loaded.
    @ObservationIgnored private var stateUser: String?
    @ObservationIgnored private var running = false
    /// Whether everything on the server has been gone through since launch
    /// (or since someone else signed in).
    @ObservationIgnored private var caughtUp = false
    /// When something saved last changed here, if that has not been synced since.
    @ObservationIgnored private var changedAt: Date?
    @ObservationIgnored private var lastAttempt = Date.distantPast
    /// True while the server's changes are being put into the store: those
    /// are not changes made here.
    @ObservationIgnored private var applying = false
    /// The JSON of each note as last worked out, so that an unchanged note
    /// is not encoded again every round.
    @ObservationIgnored private var encoded: [UUID: (note: Note, json: String)] = [:]
    private static let onKey = "cloudSync"
    private static let log = Logger(subsystem: "blog.terminal.app", category: "cloud")

    /// How long after a change here it is sent, so that a burst goes as one.
    static let settle: TimeInterval = 2
    /// How often the server is asked for other Macs' changes.
    static let interval: TimeInterval = 30

    public init(store: NoteStore, account: Account, service: any CloudService, defaults: UserDefaults = .standard) {
        self.store = store
        self.account = account
        self.service = service
        self.defaults = defaults
        let on = defaults.bool(forKey: Self.onKey)
        isOn = on
        status = on ? .idle : .off
    }

    // MARK: When

    /// Something saved has changed.
    public func storeChanged() {
        if !applying { changedAt = Date() }
    }

    /// Called about once a second: starts a round if one is due.
    public func tick(now: Date = Date()) {
        guard isOn, !running, account.isSignedIn else { return }
        let settled = changedAt.map { now.timeIntervalSince($0) >= Self.settle } ?? false
        guard settled || now.timeIntervalSince(lastAttempt) >= Self.interval else { return }
        Task { await sync() }
    }

    /// One round, now.
    public func sync() async {
        guard isOn, !running, let session = account.session else { return }
        running = true
        defer { running = false }
        changedAt = nil
        lastAttempt = Date()
        if stateUser != session.userID {
            state = SyncState.load(from: stateURL(for: session.userID))
            stateUser = session.userID
            caughtUp = false
        }
        if status != .syncing { status = .syncing }
        do {
            try await round(user: session.userID)
            lastSynced = Date()
            if isOn { status = .idle }
        } catch CloudError.signedOut {
            // The token was turned away. A fresh one may do; if the server
            // has let go of the session altogether, this signs out.
            _ = try? await account.refreshed()
            if isOn { status = account.isSignedIn ? .idle : .failed("signed out") }
            lastAttempt = .distantPast
        } catch {
            Self.log.error("sync failed: \(String(describing: error), privacy: .public)")
            if isOn { status = .failed(Self.explain(error)) }
        }
        state.save(to: stateURL(for: session.userID))
    }

    static func explain(_ error: any Error) -> String {
        if error is URLError { return "no connection" }
        if case CloudError.server(_, let message) = error { return message }
        return "something went wrong"
    }

    private func stateURL(for user: String) -> URL {
        store.directory.appendingPathComponent("cloud-\(user).json")
    }

    // MARK: A round

    private func round(user: String) async throws {
        // Before anything is asked of the network: changes made here are
        // dated by when they are found, online or not.
        scan()
        let token = try await account.token()

        // What changed on the server.
        // The first round after launch asks for everything: numbers are
        // given out before changes are committed, so one could in theory
        // land behind a number already seen. Asking again costs little, and
        // what is already here is passed over.
        var rows: [CloudRecord] = []
        var after = caughtUp ? state.cursor : 0
        while true {
            let page = try await service.pull(after: after, limit: 500, token: token)
            rows += page
            guard page.count == 500, let last = page.last else { break }
            after = last.sequence
        }

        // The pictures first, so a card arrives with its picture. Also any
        // picture that could not be had on an earlier round.
        var wanted: [(id: UUID, blob: String)] = rows.compactMap { row in
            guard row.kind == .note, !row.deleted, let blob = row.blob else { return nil }
            // A picture already agreed on is not fetched again: if the one
            // here differs, it was replaced here, and is on its way out.
            if state.records[row.key]?.blob == blob { return nil }
            return (row.id, blob)
        }
        let arriving = Set(wanted.map(\.id))
        for note in store.notes where !arriving.contains(note.id) {
            if let blob = state.records[CloudRecord.key(.note, note.id)]?.blob,
                !FileManager.default.fileExists(atPath: store.imageURL(for: note).path)
            {
                wanted.append((note.id, blob))
            }
        }
        for (id, blob) in wanted {
            let url = store.directory.appendingPathComponent(NoteStore.imagePath(for: id))
            if await fingerprint(of: id, at: url) == blob { continue }
            do {
                let data = try await service.download(Self.path(user: user, id: id, blob: blob), token: token)
                try await Self.write(data, to: url)
                state.files[id.uuidString] = nil
                onPictureChange?(id)
            } catch CloudError.notFound {
                // Not there (yet): the card comes without it, and it is asked for again next round.
                continue
            }
        }

        // Decide and apply in one go, with what is here as it is this instant.
        scan()
        var changes = RemoteChanges()
        var taken: [(key: String, synced: SyncState.Synced?)] = []
        for row in rows {
            let known = state.records[row.key]
            if row.deleted {
                guard known != nil || state.pending[row.key] != nil else { continue }
            }
            let json = row.deleted ? nil : Self.canonical(row)
            // A record this version cannot read is left for one that can.
            if !row.deleted, json == nil { continue }
            let digest = json.map(Self.digest)
            if digest == known?.digest, row.deleted || row.blob == known?.blob { continue }
            // Changed here too, since both agreed, and later than there: this Mac's stands.
            if known != nil, let mine = state.pending[row.key], mine.at > row.updatedAt { continue }

            switch (row.kind, row.deleted) {
            case (.note, true): changes.deletedNotes.insert(row.id)
            case (.project, true): changes.deletedProjects.insert(row.id)
            case (.canvas, true): changes.deletedCanvases.insert(row.id)
            case (.group, true): changes.deletedGroups.insert(row.id)
            case (.note, false): if let note = Self.note(from: row) { changes.notes.append(note) }
            case (.project, false):
                if let project = Self.decode(Project.self, from: row) { changes.projects.append(project) }
            case (.canvas, false):
                if let canvas = Self.decode(ProjectCanvas.self, from: row) { changes.canvases.append(canvas) }
            case (.group, false):
                if let group = Self.decode(NoteGroup.self, from: row) { changes.groups.append(group) }
            }
            taken.append((row.key, digest.map { SyncState.Synced(digest: $0, blob: row.blob) }))
        }
        applying = true
        store.apply(changes)
        applying = false
        for (key, synced) in taken {
            state.records[key] = synced
            state.pending[key] = nil
        }
        if let last = rows.last { state.cursor = max(state.cursor, last.sequence) }
        caughtUp = true

        try await send(user: user, token: token)
    }

    /// Sends what was changed here.
    private func send(user: String, token: String) async throws {
        let local = scan()
        let saved = store.saved
        var blobs: [UUID: String] = [:]
        for note in saved.notes {
            blobs[note.id] = await fingerprint(of: note.id, at: store.imageURL(for: note))
        }

        var outgoing: [CloudRecord] = []
        var uploads: [(id: UUID, blob: String, url: URL)] = []
        var stale: [String] = []
        for (key, pending) in state.pending {
            guard let (kind, id) = Self.parse(key) else { continue }
            let known = state.records[key]
            guard pending.digest != nil, let json = local[key] else {
                outgoing.append(CloudRecord(kind: kind, id: id, json: Data("{}".utf8), deleted: true))
                if kind == .note, let old = known?.blob { stale.append(Self.path(user: user, id: id, blob: old)) }
                continue
            }
            var blob: String?
            if kind == .note {
                // The picture is still being written: the note goes next round.
                guard let current = blobs[id] else { continue }
                blob = current
                if known?.blob != current {
                    uploads.append((id, current, store.directory.appendingPathComponent(NoteStore.imagePath(for: id))))
                    if let old = known?.blob { stale.append(Self.path(user: user, id: id, blob: old)) }
                }
            }
            outgoing.append(CloudRecord(kind: kind, id: id, json: Data(json.utf8), blob: blob))
        }
        // Notes whose picture was replaced and nothing else.
        for note in saved.notes {
            let key = CloudRecord.key(.note, note.id)
            guard state.pending[key] == nil, let known = state.records[key], let current = blobs[note.id],
                known.blob != current, let json = local[key]
            else { continue }
            uploads.append((note.id, current, store.imageURL(for: note)))
            if let old = known.blob { stale.append(Self.path(user: user, id: note.id, blob: old)) }
            outgoing.append(CloudRecord(kind: .note, id: note.id, json: Data(json.utf8), blob: current))
        }
        guard !outgoing.isEmpty else { return }

        // A batch at a time, each with its pictures first: a long first
        // sync that is cut short has not been for nothing.
        let pictures = Dictionary(uploads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sent = 0
        var start = 0
        while start < outgoing.count {
            var batch = Array(outgoing[start..<min(start + 25, outgoing.count)])
            start += batch.count
            var unready: Set<UUID> = []
            for record in batch where record.kind == .note && !record.deleted {
                guard let upload = pictures[record.id] else { continue }
                if uploads.count > 1, isOn { status = .sending(sent, of: uploads.count) }
                sent += 1
                // Read once: what is sent is what was named.
                guard let data = await Self.read(upload.url), Self.digest(data) == upload.blob else {
                    unready.insert(upload.id)
                    state.files[upload.id.uuidString] = nil
                    continue
                }
                try await service.upload(
                    data, to: Self.path(user: user, id: upload.id, blob: upload.blob), token: token)
            }
            batch.removeAll { $0.kind == .note && unready.contains($0.id) }
            try await service.push(batch, token: token)
            for record in batch {
                let digest = record.deleted ? nil : Self.digest(String(decoding: record.json, as: UTF8.self))
                state.records[record.key] = digest.map { SyncState.Synced(digest: $0, blob: record.blob) }
                // Unless it was changed again while this was on its way.
                if state.pending[record.key]?.digest == digest { state.pending[record.key] = nil }
            }
        }
        if isOn, status != .syncing { status = .syncing }
        // Pictures nothing points at any more. If this fails they are only left over.
        try? await service.remove(stale, token: token)
    }

    // MARK: What changed here

    /// Compares everything saved with what was last agreed with the server,
    /// and notes what differs. Returns the JSON of everything saved, by key.
    @discardableResult
    private func scan(now: Date = Date()) -> [String: String] {
        let saved = store.saved
        var local: [String: String] = [:]
        var fresh: [UUID: (note: Note, json: String)] = [:]
        for note in saved.notes {
            let json = encoded[note.id].flatMap { $0.note == note ? $0.json : nil } ?? Self.canonical(note)
            fresh[note.id] = (note, json)
            local[CloudRecord.key(.note, note.id)] = json
        }
        encoded = fresh
        for project in saved.projects { local[CloudRecord.key(.project, project.id)] = Self.canonical(project) }
        for canvas in saved.canvases { local[CloudRecord.key(.canvas, canvas.id)] = Self.canonical(canvas) }
        for group in saved.groups { local[CloudRecord.key(.group, group.id)] = Self.canonical(group) }

        for (key, json) in local {
            let digest = Self.digest(json)
            if state.records[key]?.digest == digest {
                state.pending[key] = nil
            } else if state.pending[key]?.digest != digest {
                state.pending[key] = SyncState.Pending(digest: digest, at: now)
            }
        }
        for key in state.records.keys where local[key] == nil {
            if state.pending[key] == nil || state.pending[key]?.digest != nil {
                state.pending[key] = SyncState.Pending(digest: nil, at: now)
            }
        }
        // Made and deleted here before the server ever heard of it.
        for key in state.pending.keys where local[key] == nil && state.records[key] == nil {
            state.pending[key] = nil
        }
        return local
    }

    // MARK: Records

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A thing as JSON that is the same whichever Mac wrote it.
    static func canonical(_ value: some Encodable) -> String {
        String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    /// A record from the server, read and written again as this Mac would write it.
    static func canonical(_ row: CloudRecord) -> String? {
        switch row.kind {
        case .note: note(from: row).map { canonical($0) }
        case .project: decode(Project.self, from: row).map { canonical($0) }
        case .canvas: decode(ProjectCanvas.self, from: row).map { canonical($0) }
        case .group: decode(NoteGroup.self, from: row).map { canonical($0) }
        }
    }

    static func decode<T: Decodable & Identifiable>(_ type: T.Type, from row: CloudRecord) -> T? where T.ID == UUID {
        guard let value = try? NoteStore.decoder.decode(type, from: row.json), value.id == row.id else { return nil }
        return value
    }

    static func note(from row: CloudRecord) -> Note? {
        guard var note = decode(Note.self, from: row) else { return nil }
        // Where its picture is kept is this Mac's business, whatever the record says.
        note.imagePath = NoteStore.imagePath(for: note.id)
        return note
    }

    static func parse(_ key: String) -> (CloudRecord.Kind, UUID)? {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = CloudRecord.Kind(rawValue: String(parts[0])),
            let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        return (kind, id)
    }

    nonisolated static func digest(_ text: String) -> String { digest(Data(text.utf8)) }

    /// The first half of a SHA-256, in hex: plenty to tell versions apart.
    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Pictures

    /// Where a version of a note's picture is in the bucket: in the
    /// account's own folder, named for the note and the picture's hash, so a
    /// replaced picture is a new file and never an old one served again.
    static func path(user: String, id: UUID, blob: String) -> String {
        "\(user)/\(id.uuidString.lowercased())-\(blob).png"
    }

    /// The hash of a note's picture as it is on disk, or `nil` if it is not
    /// there. Worked out again only when the file's size or date has changed.
    private func fingerprint(of id: UUID, at url: URL) async -> String? {
        let known = state.files[id.uuidString]
        let mark = await Task.detached(priority: .utility) { () -> SyncState.FileMark? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attributes[.size] as? NSNumber)?.intValue,
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
            else { return nil }
            if let known, known.size == size, known.modified == modified { return known }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return SyncState.FileMark(size: size, modified: modified, digest: Self.digest(data))
        }.value
        state.files[id.uuidString] = mark
        return mark?.digest
    }

    private nonisolated static func read(_ url: URL) async -> Data? {
        await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
    }

    private nonisolated static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }
}

/// What the engine remembers between rounds, kept in a file beside the
/// notes, one for each account that has synced on this Mac.
struct SyncState: Codable, Sendable {

    /// A record as this Mac and the server last agreed on it.
    struct Synced: Codable, Sendable, Equatable {
        var digest: String
        var blob: String?
    }

    /// A change made here and not yet sent. No digest: the record was deleted.
    struct Pending: Codable, Sendable, Equatable {
        var digest: String?
        var at: Date
    }

    /// A picture file as it was when last hashed.
    struct FileMark: Codable, Sendable, Equatable {
        var size: Int
        var modified: Double
        var digest: String
    }

    /// The number of the last server change taken in.
    var cursor: Int64 = 0
    var records: [String: Synced] = [:]
    var pending: [String: Pending] = [:]
    var files: [String: FileMark] = [:]

    static func load(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
