import Foundation
import Testing

@testable import RetainerKit

@Suite("Source links")
struct SourceLinkTests {

    @Test("A browser's page address is kept as it is")
    func webPagesFromBrowsers() {
        #expect(
            SourceLink.accepted("https://www.youtube.com/watch?v=abc123&t=42s", fromBrowser: true)
                == "https://www.youtube.com/watch?v=abc123&t=42s")
        #expect(SourceLink.accepted("http://example.com/", fromBrowser: true) == "http://example.com/")
        #expect(SourceLink.accepted("  https://example.com/a  \n", fromBrowser: true) == "https://example.com/a")
    }

    /// Apps built from web pages (music players, chat apps) report the
    /// address of their own interface, which links to nothing useful.
    @Test("A web address from an app that is not a browser is ignored")
    func webAddressesFromOtherApps() {
        #expect(SourceLink.accepted("https://xpui.app.example.com/index.html", fromBrowser: false) == nil)
        #expect(SourceLink.accepted("tauri://localhost/workspace?id=1", fromBrowser: false) == nil)
        #expect(SourceLink.accepted("tauri://localhost/workspace?id=1", fromBrowser: true) == nil)
    }

    @Test("A document window's file is kept, from any app")
    func files() {
        #expect(
            SourceLink.accepted("file:///Users/someone/Documents/Report%20v2.pdf", fromBrowser: false)
                == "file:///Users/someone/Documents/Report%20v2.pdf")
        // A browser showing a local file.
        #expect(SourceLink.accepted("file:///tmp/page.html", fromBrowser: true) != nil)
    }

    @Test("Things that are not links are dropped")
    func rejects() {
        #expect(SourceLink.accepted(nil, fromBrowser: true) == nil)
        #expect(SourceLink.accepted("", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("   ", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("Untitled", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("about:blank", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("chrome://settings", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("https://", fromBrowser: true) == nil)
        #expect(SourceLink.accepted("file:///", fromBrowser: false) == nil)
        // The inside of an app is not a document.
        #expect(
            SourceLink.accepted(
                "file:///Applications/Example.app/Contents/Resources/app/index.html", fromBrowser: false) == nil)
    }

    @Test("A page is shown without its scheme; a file as a path from the home folder")
    func display() {
        #expect(SourceLink.displayText(for: "https://www.youtube.com/watch?v=abc123") == "youtube.com/watch?v=abc123")
        #expect(SourceLink.displayText(for: "https://example.com/") == "example.com")
        #expect(SourceLink.displayText(for: "http://example.com/a%20b") == "example.com/a b")

        let home = NSHomeDirectory()
        let inHome = URL(fileURLWithPath: home + "/Documents/Report v2.pdf").absoluteString
        #expect(SourceLink.displayText(for: inHome) == "~/Documents/Report v2.pdf")
        #expect(SourceLink.displayText(for: "file:///Volumes/Disk/plan.key") == "/Volumes/Disk/plan.key")

        #expect(SourceLink.isFile(inHome))
        #expect(!SourceLink.isFile("https://example.com"))
    }

}
