import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

/// A server kept in memory: accounts by the code they sign in with, their
/// records numbered as they change, and their pictures.
actor FakeCloud: CloudService {

    private var sequence: Int64 = 0
    private var records: [String: [String: CloudRecord]] = [:]
    private(set) var files: [String: Data] = [:]
    private(set) var pushes = 0
    private(set) var uploads = 0
    /// Added to the clock, to put one Mac's change after another's.
    var ahead: TimeInterval = 0
    var offline = false
    /// Tokens the server no longer takes.
    var withdrawn: Set<String> = []
    private var refreshes = 0

    func set(offline: Bool) { self.offline = offline }
    func set(ahead: TimeInterval) { self.ahead = ahead }
    func withdraw(_ token: String) { withdrawn.insert(token) }
    func recordCount(for user: String) -> Int { records[user]?.values.filter { !$0.deleted }.count ?? 0 }

    private func user(for token: String) throws -> String {
        if offline { throw URLError(.notConnectedToInternet) }
        guard token.hasPrefix("access-"), !withdrawn.contains(token) else { throw CloudError.signedOut }
        return String(token.dropFirst("access-".count).prefix { $0 != "#" })
    }

    func exchange(code: String, verifier: String) async throws -> CloudSession {
        if offline { throw URLError(.notConnectedToInternet) }
        guard code.hasPrefix("code-") else { throw CloudError.server(status: 400, message: "bad code") }
        let user = String(code.dropFirst("code-".count))
        return CloudSession(
            accessToken: "access-\(user)", refreshToken: "refresh-\(user)", expiresAt: Date().addingTimeInterval(3600),
            userID: user, email: "\(user)@example.com")
    }

    func refresh(_ refreshToken: String) async throws -> CloudSession {
        if offline { throw URLError(.notConnectedToInternet) }
        guard refreshToken.hasPrefix("refresh-"), !withdrawn.contains(refreshToken) else { throw CloudError.signedOut }
        let user = String(refreshToken.dropFirst("refresh-".count))
        refreshes += 1
        return CloudSession(
            accessToken: "access-\(user)#\(refreshes)", refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(3600), userID: user, email: nil)
    }

    func signOut(token: String) async {}

    func pull(after sequence: Int64, limit: Int, token: String) async throws -> [CloudRecord] {
        let user = try user(for: token)
        return Array(
            (records[user] ?? [:]).values.filter { $0.sequence > sequence }.sorted { $0.sequence < $1.sequence }
                .prefix(limit))
    }

    func push(_ incoming: [CloudRecord], token: String) async throws {
        let user = try user(for: token)
        pushes += 1
        for var record in incoming {
            sequence += 1
            record.sequence = sequence
            record.updatedAt = Date().addingTimeInterval(ahead)
            records[user, default: [:]][record.key] = record
        }
    }

    func upload(_ data: Data, to path: String, token: String) async throws {
        let user = try user(for: token)
        guard path.hasPrefix(user + "/") else { throw CloudError.server(status: 403, message: "not yours") }
        uploads += 1
        files[path] = data
    }

    func download(_ path: String, token: String) async throws -> Data {
        let user = try user(for: token)
        guard path.hasPrefix(user + "/"), let data = files[path] else { throw CloudError.notFound }
        return data
    }

    func remove(_ paths: [String], token: String) async throws {
        _ = try user(for: token)
        for path in paths { files[path] = nil }
    }
}

/// One Mac: its notes, its account and its sync engine, talking to a `FakeCloud`.
@MainActor
final class FakeMac {
    let directory = NoteStoreTests.temporaryDirectory()
    let defaults: UserDefaults
    let suite = "cloud-tests-\(UUID().uuidString)"
    let store: NoteStore
    let account: Account
    let sync: CloudSync
    var opened: [URL] = []
    var pictureChanges: [UUID] = []

