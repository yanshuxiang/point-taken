import AVFoundation
import Foundation

/// Keeps one recording in the format it started with when the microphone changes mid-recording (AirPods
/// connecting drops 48 kHz to 16/24 kHz; a USB mic may have more channels). The WAV archive and the live
/// recognizer are opened for the first format, so later buffers are converted back to it.
/// Stateful (the resampler carries samples between calls): use it from one serial queue.
public final class BoardAudioFormatBridge {
    public let source: AVAudioFormat
    public let target: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard source.sampleRate > 0, source.channelCount > 0,
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.source = source
        self.target = target
        self.converter = converter
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    /// Whether two formats can be written into the same file without conversion.
    public static func matches(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat && a.isInterleaved == b.isInterleaved
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / source.sampleRate) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "PointTaken.AudioBridge", code: 1)
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if status == .error { throw error ?? NSError(domain: "PointTaken.AudioBridge", code: 2) }
        return output
    }
}
