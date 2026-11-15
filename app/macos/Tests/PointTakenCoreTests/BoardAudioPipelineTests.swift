import AVFoundation
import XCTest
@testable import PointTakenCore

final class BoardAudioPipelineTests: XCTestCase {
    private func buffer(_ value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = value }
        return buffer
    }

    func testSlowDiskDoesNotBlockTapAndFinishKeepsOwnedTailInOrder() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "all captured samples drained")
        var samples: [Float] = []
        let pipeline = BoardAudioPipeline(consume: { buffer in
            if samples.isEmpty { entered.signal(); release.wait() }
            samples.append(buffer.floatChannelData![0][0])
        }, failed: { _ in XCTFail("audio rejected") })
        let first = buffer(1)
        pipeline.append(first)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let began = Date()
        pipeline.append(buffer(2))
        pipeline.append(buffer(3))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.05)
        // The real tap reuses its buffer as soon as append returns.
        first.floatChannelData![0][0] = 9
        pipeline.finish {
            XCTAssertEqual(samples, [1, 2, 3])
            finished.fulfill()
        }
        pipeline.append(buffer(4))
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    func testPauseBoundaryFollowsAudioAlreadyCaptured() {
        let done = expectation(description: "pause boundary")
        var events: [String] = []
        let pipeline = BoardAudioPipeline(consume: { _ in events.append("audio") }, failed: { _ in XCTFail() })
        pipeline.append(buffer(1))
        pipeline.afterPending { events.append("pause") }
        pipeline.append(buffer(2))
        pipeline.finish {
            XCTAssertEqual(events, ["audio", "pause", "audio"])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testBacklogIsBoundedAndReportsFailureInsteadOfSilentlyDropping() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let failure = expectation(description: "backlog visible")
        let drained = expectation(description: "accepted buffer retained")
        var count = 0
        let pipeline = BoardAudioPipeline(maximumPendingBytes: 4096, consume: { _ in
            entered.signal(); release.wait(); count += 1
        }, failed: { error in
            guard case .backlog = error else { return XCTFail("wrong failure") }
            failure.fulfill()
        })
        pipeline.append(buffer(1))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        pipeline.append(buffer(2))
        pipeline.finish { XCTAssertEqual(count, 1); drained.fulfill() }
        release.signal()
        wait(for: [failure, drained], timeout: 2)
    }
}