    init(cloud: FakeCloud, site: String = "https://example.com/") {
        defaults = UserDefaults(suiteName: suite)!
        store = NoteStore(directory: directory, calendar: NoteStoreTests.calendar)
        store.undoManager.groupsByEvent = false
        let config = CloudConfig(server: URL(string: "https://server.invalid")!, key: "key", site: URL(string: site)!)
        var open: (URL) -> Void = { _ in }
        account = Account(directory: directory, service: cloud, config: config, defaults: defaults) { open($0) }
        sync = CloudSync(store: store, account: account, service: cloud, defaults: defaults)
        store.onChange = { [sync] in sync.storeChanged() }
        open = { [weak self] url in self?.opened.append(url) }
        sync.onPictureChange = { [weak self] id in self?.pictureChanges.append(id) }
    }

    func signIn(as user: String = "ada") async {
        account.beginSignIn()
        await account.finishSignIn(with: URL(string: "retainer://auth?code=code-\(user)")!)
    }

    /// Does one thing to the store, as one step to undo.
    func step(_ change: () -> Void) {
        store.undoManager.beginUndoGrouping()
        change()
        store.undoManager.endUndoGrouping()
    }

    @discardableResult
    func capture(_ text: String, picture: String = "picture") -> Note {
        let note = NoteStoreTests.sampleNote(text: text, on: Date())
        try! Data(picture.utf8).write(to: store.imageURL(for: note))
        step { store.add(note) }
        return note
    }

    func picture(of note: Note) -> String? {
        (try? Data(contentsOf: store.imageURL(for: note))).map { String(decoding: $0, as: UTF8.self) }
    }

