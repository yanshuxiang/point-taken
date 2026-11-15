import Foundation
import AVFoundation
import PointTakenCore

/// The selected caption model consumes its own pause-trimmed PCM, independently of the original archive.
/// No system recognizer, keyboard hooks, dictation state, or fallback provider is involved.
final class BoardLiveSpeech {
    let model: String
    let directory: URL
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onFinalizing: (() -> Void)?
    private let pcm: BoardLivePCM
    private let worker = DispatchQueue(label: "pointtaken.board.live-speech", qos: .userInitiated)
    private let stateLock = NSLock()
    private var process: ProcessGroup?
    private var cancelled = false
    private var terminal = false
    private var failed = false
    private var receivedText = false
    private var completion: (() -> Void)?
    private var lastMetadata: [String: Any] = [:]
    private let audioURL: URL
    var healthy: Bool { !failed && !terminal }
    /// Each finished sentence with its time in the recording, from the provider's own final results.
    private(set) var segments: [BoardSpeechSegment] = []
    /// The whole recording went through one session without an error and the provider confirmed the end.
    private(set) var completedCleanly = false
    private(set) var fileFinalizationAttempted = false
    private(set) var finalFileTranscript: BoardSpeech.FileTranscript?
    /// Doubao's live session runs a second, non-streaming pass on every sentence (enable_nonstream): its text is the
    /// final transcript's quality, so the stop needn't send the whole recording again.
    var finalQuality: Bool { completedCleanly && !cancelled && (lastMetadata["service_model"] as? String)?.contains("two-pass") == true }
    var receiptMetadata: [String: Any] { lastMetadata }

