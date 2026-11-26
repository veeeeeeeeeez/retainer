import AppKit
import Foundation

/// `--cloud-check <code> --verifier <secret>`: cloud mode, for real.
///
/// Two stores in temporary folders stand in for two Macs signed in to one
/// account. Notes and pictures go from one to the other through the actual
/// server, are edited and deleted, and everything made is deleted again at
/// the end.
@MainActor
enum CloudCheck {

    @MainActor
    private final class Mac {
        let directory: URL
        let store: NoteStore
        let account: Account
        let sync: CloudSync

        init(named name: String, service: any CloudService, sessionFrom other: Mac? = nil) {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("retainer-cloud-check-\(UUID().uuidString)-\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let other {
                try? FileManager.default.copyItem(
                    at: other.directory.appendingPathComponent("account.json"),
                    to: directory.appendingPathComponent("account.json"))
            }
            let defaults = UserDefaults(suiteName: "retainer-cloud-check-\(name)")!
            defaults.removePersistentDomain(forName: "retainer-cloud-check-\(name)")
            store = NoteStore(directory: directory)
            account = Account(directory: directory, service: service, defaults: defaults) { _ in }
            sync = CloudSync(store: store, account: account, service: service, defaults: defaults)
            sync.isOn = true
        }

        func capture(_ text: String, shade: CGFloat) -> Note {
            let id = UUID()
            let note = Note(
                id: id, imagePath: NoteStore.imagePath(for: id), imagePixelSize: PixelSize(width: 64, height: 48),
                imageScale: 2, note: text, rawTranscript: text, engine: "none", tidy: false, sourceApp: "Cloud check")
            let context = CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: shade, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            try? ImageFiles.writePNG(context.makeImage()!, scale: 2, to: store.imageURL(for: note))
            store.add(note)
            return note
        }

        func picture(_ note: Note) -> Data? { try? Data(contentsOf: store.imageURL(for: note)) }
    }

    static func run(code: String, verifier: String) async -> Bool {
        var failures = 0
        func check(_ what: String, _ passed: Bool) {
            print((passed ? "ok    " : "FAIL  ") + what)
            if !passed { failures += 1 }
        }

        let service = SupabaseService()
        let one = Mac(named: "one", service: service)
        let suite = UserDefaults(suiteName: "retainer-cloud-check-one")!
        suite.set(verifier, forKey: "signInVerifier")
        await one.account.finishSignIn(with: URL(string: "retainer://auth?code=\(code)")!)
        check("the code and its secret become a session (\(one.account.email ?? "no email"))", one.account.isSignedIn)
        guard one.account.isSignedIn else {
            print("      \(one.account.phase)")
            return false
        }
        let two = Mac(named: "two", service: service, sessionFrom: one)
        check("the session is there at the next launch", two.account.isSignedIn)

        let first = one.capture("Cloud check: first.", shade: 0.2)
        let second = one.capture("Cloud check: second.", shade: 0.8)
        let project = one.store.addProject(name: "Cloud check")
        let canvas = one.store.addCanvas(in: project.id, name: "Board")
        if let canvas { one.store.place(noteID: first.id, on: canvas.id, at: CGPoint(x: 12, y: 34)) }
        ImageFiles.waitUntilIdle()

        await one.sync.sync()
        check("the first Mac sends its notes (\(one.sync.status))", one.sync.status == .idle)
        await two.sync.sync()
        check("the second Mac gets them (\(two.sync.status))", two.sync.status == .idle)
        check("both notes arrive", two.store.note(first.id)?.note == first.note && two.store.note(second.id) != nil)
        check("with their pictures, byte for byte", two.picture(first) != nil && two.picture(first) == one.picture(first))
        check("and the project and its canvas", two.store.canvases.first { $0.id == canvas?.id }?.cards.count == 1)

        two.store.updateText(id: first.id, text: "Cloud check: reworded on the second Mac.")
        two.store.delete(id: second.id)
        await two.sync.sync()
        await one.sync.sync()
        check("an edit comes back", one.store.note(first.id)?.note == "Cloud check: reworded on the second Mac.")
        check("a deletion comes back", one.store.note(second.id) == nil)

        // Someone who is not signed in gets nothing.
        let stranger = try? await service.pull(after: 0, limit: 10, token: CloudConfig.standard.key)
        check("the key alone reads nothing", stranger == nil || stranger?.isEmpty == true)

        // Leave the account as it was found.
        one.store.delete(id: first.id)
        one.store.deleteProject(id: project.id)
        await one.sync.sync()
        await two.sync.sync()
        check("cleaned up", two.store.notes.isEmpty && two.store.projects.isEmpty && one.sync.status == .idle)
        for mac in [one, two] {
            mac.store.flush()
            try? FileManager.default.removeItem(at: mac.directory)
        }
        print(failures == 0 ? "cloud check passed" : "cloud check: \(failures) failed")
        return failures == 0
    }
}
