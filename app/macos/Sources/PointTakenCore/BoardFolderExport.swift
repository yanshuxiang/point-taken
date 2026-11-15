import Foundation

/// An independent snapshot: later archive edits/deletions cannot invalidate a handoff.
public enum BoardFolderExport {
    public struct Bundle {
        public let directory: URL
        public let images: [URL]
        public let text: String
    }

    public static func create(root: URL, pages: [BoardReadablePage], transcript: String,
                              evidence: BoardEvidence?) throws -> Bundle {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let id = UUID().uuidString
        let destination = root.appendingPathComponent(stamp.string(from: Date()) + " " + id)
        let staging = root.appendingPathComponent(".preparing-" + id)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var exported = pages
        var index = 0
        for p in exported.indices {
            for i in exported[p].images.indices {
                index += 1
                let source = exported[p].images[i]
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard source.isFileURL, values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let name = "图\(index).png"
                try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
                exported[p].images[i] = destination.appendingPathComponent(name)
            }
        }
        let intro = "图片已保存为本地文件，请读取下列完整路径对应的图片，结合转写与标记理解反馈。需要接收端能够访问这台电脑的文件。"
        let text = intro + "\n\n" + BoardReadableExport.text(pages: exported, transcript: transcript,
                                                            evidence: evidence, terminal: true)
        try text.write(to: staging.appendingPathComponent("说明.md"), atomically: true, encoding: .utf8)
        // Publish only after every image and the matching explanation have been written.
        try fm.moveItem(at: staging, to: destination)
        return Bundle(directory: destination, images: exported.flatMap(\.images), text: text)
    }
}
