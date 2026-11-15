import Foundation
import AVFoundation

/// The session transcript lives independently of screenshots. Interim recognition replaces the previous
/// hypothesis; saving/deleting a page never deletes the full transcript or restarts recognition.
public struct BoardTranscript {
    private var finished: [String] = []
    private var hypothesis = ""
    private var utteranceComplete = false
    private var pageOffset = 0
    public init() {}

    public var text: String { (finished + [hypothesis]).filter { !$0.isEmpty }.joined(separator: " ") }
    public var pageText: String { String(text.dropFirst(min(pageOffset, text.count))) }

    public mutating func update(_ words: String, final: Bool, utteranceComplete: Bool = false) {
        let next = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // On-device Speech may finish an utterance without finishing its recognition task.
        // The next partial then starts over. Preserve the settled utterance, while still
        // allowing recognizers that return cumulative text to revise/extend it in place.
        if !next.isEmpty {
            if self.utteranceComplete && next != hypothesis && !next.hasPrefix(hypothesis) { commit() }
            if next != hypothesis { self.utteranceComplete = false }
            hypothesis = next
        }
        if utteranceComplete { self.utteranceComplete = true }
        if final { commit() }
    }

    public mutating func commit() {
        if !hypothesis.isEmpty { finished.append(hypothesis) }
        hypothesis = ""
        utteranceComplete = false
    }

    /// A completed file transcription covers the whole recording, including recognizer restart gaps.
    public mutating func replaceWithFileTranscript(_ words: String) {
        finished = [words]
        hypothesis = ""
        utteranceComplete = false
    }

    /// Page excerpts are advisory: recognizer revisions before a boundary can move that boundary.
    /// The authoritative full text above retains the complete corrected recognition.
    @discardableResult public mutating func markPage() -> String {
        let result = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        pageOffset = text.count
        return result
    }
}

public enum BoardExport {
    public static func text(transcript: String, images: [URL], terminal: Bool) -> String {
        var parts: [String] = []
        if !transcript.isEmpty { parts.append("完整语音转写（含背景说明）：\n" + transcript) }
        if !images.isEmpty {
            let list = images.enumerated().map { index, url in
                "图\(index + 1)" + (terminal ? "：\(url.path)" : "：第 \(index + 1) 张附件")
            }.joined(separator: "\n")
            parts.append("标注截图：\n" + list)
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Explicit review edits are separate from recognition. Old empty exports are not evidence
/// that the user deliberately deleted everything; new edits carry an explicit marker.
public enum BoardDeliveryTranscript {
    public static func load(from directory: URL) -> String {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("转写编辑.json")),
           let edit = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           edit["userEdited"] as? Bool == true, let text = edit["text"] as? String { return text }
        if let text = try? String(contentsOf: directory.appendingPathComponent("交付转写.txt"), encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return (try? String(contentsOf: directory.appendingPathComponent("完整转写.txt"), encoding: .utf8)) ?? ""
    }

    public static func saveEdit(_ text: String, to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["userEdited": true, "text": text], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("转写编辑.json"), options: .atomic)
        try text.write(to: directory.appendingPathComponent("交付转写.txt"), atomically: true, encoding: .utf8)
    }
}

/// Uncompressed microphone samples, written continuously even when recognition is unavailable.
/// Serializes writes with close so a late audio callback cannot write into a closed file.
public final class BoardAudioArchive {
    private let lock = NSLock()
    private let durationLock = NSLock()
    private var file: AVAudioFile?
    private var duration = 0.0
    // UI timestamps must not wait for an in-progress disk write.
    public var seconds: Double { durationLock.lock(); defer { durationLock.unlock() }; return duration }
    public init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        try file.write(from: buffer)
        durationLock.lock()
        duration += Double(buffer.frameLength) / buffer.format.sampleRate
        durationLock.unlock()
    }

    public func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
