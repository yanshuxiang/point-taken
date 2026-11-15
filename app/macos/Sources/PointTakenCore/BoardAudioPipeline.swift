import AVFoundation
import Foundation

/// Owns tap buffers before AVAudioEngine reuses them. Disk, conversion and recognition work run in order,
/// off the audio thread; finishing closes admission and drains the accepted tail before finalization.
public final class BoardAudioPipeline {
    public enum Failure: Error { case allocation, backlog }
    private let queue = DispatchQueue(label: "pointtaken.board.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var pendingBytes = 0
    private let maximumPendingBytes: Int
    private let consume: (AVAudioPCMBuffer) -> Void
    private let failed: (Failure) -> Void

    public init(maximumPendingBytes: Int = 32 * 1024 * 1024,
                consume: @escaping (AVAudioPCMBuffer) -> Void,
                failed: @escaping (Failure) -> Void) {
        self.maximumPendingBytes = maximumPendingBytes
        self.consume = consume
        self.failed = failed
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard pendingBytes + bytes <= maximumPendingBytes else {
            accepting = false
            lock.unlock()
            failed(.backlog)
            return
        }
        guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            accepting = false
            lock.unlock()
            failed(.allocation)
            return
        }
        owned.frameLength = buffer.frameLength
        let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for (input, output) in zip(source, destination) {
            if let inputData = input.mData, let outputData = output.mData {
                memcpy(outputData, inputData, Int(input.mDataByteSize))
            }
        }
        pendingBytes += bytes
        queue.async { [self] in
            consume(owned)
            lock.lock(); pendingBytes -= bytes; lock.unlock()
        }
        lock.unlock()
    }

    /// Place a boundary after all buffers accepted so far (pause markers and request.endAudio).
    public func afterPending(_ work: @escaping () -> Void) {
        lock.lock(); queue.async(execute: work); lock.unlock()
    }

    public func finish(_ work: @escaping () -> Void) {
        lock.lock()
        accepting = false
        queue.async(execute: work)
        lock.unlock()
    }
}
