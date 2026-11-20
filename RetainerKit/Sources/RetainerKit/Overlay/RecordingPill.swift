import SwiftUI

/// The small capsule that says "recording": a live waveform driven by the
/// microphone level. Once the hold ends it shows a short status word instead.
struct RecordingPill: View {

    enum Mode: Equatable {
        case recording
        case status(String)
    }

    let meter: LevelMeter
    var mode: Mode = .recording
    /// A fixed level for static renders; `nil` reads the meter live.
    var fixedLevel: Float?

    static let height: CGFloat = 28

    var body: some View {
        Group {
            switch mode {
            case .recording:
                Waveform(meter: meter, fixedLevel: fixedLevel)
            case .status(let text):
                Text(text)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background { PillBackground() }
        .animation(.easeOut(duration: 0.15), value: mode)
        .accessibilityElement()
        .accessibilityLabel(mode == .recording ? "Recording" : "Processing")
    }
}

/// A near-black capsule with a hairline edge. The edge is a second, larger
/// capsule behind the fill rather than a stroke, which keeps it even all the
/// way round the ends.
struct PillBackground: View {
    var body: some View {
        ZStack {
            Capsule().fill(Theme.hairlineStrong)
            Capsule().inset(by: Theme.hairlineWidth).fill(Theme.background)
        }
    }
}

/// Vertical bars whose heights follow the microphone level. Loudness shapes
/// the whole row; a slow per-bar ripple keeps it from moving as one block.
private struct Waveform: View {

    let meter: LevelMeter
    var fixedLevel: Float?

    private static let barCount = 11
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 2
    private static let minHeight: CGFloat = 2
    private static let maxHeight: CGFloat = 16
    /// Taller in the middle, shorter at the ends.
    private static let envelope: [CGFloat] = [0.38, 0.55, 0.72, 0.86, 0.96, 1.0, 0.96, 0.86, 0.72, 0.55, 0.38]

    /// Smoothed level carried from frame to frame.
    private final class Smoother {
        var value: CGFloat = 0
        var lastUpdate: Date?

        func advance(toward target: CGFloat, at date: Date) -> CGFloat {
            let elapsed = lastUpdate.map { min(date.timeIntervalSince($0), 0.1) } ?? (1.0 / 60)
            lastUpdate = date
            // Rise quickly with the voice, fall back more slowly.
            let timeConstant = target > value ? 0.035 : 0.16
            value += (target - value) * CGFloat(1 - exp(-elapsed / timeConstant))
            return value
        }
    }

    @State private var smoother = Smoother()

    private var width: CGFloat {
        CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.gap
    }

    var body: some View {
        if let fixedLevel {
            bars(level: CGFloat(fixedLevel), time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                let level = smoother.advance(toward: CGFloat(meter.level), at: context.date)
                bars(level: level, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(level: CGFloat, time: TimeInterval) -> some View {
        Canvas { context, size in
            for index in 0..<Self.barCount {
                let ripple = 0.78 + 0.22 * sin(time * (6.0 + Double(index % 4)) + Double(index) * 1.7)
                let amount = min(1, max(0, level * Self.envelope[index] * CGFloat(ripple)))
                let height = Self.minHeight + (Self.maxHeight - Self.minHeight) * amount
                let x = CGFloat(index) * (Self.barWidth + Self.gap)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(Theme.accent))
            }
        }
        .frame(width: width, height: Self.maxHeight)
    }
}
