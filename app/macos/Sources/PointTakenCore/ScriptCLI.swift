import Foundation

// MARK: - Running the skill's scripts

/// One finished script call.
public struct CLIResult {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public var ok: Bool { status == 0 }
    /// stdout's last JSON object line (the C2/C5 CLIs print one line; transcribe.py models prints pretty JSON)
    public var json: [String: Any]? {
        if let o = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] { return o }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return o }
        }
        return nil
    }
    public func decode<T: Decodable>(_ t: T.Type) -> T? {
        if let v = try? JSONDecoder().decode(t, from: stdout) { return v }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let v = try? JSONDecoder().decode(t, from: Data(line.utf8)) { return v }
        }
        return nil
    }
    /// {"ok": false, "error": …} from stdout, else the tail of stderr
    public var errorText: String {
        if let e = json?["error"] as? String { return e }
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? "exit \(status)" : String(e.suffix(600))
    }
}

/// The skill's Python CLIs through uv: WP4's ScriptRunner for plain calls. Calls that need extra packages
/// (`uv run --with mlx-whisper …`), extra or replaced environment (POINT_TAKEN_HF_MIRROR, agents.py install's full env) or
/// separate stdout / stderr streams (download progress) start `uv run -q [--with X] <script>` here, in the same
/// ShellEnv environment.
public final class SkillCLI {
    public static let shared = SkillCLI()

    /// The environment for every child (ShellEnv's login-shell environment unless replaced).
    public var environment: () -> [String: String] = { ShellEnv.agentEnvironment() }

    public init() {}

    /// uv on the user's PATH, else ~/.point-taken/bin/uv (WP4's lookup).
    public var uvPath: String? { ScriptRunner.shared.uvPath }

    public func scriptURL(_ script: String) -> URL {
        script.hasPrefix("/") ? URL(fileURLWithPath: script) : PointTakenPaths.scripts.appendingPathComponent(script)
    }

    /// Never throws for a non-zero exit: the CLIs report errors as JSON on stdout. Throws when uv or the script is
    /// missing, or on timeout.
    public func run(_ script: String, _ args: [String], stdin: Data? = nil, with packages: [String] = [],
                    env extra: [String: String] = [:], timeout: TimeInterval = 60) async throws -> CLIResult {
        if packages.isEmpty, extra.isEmpty, self === SkillCLI.shared {
            do {
                let out = try await ScriptRunner.shared.run(script, args, stdin: stdin, timeout: timeout)
                return CLIResult(status: 0, stdout: out, stderr: "")
            } catch ScriptError.failed(let status, let out, let err) {
                return CLIResult(status: status, stdout: out, stderr: err)
            }
        }
        let p = try makeProcess(script, args, with: packages, env: extra)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                if stdin != nil { p.standardInput = Pipe() } else { p.standardInput = FileHandle.nullDevice }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let s = stdin, let inPipe = p.standardInput as? Pipe {
                    inPipe.fileHandleForWriting.write(s)
                    try? inPipe.fileHandleForWriting.close()
                }
                var out = Data(), err = Data()
                let lock = NSLock()
                let g = DispatchGroup()
                for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
                    g.enter()
                    DispatchQueue.global().async {
                        while true {
                            let c = pipe.fileHandleForReading.availableData
                            if c.isEmpty { break }
                            lock.lock(); if isOut { out.append(c) } else { err.append(c) }; lock.unlock()
                        }
                        g.leave()
                    }
                }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning {
                    p.terminate()
                    cont.resume(throwing: ScriptError.timeout(timeout))
                    return
                }
                _ = g.wait(timeout: .now() + 2)
                lock.lock(); defer { lock.unlock() }
                cont.resume(returning: CLIResult(status: p.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self)))
            }
        }
    }

    /// A long-running script: stdout and stderr lines (on the main queue), then the exit status (main queue).
    @discardableResult
    public func spawn(_ script: String, _ args: [String], with packages: [String] = [], env extra: [String: String] = [:],
                      onLine: @escaping (String, Bool) -> Void, onExit: @escaping (Int32) -> Void) throws -> Process {
        let p = try makeProcess(script, args, with: packages, env: extra)
        p.standardInput = FileHandle.nullDevice
        streamLines(p, onLine: onLine)
        p.terminationHandler = { pr in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onExit(pr.terminationStatus) }   // let the last lines land
        }
        try p.run()
        return p
    }

    func makeProcess(_ script: String, _ args: [String], with packages: [String], env extra: [String: String]) throws -> Process {
        guard let uv = uvPath else { throw ScriptError.uvMissing }
        let url = scriptURL(script)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ScriptError.scriptMissing(url.path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "-q"] + packages.flatMap { ["--with", $0] } + [url.path] + args
        p.environment = environment().merging(extra) { _, new in new }
        return p
    }
}

/// stdout/stderr of `p` as lines on the main queue (bool = from stderr). Call before p.run().
public func streamLines(_ p: Process, onLine: @escaping (String, Bool) -> Void) {
    for isErr in [false, true] {
        let pipe = Pipe()
        if isErr { p.standardError = pipe } else { p.standardOutput = pipe }
        var buf = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; if !buf.isEmpty { let s = String(decoding: buf, as: UTF8.self); buf = Data(); DispatchQueue.main.async { onLine(s, isErr) } }; return }
            buf.append(chunk)
            // progress bars use \r; treat it as a line end too
            while let i = buf.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...i)
                if !line.isEmpty { DispatchQueue.main.async { onLine(line, isErr) } }
            }
        }
    }
}