    init(model: String, directory: URL, format: AVAudioFormat) throws {
        self.model = model
        self.directory = directory.appendingPathComponent("实时语音", isDirectory: true)
        audioURL = directory.appendingPathComponent("原始录音.wav")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        pcm = try BoardLivePCM(url: self.directory.appendingPathComponent("audio.pcm"), format: format)
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("stop"))
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("paused"))
    }

    func start() {
        BoardModelStatus.writeReceipt(audio: audioURL, state: "connecting", model: model, filename: "实时调用.json")
        worker.async { [self] in
            do {
                guard let uv = ScriptRunner.shared.uvPath else { throw ScriptError.uvMissing }
                let script = try ScriptRunner.shared.scriptURL("board_live.py")
                let output = Pipe()
                defer { try? output.fileHandleForReading.close() }
                let exited = DispatchSemaphore(value: 0)
                let environment = ShellEnv.agentEnvironment().merging(ScriptRunner.extraEnvironment()) { _, key in key }
                stateLock.lock()
                if cancelled { stateLock.unlock(); try? output.fileHandleForWriting.close(); return }
                // Serialize launch with cancellation so a cancelled task cannot start afterwards.
                do {
                    process = try ProcessGroup.spawn(uv,
                        ["run", "-q", script.path, directory.path, "--model-id", model, "--audio-file", audioURL.path],
                        env: environment,
                        cwd: directory, input: nil, output: output.fileHandleForWriting, error: nil,
                        callbackQueue: .global(qos: .utility)) { _ in exited.signal() }
                } catch {
                    stateLock.unlock(); try? output.fileHandleForWriting.close(); throw error
                }
                stateLock.unlock()
                try? output.fileHandleForWriting.close()
                var pending = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: end)
                        pending.removeSubrange(...end)
                        if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            DispatchQueue.main.async { self.receive(event) }
                        }
                    }
                    if pending.count > 2_000_000 { throw ScriptError.notImplemented }
                }
                if exited.wait(timeout: .now() + 2) == .timedOut { stopProcess() }
                else { stateLock.lock(); process = nil; stateLock.unlock() }
                DispatchQueue.main.async { self.didExit() }
            } catch {
                let code: String
                switch error {
                case ScriptError.scriptMissing: code = "no_scripts"
                case ScriptError.uvMissing: code = "no_uv"
                default: code = "error"
                }
                stopProcess()
                DispatchQueue.main.async { self.fail(code); self.didExit() }
            }
        }
    }

    /// Called by the audio worker; conversion and writes never occupy the microphone callback.
    func append(_ buffer: AVAudioPCMBuffer) {
        do { try pcm.append(buffer) }
        catch { DispatchQueue.main.async { self.fail("audio") } }
    }

    func setPaused(_ paused: Bool) {
        let marker = directory.appendingPathComponent("paused")
        if paused { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: marker) }
    }

    func finish(_ done: @escaping () -> Void) {
        pcm.close()
        if terminal { done(); return }
        completion = done
        FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: nil)
        let timeout: Double = model == "volcengine-seedasr" ? 25 : 600
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.terminal else { return }
            self.fail("network")
            self.cancel()
            self.didExit()
        }
    }

    func cancel() {
        // A write already running on the audio worker may still hold the PCM lock.
        let pcm = self.pcm
        DispatchQueue.global(qos: .utility).async { pcm.close() }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: nil)
        stateLock.lock(); cancelled = true; stateLock.unlock()
        stopProcess()
        BoardModelStatus.writeReceipt(audio: audioURL, state: "interrupted", model: model, response: lastMetadata, filename: "实时调用.json")
        onText = nil; onReady = nil; onFailure = nil; onFinalizing = nil
        terminal = true
        let done = completion; completion = nil; done?()
    }

    /// Stop uv and its Python/model children as one owned group; never wait on the UI or audio worker.
    private func stopProcess() {
        stateLock.lock(); let task = process; process = nil; stateLock.unlock()
        guard let task else { return }
        DispatchQueue.global(qos: .utility).async {
            guard ProcessGroup.isOurs(task.pgid, started: task.started) else { return }
            ProcessGroup.stop(task.pgid, grace: 0.2)
        }
    }

    private func receive(_ event: [String: Any]) {
        guard !terminal, !cancelled else { return }
        guard event["model"] as? String == model else { fail("bad_response"); return }
        for key in ["model", "provider", "request_id", "service_model"] {
            if let value = event[key] as? String, !value.isEmpty { lastMetadata[key] = value }
        }
        if event["event"] as? String == "finalizing" {
            fileFinalizationAttempted = true
            BoardModelStatus.writeReceipt(audio: audioURL, state: "requested", model: model, response: lastMetadata)
            onFinalizing?()
            return
        }
        if event["event"] as? String == "file_transcript" {
            fileFinalizationAttempted = true
            guard event["ok"] as? Bool != false, event["looped"] as? Bool != true,
                  let text = event["text"] as? String, let rows = event["segments"] as? [[String: Any]] else {
                BoardModelStatus.writeReceipt(audio: audioURL, state: "failed", model: model, response: event)
                fail(event["code"] as? String ?? "incomplete_response")
                return
            }
            let segments = rows.compactMap { row -> BoardSpeechSegment? in
                guard let start = row["start"] as? Double, let end = row["end"] as? Double,
                      let words = row["text"] as? String, start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                return BoardSpeechSegment(start: start, end: end, text: words)
            }
            guard segments.count == rows.count else {
                BoardModelStatus.writeReceipt(audio: audioURL, state: "failed", model: model, response: ["code": "incomplete_response"])
                fail("incomplete_response"); return
            }
            finalFileTranscript = .init(text: text, segments: segments)
            return
        }
        if event["ok"] as? Bool == false { fail(event["code"] as? String ?? "error"); return }
        switch event["event"] as? String {
        case "connected":
            BoardModelStatus.writeReceipt(audio: audioURL, state: "connected", model: model, response: lastMetadata, filename: "实时调用.json")
            onReady?()
        case "partial", "segment":
            guard let text = event["text"] as? String else { fail("bad_response"); return }
            if !text.isEmpty && !receivedText {
                receivedText = true
                BoardModelStatus.writeReceipt(audio: audioURL, state: "receiving", model: model, response: lastMetadata, filename: "实时调用.json")
            }
            if event["event"] as? String == "segment" {
                let rows = (event["utterances"] as? [[String: Any]] ?? []).compactMap { row -> BoardSpeechSegment? in
                    guard let start = row["start"] as? Double, let end = row["end"] as? Double, let words = row["text"] as? String,
                          start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                    return BoardSpeechSegment(start: start, end: end, text: words)
                }
                if !rows.isEmpty { segments += rows }
                else if let start = event["start"] as? Double, let end = event["end"] as? Double, end > start,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(BoardSpeechSegment(start: start, end: end, text: text))
                }
            }
            onText?(text, event["event"] as? String == "segment")
        case "done":
            if !failed {
                BoardModelStatus.writeReceipt(audio: audioURL, state: "success", model: model, response: lastMetadata, filename: "实时调用.json")
                completedCleanly = true
            }
            didExit(confirmed: true)
        default: break
        }
    }

    private func fail(_ code: String) {
        guard !failed, !terminal else { return }
        failed = true
        var metadata = lastMetadata; metadata["code"] = code
        BoardModelStatus.writeReceipt(audio: audioURL, state: "failed", model: model, response: metadata, filename: "实时调用.json")
        onFailure?(BoardModelStatus.failureText(code))
    }

    private func didExit(confirmed: Bool = false) {
        guard !terminal else { return }
        if !failed && !confirmed && !cancelled { fail("network") }
        terminal = true
        let done = completion; completion = nil
        done?()
    }
}

