import AVFoundation
import XCTest
@testable import PointTakenCore

/// A microphone switch mid-recording (built-in 48 kHz → AirPods 24 kHz, or a stereo USB mic) must still land in
/// the WAV that was opened for the first format.
final class BoardAudioFormatBridgeTests: XCTestCase {
    private func tone(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for n in 0..<Int(frames) {
                buffer.floatChannelData![channel][n] = sinf(Float(n) * 2 * .pi * 440 / Float(format.sampleRate)) * 0.5
            }
        }
        return buffer
    }

    func testMatchesIgnoresIdenticalFormatsOnly() {
        let a = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        XCTAssertTrue(BoardAudioFormatBridge.matches(a, AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!))
        XCTAssertFalse(BoardAudioFormatBridge.matches(a, AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!))
        XCTAssertFalse(BoardAudioFormatBridge.matches(a, AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!))
    }

    func testLowerRateMicrophoneIsResampledIntoTheOriginalArchive() throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let source = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let bridge = try XCTUnwrap(BoardAudioFormatBridge(from: source, to: target))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try BoardAudioArchive(url: url, format: target)
        var produced: AVAudioFramePosition = 0
        for _ in 0..<24 { // one second of 24 kHz input
            let out = try bridge.convert(tone(source, frames: 1000))
            XCTAssertEqual(out.format.sampleRate, 48000)
            if out.frameLength > 0 { try archive.append(out) }
            produced += AVAudioFramePosition(out.frameLength)
        }
        archive.close()
        // The resampler holds back a few samples of latency; nearly a full second at 48 kHz must come out.
        XCTAssertGreaterThan(produced, 47000)
        XCTAssertLessThanOrEqual(produced, 48000)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, produced)
        XCTAssertEqual(archive.seconds, Double(produced) / 48000, accuracy: 0.001)
    }

    func testStereoMicrophoneIsDownmixedToMono() throws {
        let target = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let bridge = try XCTUnwrap(BoardAudioFormatBridge(from: source, to: target))
        let out = try bridge.convert(tone(source, frames: 1024))
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertGreaterThan(out.frameLength, 0)
        let peak = (0..<Int(out.frameLength)).map { abs(out.floatChannelData![0][$0]) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "downmix must keep the signal, not silence it")
    }
}
