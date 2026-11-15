// The way to the bundled Python scripts (transcription, the cloud speech check): ScriptRunner (uv, the login-shell
// environment); results come back on the main queue. A failing script answers {"ok": false, "code": …}.
import AppKit
import PointTakenCore

enum Scripts {
    static var dir: URL { PointTakenPaths.scripts }
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    static func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    struct Failure: Error, CustomStringConvertible {
        let code: String
        let message: String
        var description: String { message }
        /// What to tell the user: the code's own sentence when there is one, else a general one.
        var localized: String {
            let k = "main.error.\(code)"
            return T(k) == k ? T("main.error.generic") : T(k)
        }
    }

    /// The last JSON object a CLI printed.
    static func json(_ d: Data) -> [String: Any]? {
        for l in String(decoding: d, as: UTF8.self).split(separator: "\n").reversed() {
            if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] { return o }
        }
        return nil
    }

    /// Runs `script args…` off the main thread; `done` gets stdout (or the error) on the main queue.
    static func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60,
                    done: @escaping (Result<Data, Error>) -> Void) {
        Task.detached {
            let r: Result<Data, Error>
            do { r = .success(try await ScriptRunner.shared.run(script, args, stdin: stdin, timeout: timeout)) } catch { r = .failure(error) }
            await MainActor.run { done(r) }
        }
    }

    /// run() for the {"ok": …} CLIs: the decoded object, or a Failure carrying the CLI's code.
    static func call(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60,
                     done: @escaping (Result<[String: Any], Failure>) -> Void) {
        run(script, args, stdin: stdin, timeout: timeout) { r in
            switch r {
            case .success(let d):
                guard let o = json(d), o["ok"] as? Bool == true else {
                    let o = json(d) ?? [:]
                    return done(.failure(Failure(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? "\(script) failed")))
                }
                done(.success(o))
            case .failure(ScriptError.failed(_, let out, let err)):
                let o = json(out) ?? [:]
                done(.failure(Failure(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? err)))
            case .failure(ScriptError.scriptMissing(let p)):
                done(.failure(Failure(code: "no_scripts", message: p)))
            case .failure(ScriptError.uvMissing):
                done(.failure(Failure(code: "no_uv", message: "uv not found")))
            case .failure(let e):
                done(.failure(Failure(code: "failed", message: "\(e)")))
            }
        }
    }
}
