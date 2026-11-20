import AVFoundation
import Testing

@testable import RetainerKit

/// The recorder's resampling, checked with synthetic audio so no microphone
/// is needed.
@Suite("Audio conversion")
struct AudioConversionTests {

    static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    /// A buffer holding a sine wave on the first channel and, when there is a
    /// second channel, full-scale noise that must not leak into the result.
    static func sine(format: AVAudioFormat, frames: Int, startFrame: Int, frequency: Double) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = buffer.floatChannelData!
        for frame in 0..<frames {
            let time = Double(startFrame + frame) / format.sampleRate
            channels[0][frame] = Float(sin(2 * .pi * frequency * time)) * 0.5
            if format.channelCount > 1 {
                channels[1][frame] = frame % 2 == 0 ? 1 : -1
            }
        }
        return buffer
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test(
        "A second of microphone audio becomes a second of 16 kHz mono",
        arguments: [(48_000.0, 1), (48_000.0, 2), (44_100.0, 2), (24_000.0, 1), (16_000.0, 1)])
    func resamples(sampleRate: Double, channels: Int) throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels),
                interleaved: false))
        let converter = try #require(AudioRecorder.makeConverter(from: format, to: Self.target))

        // Ten buffers of a tenth of a second, as the input tap delivers them.
        let framesPerBuffer = Int(sampleRate / 10)
        var output: [Float] = []
        for index in 0..<10 {
            let buffer = Self.sine(
                format: format, frames: framesPerBuffer, startFrame: index * framesPerBuffer, frequency: 440)
            output += AudioRecorder.convert(buffer, with: converter, to: Self.target)
        }
        output += AudioRecorder.convert(nil, with: converter, to: Self.target)

        // One second in, one second out, give or take the few milliseconds
        // the resampler's filter adds or holds back at the edges.
        #expect(abs(output.count - 16_000) <= 160)

        // The tone survives at its level (0.5 peak is 0.354 RMS), which also
        // shows the second channel's noise was not mixed in.
        let middle = output[2_000..<14_000]
        #expect(abs(Self.rms(middle) - 0.3536) < 0.02)

        // No clicks at buffer boundaries: a 440 Hz tone at 16 kHz never moves
        // more than 0.09 between samples.
        let largestStep = zip(middle, middle.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        #expect(largestStep < 0.12)
    }

    @Test("The level meter maps quiet to low and loud to high")
    func levelMeter() {
        let meter = LevelMeter()
        meter.push(rms: 0.0001)
        #expect(meter.level < 0.05)
        meter.push(rms: 0.05)
        let speech = meter.level
        #expect(speech > 0.4 && speech < 0.8)
        meter.push(rms: 1.0)
        #expect(meter.level == 1)
        meter.reset()
        #expect(meter.level == 0)
    }
}
