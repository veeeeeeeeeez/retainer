import AppKit
import CoreImage
import WebKit

/// A picture of a web page, for the card of a link that was pasted in.
///
/// This loads the page, which is the one place the app reaches the network
/// besides fetching the speech model: only for a link the user has pasted,
/// only that page, in a web view that keeps nothing afterwards.
@MainActor
final class WebSnapshot: NSObject, WKNavigationDelegate {

    /// The size of the window the page is laid out in, in points.
    static let viewport = CGSize(width: 1280, height: 800)

    private var webView: WKWebView?
    private var finished: CheckedContinuation<Bool, Never>?

    /// Loads `url` out of sight and returns what the top of the page looks
    /// like, or `nil` if it did not load in time.
    static func capture(_ url: URL) async -> CGImage? {
        await WebSnapshot().run(url)
    }

    private func run(_ url: URL) async -> CGImage? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.viewport), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        defer { webView = nil }

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            finished = continuation
            view.load(URLRequest(url: url, timeoutInterval: 15))
            // A page that never says it has finished is given up on.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(18))
                self?.finish(false)
            }
        }
        guard loaded else { return nil }
        // A moment for pictures and fonts to arrive after the page says it is done.
        try? await Task.sleep(for: .milliseconds(900))

        let wanted = WKSnapshotConfiguration()
        wanted.rect = CGRect(origin: .zero, size: Self.viewport)
        let image = try? await view.takeSnapshot(configuration: wanted)
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func finish(_ loaded: Bool) {
        finished?.resume(returning: loaded)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) { finish(false) }
}

extension LinkCard {

    /// A page's picture made into a link's card: softened and dimmed a
    /// little, so that the link sign in its top left corner is what is seen
    /// first and the page behind says where it goes.
    static func compose(page: CGImage) -> CapturedImage? {
        let width = page.width
        let height = page.height
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        // Pixels per point, taking the page as the snapshot's 1280 points wide.
        let unit = CGFloat(width) / WebSnapshot.viewport.width

        // The page, slightly out of focus.
        let soft = CIImage(cgImage: page).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(2.2 * unit))
            .cropped(to: whole)
        let blurred = CIContext().createCGImage(soft, from: whole) ?? page
        context.draw(blurred, in: whole)
        context.setFillColor(CGColor(gray: 0, alpha: 0.3))
        context.fill(whole)

        // The link sign: a dark glass tile in the top left corner.
        let side = 92 * unit
        let tile = CGRect(x: 36 * unit, y: CGFloat(height) - 36 * unit - side, width: side, height: side)
        let shape = CGPath(roundedRect: tile, cornerWidth: 22 * unit, cornerHeight: 22 * unit, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 18 * unit, color: CGColor(gray: 0, alpha: 0.5))
        context.addPath(shape)
        context.setFillColor(CGColor(srgbRed: 0x15 / 255.0, green: 0x11 / 255.0, blue: 0x10 / 255.0, alpha: 0.86))
        context.fillPath()
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        context.setLineWidth(max(1, 1.5 * unit))
        context.strokePath()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let pointSize = 44 * unit
        if let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let size = tinted.size
            tinted.draw(
                in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
        }
        guard let image = context.makeImage() else { return nil }
        return CapturedImage(cgImage: image, scale: unit)
    }
}
