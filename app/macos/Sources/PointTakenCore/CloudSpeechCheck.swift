import Foundation

/// Settings' Test for a cloud speech service: `transcribe.py check-cloud`'s answer, and the key's own check.
public enum CloudSpeechCheck {
    public enum Result: Equatable {
        /// it answered in `ms`; `heard`: the test clip's words came back
        case ok(ms: Int, heard: Bool)
        /// a Dictation.strings key for the plain sentence
        case failed(String)
    }

    /// The answer's JSON → the result (nil JSON: the script couldn't run).
    public static func result(_ o: [String: Any]?) -> Result {
        guard let o else { return .failed("speech.cloud.check.other") }
        if o["ok"] as? Bool == true { return .ok(ms: o["ms"] as? Int ?? 0, heard: o["heard"] as? Bool ?? true) }
        return .failed(sentence(o["code"] as? String))
    }

    public static func sentence(_ code: String?) -> String {
        switch code {
        case "auth": return "speech.cloud.check.auth"
        case "network", "timeout": return "speech.cloud.check.network"
        case "quota": return "speech.cloud.check.quota"
        case "privacy": return "speech.cloud.check.privacy"
        case "no_key": return "speech.cloud.check.no_key"
        case "bad_key": return "speech.cloud.check.bad_key"
        case "model": return "speech.cloud.check.model"
        default: return "speech.cloud.check.other"
        }
    }

    /// A key as typed → the key to keep, or nil when it has a character no API key has (what ⌥C types, "ç", came
    /// after the founder's key: every take then failed). Spaces and line breaks around it go; inside it they don't
    /// belong either.
    public static func clean(_ typed: String) -> String? {
        let k = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "" }
        return k.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F } ? k : nil
    }
}
