import AppKit
import Foundation
import Testing

@testable import RetainerKit

@Suite("Palette and appearance")
@MainActor
struct ThemeTests {

    /// A theme colour as it comes out in a window of the given appearance.
    private func hex(_ colour: NSColor, in name: NSAppearance.Name) -> String {
        var result = ""
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let rgb = colour.usingColorSpace(.sRGB) else { return }
            result = String(
                format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        return result
    }

    /// The dark values are the ones sampled from the screenshot the palette
    /// was asked to match.
    @Test("Dark is the requested palette")
    func darkPalette() {
        #expect(hex(Theme.nsBackground, in: .darkAqua) == "151110")
        #expect(hex(Theme.nsPanel, in: .darkAqua) == "1B1917")
        #expect(hex(Theme.nsPanelRaised, in: .darkAqua) == "201E1C")
        #expect(hex(Theme.nsHairline, in: .darkAqua) == "2C2826")
        #expect(hex(Theme.nsHairlineStrong, in: .darkAqua) == "373533")
        #expect(hex(Theme.nsText, in: .darkAqua) == "EAE8E6")
        #expect(hex(Theme.nsTextSecondary, in: .darkAqua) == "A5A09D")
        #expect(hex(Theme.nsAccent, in: .darkAqua) == "DDC1B1")
    }

    @Test("Light turns it over: pale surfaces, dark text")
    func lightPalette() {
        #expect(hex(Theme.nsBackground, in: .aqua) == "F6F4F1")
        #expect(hex(Theme.nsPanel, in: .aqua) == "FDFCFA")
        #expect(hex(Theme.nsText, in: .aqua) == "1B1917")
        // Every colour differs between the two, so nothing is left behind when switching.
        let all = [
            Theme.nsBackground, Theme.nsPanel, Theme.nsPanelRaised, Theme.nsHairline, Theme.nsHairlineStrong,
            Theme.nsText, Theme.nsTextSecondary, Theme.nsTextMuted, Theme.nsTextFaint, Theme.nsAccent,
            Theme.nsSelection,
        ]
        for colour in all {
            #expect(hex(colour, in: .aqua) != hex(colour, in: .darkAqua))
        }
    }

    /// Relative luminance contrast between two colours, 1…21.
    private func contrast(_ a: NSColor, _ b: NSColor, in name: NSAppearance.Name) -> Double {
        func luminance(_ colour: NSColor) -> Double {
            var value = 0.0
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                guard let rgb = colour.usingColorSpace(.sRGB) else { return }
                func linear(_ c: CGFloat) -> Double {
                    let c = Double(c)
                    return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
                value =
                    0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                    + 0.0722 * linear(rgb.blueComponent)
            }
            return value
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("Text is readable on its surfaces in both appearances", arguments: [NSAppearance.Name.darkAqua, .aqua])
    func readable(appearance: NSAppearance.Name) {
        for surface in [Theme.nsBackground, Theme.nsPanel] {
            #expect(contrast(Theme.nsText, surface, in: appearance) > 12)
            #expect(contrast(Theme.nsTextSecondary, surface, in: appearance) > 5.5)
            #expect(contrast(Theme.nsTextMuted, surface, in: appearance) > 3.5)
        }
        // The waveform's colour against the pill it sits in.
        #expect(contrast(Theme.nsAccent, Theme.nsPanel, in: appearance) > 3)
    }

    @Test("Light mode is off until switched on, is remembered, and announces each change once")
    func lightModeSetting() {
        let suite = "retainer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.lightMode)
        var announced: [Bool] = []
        settings.onLightModeChange = { announced.append($0) }

        settings.lightMode = true
        settings.lightMode = true
        #expect(announced == [true])
        #expect(AppSettings(defaults: defaults).lightMode)

        settings.lightMode = false
        #expect(announced == [true, false])
        #expect(!AppSettings(defaults: defaults).lightMode)
        // The other setting is untouched by all this.
        #expect(AppSettings(defaults: defaults).tidyEnabled)
    }
}