    func cleanUp() {
        store.flush()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Signing in")
@MainActor
struct AccountTests {

    @Test("The challenge is the SHA-256 of the secret, as the standard has it")
    func challenge() {
        // The worked example in RFC 7636, appendix B.
        #expect(
            Account.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = Account.makeVerifier()
        #expect(verifier.count == 43)
        #expect(verifier != Account.makeVerifier())
    }

    @Test("Sign in opens the website with the challenge, and the code that comes back signs in")
    func signIn() async throws {
        let mac = FakeMac(cloud: FakeCloud(), site: "https://example.com/retainer/")
        defer { mac.cleanUp() }
        #expect(!mac.account.isSignedIn)

        mac.account.beginSignIn()
        #expect(mac.account.phase == .waiting)
        let page = try #require(mac.opened.first)
        #expect(page.absoluteString.hasPrefix("https://example.com/retainer/login/?challenge="))
        #expect(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first?.value?.count == 43)

        await mac.account.finishSignIn(with: URL(string: "retainer://auth?code=code-ada")!)
        #expect(mac.account.isSignedIn)
        #expect(mac.account.email == "ada@example.com")
        #expect(mac.account.phase == .idle)
    }

    @Test("The session is kept in a file only its owner can read, and is there at the next launch")
    func kept() async throws {
        let cloud = FakeCloud()
        let mac = FakeMac(cloud: cloud)
        defer { mac.cleanUp() }
        await mac.signIn()

        let file = mac.directory.appendingPathComponent("account.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let again = Account(directory: mac.directory, service: cloud, defaults: mac.defaults) { _ in }
        #expect(again.session == mac.account.session)

        mac.account.signOut()
        #expect(!mac.account.isSignedIn)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A code for a sign-in this Mac did not begin is refused")
    func notBegun() async {
        let mac = FakeMac(cloud: FakeCloud())
        defer { mac.cleanUp() }
        await mac.account.finishSignIn(with: URL(string: "retainer://auth?code=code-eve")!)
        #expect(!mac.account.isSignedIn)
        if case .failed = mac.account.phase {} else { Issue.record("expected a failure, got \(mac.account.phase)") }
        // Nor is anything that is not a sign-in address looked at.
        #expect(!Account.isCallback(URL(string: "https://example.com/auth?code=1")!))
        #expect(Account.isCallback(URL(string: "retainer://auth?code=1")!))
    }

    @Test("A code the server turns down leaves the app signed out, saying so")
    func turnedDown() async {
        let mac = FakeMac(cloud: FakeCloud())
        defer { mac.cleanUp() }
        mac.account.beginSignIn()
        await mac.account.finishSignIn(with: URL(string: "retainer://auth?code=nonsense")!)
        #expect(!mac.account.isSignedIn)
        if case .failed = mac.account.phase {} else { Issue.record("expected a failure, got \(mac.account.phase)") }
    }

    @Test("A session the server has let go of signs the app out; a lost connection does not")
    func refreshing() async throws {
        let cloud = FakeCloud()
        let mac = FakeMac(cloud: cloud)
        defer { mac.cleanUp() }
        await mac.signIn()

        let fresh = try await mac.account.refreshed()
        #expect(fresh.accessToken != "access-ada")
        #expect(fresh.email == "ada@example.com")

        await cloud.set(offline: true)
        await #expect(throws: URLError.self) { try await mac.account.refreshed() }
        #expect(mac.account.isSignedIn)

        await cloud.set(offline: false)
        await cloud.withdraw("refresh-ada")
        await #expect(throws: CloudError.signedOut) { try await mac.account.refreshed() }
        #expect(!mac.account.isSignedIn)
    }

    @Test("The server's answers are read: a session, a record, a failure")
    func parsing() throws {
        let session = try SupabaseService.session(
            from: Data(
                #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"6F1C7B7E-0000-4000-8000-000000000001","email":"a@b.c"}}"#
                    .utf8), now: Date(timeIntervalSince1970: 0))
        #expect(session.userID == "6f1c7b7e-0000-4000-8000-000000000001")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 3600))
        #expect(session.email == "a@b.c")

        let id = UUID()
        let record = try #require(
            SupabaseService.record(from: [
                "kind": "project", "id": id.uuidString.lowercased(), "data": ["name": "Thesis"], "deleted": false,
                "blob": NSNull(), "updated_at": "2026-11-25T17:01:02.123456+00:00", "seq": 42,
            ]))
        #expect(record.id == id)
        #expect(record.sequence == 42)
        #expect(record.blob == nil)
        #expect(record.updatedAt == NoteStoreTests.date(2026, 11, 25, hour: 17, minute: 1).addingTimeInterval(2))

        #expect(SupabaseService.failure(status: 401, body: Data()) == .signedOut)
        #expect(SupabaseService.failure(status: 404, body: Data()) == .notFound)
        #expect(
            SupabaseService.failure(status: 429, body: Data(#"{"msg":"slow down"}"#.utf8))
                == .server(status: 429, message: "slow down"))
    }
}

@Suite("Cloud mode")
@MainActor
struct CloudSyncTests {

    /// Two Macs signed in to one account, both with cloud mode on.
    private func pair() async -> (FakeCloud, FakeMac, FakeMac) {
        let cloud = FakeCloud()
        let one = FakeMac(cloud: cloud)
        let two = FakeMac(cloud: cloud)
        for mac in [one, two] {
            await mac.signIn()
            mac.sync.isOn = true
        }
        return (cloud, one, two)
    }

    @Test("Off until switched on, and then nothing leaves this Mac")
    func off() async {
        let cloud = FakeCloud()
        let mac = FakeMac(cloud: cloud)
        defer { mac.cleanUp() }
        await mac.signIn()
        mac.capture("Stays here.")
        #expect(mac.sync.status == .off)
        await mac.sync.sync()
        #expect(await cloud.pushes == 0)
        #expect(await cloud.uploads == 0)
    }

    @Test("A note and its picture made on one Mac arrive on the other")
    func crosses() async {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = one.capture("The painting of mountains.", picture: "mountains")

        await one.sync.sync()
        #expect(one.sync.status == .idle)
        #expect(await cloud.files.keys.allSatisfy { $0.hasPrefix("ada/") })
        await two.sync.sync()

        let arrived = two.store.note(note.id)
        #expect(arrived?.note == "The painting of mountains.")
        #expect(arrived?.position == note.position)
        #expect(two.picture(of: note) == "mountains")
        // It is not something the second Mac did: there is nothing to undo.
        #expect(!two.store.undoManager.canUndo)
    }

    @Test("Once in step, a round sends and changes nothing")
    func quiet() async {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        one.capture("One.")
        one.capture("Two.")
        await one.sync.sync()
        await two.sync.sync()
        let pushes = await cloud.pushes
        let uploads = await cloud.uploads
        let before = two.store.notes

        await one.sync.sync()
        await two.sync.sync()
        await one.sync.sync()
        #expect(await cloud.pushes == pushes)
        #expect(await cloud.uploads == uploads)
        #expect(two.store.notes == before)
        #expect(two.pictureChanges.count == 2)
    }

    @Test("Edits, moves and archiving go both ways")
    func bothWays() async {
        let (_, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = one.capture("Frist draft.")
        await one.sync.sync()
        await two.sync.sync()

        two.step { two.store.updateText(id: note.id, text: "First draft.") }
        two.step { two.store.move(id: note.id, to: CGPoint(x: 300, y: 40)) }
        await two.sync.sync()
        await one.sync.sync()
        #expect(one.store.note(note.id)?.note == "First draft.")
        #expect(one.store.note(note.id)?.position == CanvasPoint(x: 300, y: 40))

        one.step { one.store.archive(id: note.id) }
        await one.sync.sync()
        await two.sync.sync()
        #expect(two.store.note(note.id)?.isArchived == true)
    }

    @Test("A note deleted on one Mac goes from the other, and its picture from the cloud")
    func deletion() async {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let kept = one.capture("Kept.")
        let gone = one.capture("Gone.", picture: "gone")
        await one.sync.sync()
        await two.sync.sync()
        #expect(await cloud.files.count == 2)

        two.step { two.store.delete(id: gone.id) }
        await two.sync.sync()
        await one.sync.sync()
        #expect(one.store.note(gone.id) == nil)
        #expect(one.store.note(kept.id) != nil)
        #expect(await cloud.files.count == 1)
        #expect(await cloud.recordCount(for: "ada") == 1)

        // Undoing the deletion on the Mac that made it brings it back everywhere.
        two.store.undoManager.undo()
        #expect(two.store.note(gone.id) != nil)
        await two.sync.sync()
        await one.sync.sync()
        #expect(one.store.note(gone.id)?.note == "Gone.")
        #expect(one.picture(of: gone) == "gone")
    }

    @Test("Changed on both Macs between syncs, the later change stands on both")
    func laterWins() async {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = one.capture("Original.")
        await one.sync.sync()
        await two.sync.sync()

        // The first Mac's change is found while it is offline…
        await cloud.set(offline: true)
        one.step { one.store.updateText(id: note.id, text: "From the first Mac, earlier.") }
        await one.sync.sync()
        if case .failed = one.sync.status {} else { Issue.record("expected a failed round, got \(one.sync.status)") }
        // …and the second Mac's is made after it.
        await cloud.set(offline: false)
        await cloud.set(ahead: 60)
        two.step { two.store.updateText(id: note.id, text: "From the second Mac, later.") }
        await two.sync.sync()

        await one.sync.sync()
        #expect(one.store.note(note.id)?.note == "From the second Mac, later.")
        await two.sync.sync()
        #expect(two.store.note(note.id)?.note == "From the second Mac, later.")

        // The other way about: the server's change is the older one.
        await cloud.set(ahead: -60)
        two.step { two.store.updateText(id: note.id, text: "Second Mac, earlier.") }
        await two.sync.sync()
        one.step { one.store.updateText(id: note.id, text: "First Mac, later.") }
        await one.sync.sync()
        await two.sync.sync()
        #expect(one.store.note(note.id)?.note == "First Mac, later.")
        #expect(two.store.note(note.id)?.note == "First Mac, later.")
    }

    @Test("A picture replaced on one Mac replaces it on the other, and the old one leaves the cloud")
    func pictureReplaced() async throws {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = one.capture("A link.", picture: "placeholder")
        await one.sync.sync()
        await two.sync.sync()

        try Data("the page itself".utf8).write(to: one.store.imageURL(for: note))
        await one.sync.sync()
        await two.sync.sync()
        #expect(two.picture(of: note) == "the page itself")
        #expect(two.pictureChanges == [note.id, note.id])
        #expect(await cloud.files.count == 1)
    }

    @Test("A note whose picture is not on disk yet waits for it")
    func waitsForPicture() async throws {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = NoteStoreTests.sampleNote(text: "Still being written.", on: Date())
        one.step { one.store.add(note) }
        await one.sync.sync()
        #expect(await cloud.pushes == 0)

        try Data("now it is".utf8).write(to: one.store.imageURL(for: note))
        await one.sync.sync()
        await two.sync.sync()
        #expect(two.picture(of: note) == "now it is")
    }

    @Test("Projects, canvases and groups cross too")
    func everythingElse() async {
        let (_, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let first = one.capture("First.")
        let second = one.capture("Second.")
        var canvasID: UUID?
        one.step {
            let project = one.store.addProject(name: "Thesis")
            let canvas = one.store.addCanvas(in: project.id, name: "Outline")
            canvasID = canvas?.id
            one.store.place(noteID: first.id, on: canvas!.id, at: CGPoint(x: 5, y: 6))
            one.store.place(noteID: second.id, on: canvas!.id, at: CGPoint(x: 50, y: 6))
            one.store.makeGroup(
                on: Board.canvas(canvas!.id).id, of: [first.id, second.id], at: CGPoint(x: 1, y: 2), name: "Pair")
        }
        await one.sync.sync()
        await two.sync.sync()
        // The same on both, to the second (which is as fine as a saved date goes).
        #expect(CloudSync.canonical(two.store.saved.notes) == CloudSync.canonical(one.store.saved.notes))
        #expect(CloudSync.canonical(two.store.saved.canvases) == CloudSync.canonical(one.store.saved.canvases))
        #expect(CloudSync.canonical(two.store.saved.groups) == CloudSync.canonical(one.store.saved.groups))
        #expect(two.store.projects.map(\.name) == ["Thesis"])
        #expect(two.store.groups.count == 1)

        two.step { two.store.deleteCanvas(id: canvasID!) }
        await two.sync.sync()
        await one.sync.sync()
        #expect(one.store.canvases.isEmpty)
        #expect(one.store.groups.isEmpty)
        #expect(one.store.projects.count == 1)
        #expect(one.store.notes.count == 2)
    }

    @Test("What each Mac had before cloud mode ends up on both")
    func joined() async {
        let cloud = FakeCloud()
        let one = FakeMac(cloud: cloud)
        let two = FakeMac(cloud: cloud)
        defer { one.cleanUp(); two.cleanUp() }
        let here = one.capture("On the first Mac.")
        let there = two.capture("On the second Mac.")
        for mac in [one, two] {
            await mac.signIn()
            mac.sync.isOn = true
        }
        await one.sync.sync()
        await two.sync.sync()
        await one.sync.sync()
        #expect(Set(one.store.notes.map(\.id)) == [here.id, there.id])
        #expect(Set(two.store.notes.map(\.id)) == [here.id, there.id])
        #expect(one.picture(of: there) == "picture")
    }

    @Test("One account's notes are not another's")
    func apart() async {
        let cloud = FakeCloud()
        let ada = FakeMac(cloud: cloud)
        let bob = FakeMac(cloud: cloud)
        defer { ada.cleanUp(); bob.cleanUp() }
        await ada.signIn(as: "ada")
        await bob.signIn(as: "bob")
        ada.sync.isOn = true
        bob.sync.isOn = true
        ada.capture("Ada's.")
        await ada.sync.sync()
        await bob.sync.sync()
        #expect(bob.store.notes.isEmpty)
    }

    @Test("A token the server turns away is replaced, and the next round goes through")
    func tokenTurnedAway() async {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        let note = one.capture("After a new token.")
        await cloud.withdraw("access-ada")
        await one.sync.sync()
        #expect(one.account.isSignedIn)
        await one.sync.sync()
        #expect(one.sync.status == .idle)
        await two.sync.sync()
        await two.sync.sync()
        #expect(two.store.note(note.id) != nil)
    }

    @Test("A round is due a moment after a change, and otherwise every half minute")
    func due() async throws {
        let (cloud, one, two) = await pair()
        defer { one.cleanUp(); two.cleanUp() }
        await one.sync.sync()
        let pushes = await cloud.pushes
        one.capture("Just now.")
        // Too soon: the change has not settled.
        one.sync.tick(now: Date())
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cloud.pushes == pushes)
        one.sync.tick(now: Date().addingTimeInterval(CloudSync.settle + 0.1))
        for _ in 0..<100 where await cloud.pushes == pushes { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await cloud.pushes == pushes + 1)
    }
}