/// Buffer format conversion shared by production and the synthetic live probe.
private final class BoardLivePCM {
    private let lock = NSLock()
    private var file: FileHandle?
    private let converter: AVAudioConverter
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    init(url: URL, format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: output),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BoardLongImage.Failure(message: "无法准备所选模型的实时音频。")
        }
        self.converter = converter
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        file = try FileHandle(forWritingTo: url)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 256
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if status == .error {
            if let error { throw error }
            throw BoardLongImage.Failure(message: "实时音频转换失败。")
        }
        if let samples = converted.int16ChannelData?[0], converted.frameLength > 0 {
            try file.write(contentsOf: Data(bytes: samples, count: Int(converted.frameLength) * 2))
        }
    }
    func close() { lock.lock(); defer { lock.unlock() }; try? file?.close(); file = nil }
}

/// Pace a synthetic caller-provided WAV through the production converter and live bridge, without microphone access.
enum BoardLiveProbe {
    static func run(_ args: [String]) -> Never {
        guard args.count == 1, BoardTranscription.selected != BoardTranscription.apple else { exit(2) }
        CloudSpeech.install()
        let model = BoardTranscription.selected
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[0]))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("point-taken-live-probe-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: args[0]), to: root.appendingPathComponent("原始录音.wav"))
            let live = try BoardLiveSpeech(model: model, directory: root, format: file.processingFormat)
            let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            var finishing = false
            var updates = 0
            var lastWords = ""
            var errorMessage: String?
            var silence = 0
            let timer = DispatchSource.makeTimerSource(queue: .main)
            live.onText = { words, final in
                if !finishing && !final && !words.isEmpty { updates += 1 }
                if !words.isEmpty { lastWords = words }
            }
            live.onFailure = { errorMessage = $0 }
            func finish() {
                guard !finishing else { return }; finishing = true
                timer.cancel()
                live.finish {
                    var metadata = BoardModelStatus.read(root.appendingPathComponent("实时调用.json")) ?? [:]
                    let ok = updates > 0 && !lastWords.isEmpty && errorMessage == nil
                    metadata["event"] = "board_live_probe"
                    metadata["ok"] = ok
                    metadata["updates_before_stop"] = updates
                    metadata["characters"] = lastWords.count; metadata["text"] = lastWords; metadata["final_quality"] = live.finalQuality; metadata["segments"] = live.segments.count
                    if let errorMessage { metadata["error"] = errorMessage }
                    metadata["directory"] = root.path
                    emit(metadata)
                    exit(ok ? 0 : 1)
                }
            }
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { finish(); return }
                do {
                    if file.framePosition < file.length {
                        try file.read(into: buffer, frameCount: frames)
                    }
                    if buffer.frameLength > 0 { live.append(buffer) }
                    else if silence < 20 {
                        silence += 1
                        buffer.frameLength = frames
                        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
                        }
                        live.append(buffer)
                    } else { finish() }
                } catch { errorMessage = "audio"; finish() }
            }
            live.start()
            timer.resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(45, Double(file.length) / file.processingFormat.sampleRate + 15)) { finish() }
            CFRunLoopRun()
            exit(2)
        } catch {
            emit(["event": "board_live_probe", "ok": false, "code": "audio"])
            exit(1)
        }
    }
}
