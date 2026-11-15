import XCTest
@testable import PointTakenCore

final class ScriptTimeoutTests: XCTestCase {
    func testTimedOutCaptureStopsItsDescendants() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late-write")
        let result = ShellEnv.runCapture("/bin/sh", ["-c", "(trap '' TERM; printf ready; sleep 0.6; printf late > \"$1\") & wait", "test", marker.path], timeout: 0.2)
        XCTAssertNil(result.status)
        XCTAssertTrue(String(decoding: result.out, as: UTF8.self).contains("ready"), "The child must have started before testing cancellation")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A timed-out child kept working after its parent stopped")
    }

    func testCaptureDrainsOutputAndPreservesExitStatus() {
        let result = ShellEnv.runCapture("/bin/sh", ["-c", "printf hello; printf error >&2; exit 7"], timeout: 2)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.out, as: UTF8.self), "helloerror")
    }

    func testScriptTimeoutStopsAnUncooperativeChildAndReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late-write")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; (sleep 1; printf late > \"$1\") & wait", "test", marker.path]
        let start = Date()
        do {
            _ = try await ScriptRunner().runProcess(process, timeout: 0.2)
            XCTFail("The uncooperative script must time out")
        } catch ScriptError.timeout { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testScriptReceivesInputAndDrainsLargeOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Data(repeating: 65, count: 512 * 1024)
        let output = try await ScriptRunner().runProcess(process, stdin: input, timeout: 3)
        XCTAssertEqual(output, input)
    }
}
