import PointTakenCore
import Foundation

/// Only allowlisted request metadata is saved here; audio, text and credentials stay out.
enum BoardModelStatus {
    static func name(_ id: String?) -> String {
        switch id {
        case "board-apple-speech": return "苹果系统识别"
        case "volcengine-seedasr": return "豆包 Seed-ASR 2.0"
        case nil, "": return "未记录模型"
        default: return id!
        }
    }

    /// A failed call's code as a sentence people can act on (never a raw string-table key).
    static func failureText(_ code: String?) -> String {
        switch code {
        case "no_scripts": return "找不到转写脚本，安装不完整，请重新安装" + PointTaken.nameZh
        case "no_uv": return "缺少运行转写需要的 uv，请重新安装" + PointTaken.nameZh
        default: return Loc.string(CloudSpeechCheck.sentence(code), table: "Speech")
        }
    }

    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func latest(root: URL) -> (directory: URL, state: [String: Any], receipt: [String: Any]?)? {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for directory in folders {
            if let state = read(directory.appendingPathComponent("转写状态.json")) {
                return (directory, state, read(directory.appendingPathComponent("转写调用.json")))
            }
        }
        return nil
    }

    static func result(state: [String: Any], receipt: [String: Any]?) -> String {
        let model = name(state["model"] as? String)
        switch state["state"] as? String {
        case "recording": return "本次：尚未调用完整转写 · " + model
        case "finalizing": return "本次：正在完整转写 · " + model
        case "complete":
            if receipt?["state"] as? String == "failed" { return "最近记录：完整转写未完成 · " + model }
            if let receipt, receipt["state"] as? String == "success",
               receipt["actualModel"] as? String == state["model"] as? String,
               receipt["provider"] as? String == "volcengine",
               let request = receipt["requestID"] as? String, !request.isEmpty {
                return "最近记录：豆包 API 已完成"
            }
            return "最近记录：已完成 · " + model
        case "incomplete":
            let warning = state["warning"] as? String ?? ""
            if warning.contains("可从历史重新转写") {
                return "最近记录：退出时保存，完整转写未完成"
            }
            return "最近记录：完整转写未完成 · " + model
        default: return "最近记录：未记录转写结果"
        }
    }

    static func writeReceipt(audio: URL, state: String, model: String, response: [String: Any] = [:], filename: String = "转写调用.json") {
        var fields: [String: Any] = ["state": state, "model": model, "updatedAt": Date().timeIntervalSince1970]
        for (source, target) in [("model", "actualModel"), ("provider", "provider"),
                                 ("service_model", "serviceModel"), ("request_id", "requestID"), ("code", "code")] {
            if let value = response[source] as? String { fields[target] = value }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: audio.deletingLastPathComponent().appendingPathComponent(filename), options: .atomic)
        }
    }
}
