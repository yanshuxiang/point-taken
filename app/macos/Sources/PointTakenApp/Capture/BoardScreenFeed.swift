import AppKit
import PointTakenCore
import ScreenCaptureKit
import CoreImage

/// Captures original pixels with all of this app's windows excluded. Only one frame can await delivery
/// per display, bounding memory even if the main thread is busy rendering or writing a page.
final class BoardScreenFeed: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let image: CGImage
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let scene: String
        var appName: String = ""
        var title: String = ""
        /// the picture's small signature, made once (on the capture queue for live frames): comparing frames never
        /// rescales a full screenshot on the main thread, where the pen's mouse events are handled
        let fingerprint: BoardFrameFingerprint
        init(image: CGImage, displayID: CGDirectDisplayID, bounds: CGRect, scene: String, appName: String = "", title: String = "",
             fingerprint: BoardFrameFingerprint? = nil) {
            self.image = image; self.displayID = displayID; self.bounds = bounds; self.scene = scene
            self.appName = appName; self.title = title
            self.fingerprint = fingerprint ?? BoardFrameFingerprint(image)
        }
    }
    var onObserve: ((Frame, Bool) -> Void)?
    var onLeave: ((Frame) -> Void)?
    var onTransition: ((Frame, Frame, Bool) -> Bool)?
    private var lastScroll = -Double.infinity
    var onFailure: ((String) -> Void)?
    var paused = false { didSet { lock.lock(); capturePaused = paused; lock.unlock() } }
    private var capturePaused = false
    private(set) var current: Frame?
    private var reference: Frame?
    private var gate = BoardPageGate()
    private var streams: [SCStream] = []
    private var metadata: [ObjectIdentifier: (CGDirectDisplayID, CGRect)] = [:]
    private let queue = DispatchQueue(label: "point-taken.board.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var delivering: Set<ObjectIdentifier> = []
    private var monitor: Any?
    private var token = UUID()

    func start() {
        stop()
        paused = false
        let id = UUID(); token = id
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            guard let self, !self.paused else { return }
            if event.type == .scrollWheel { self.lastScroll = ProcessInfo.processInfo.systemUptime }
            else { Self.cachedContext = nil }
            self.gate.interaction(at: ProcessInfo.processInfo.systemUptime, scroll: event.type == .scrollWheel)
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.token == id else { return }
                guard let content else { self.onFailure?(error?.localizedDescription ?? "无法读取屏幕"); return }
                let own = content.applications.filter { $0.processID == getpid() }
                for display in content.displays {
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let configuration = SCStreamConfiguration()
                    let scale = backingScale(forDisplay: display.displayID)
                    configuration.width = Int(display.frame.width * scale)
                    configuration.height = Int(display.frame.height * scale)
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
                    configuration.queueDepth = 3
                    configuration.showsCursor = false
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                    self.lock.lock()
                    self.metadata[ObjectIdentifier(stream)] = (display.displayID, display.frame)
                    self.lock.unlock()
                    do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue) }
                    catch { self.onFailure?(error.localizedDescription); continue }
                    self.streams.append(stream)
                    stream.startCapture { error in
                        if let error { DispatchQueue.main.async { if self.token == id { self.onFailure?(error.localizedDescription) } } }
                    }
                }
            }
        }
    }

    func stop() {
        token = UUID()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        streams.forEach { $0.stopCapture { _ in } }; streams = []
        lock.lock(); metadata = [:]; delivering = []; lock.unlock()
        current = nil; reference = nil; gate = BoardPageGate()
    }

    func resetBoundary() { reference = current; gate = BoardPageGate() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let value = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: value) == .complete,
              let pixels = sample.imageBuffer else { return }
        let key = ObjectIdentifier(stream)
        lock.lock()
        guard let info = metadata[key], !capturePaused, !delivering.contains(key),
              let location = CGEvent(source: nil)?.location, info.1.contains(location) else { lock.unlock(); return }
        delivering.insert(key)
        lock.unlock()
        let input = CIImage(cvPixelBuffer: pixels)
        let image = context.createCGImage(input, from: input.extent)
        let print = image.map(BoardFrameFingerprint.init)          // here, off the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.delivering.remove(key)
            let active = self.metadata[key] != nil
            self.lock.unlock()
            guard active, let image else { return }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard display == info.0 else { return }
            let metadata = Self.context()
            let scene = metadata.scene + ":\(info.0)"
            let frame = Frame(image: image, displayID: info.0, bounds: info.1, scene: scene,
                              appName: metadata.app, title: metadata.title, fingerprint: print)
            guard !self.paused else { return }
            let old = self.current
            self.current = frame
            if let old, self.onTransition?(old, frame, ProcessInfo.processInfo.systemUptime - self.lastScroll < 1.2) == true {
                self.reference = frame; self.gate = BoardPageGate(); return
            }
            let decision = self.gate.observe(frame.fingerprint, context: scene + "|" + frame.title, at: ProcessInfo.processInfo.systemUptime)
            switch decision {
            case .reference:
                self.onObserve?(frame, false)
                self.reference = frame
            case .leave:
                if let old = self.reference { self.onLeave?(old) }
                self.onObserve?(frame, true)
                self.reference = frame
            case .settling: break
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.streams.contains(where: { $0 === stream }) else { return }
            self.onFailure?(error.localizedDescription)
        }
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"(?:https?|file)://\S+|\bwww\.\S+"#)
    private static var cachedContext: (pid: pid_t, at: Double, value: (scene: String, app: String, title: String))?
    static func context() -> (scene: String, app: String, title: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("desktop", "桌面", "") }
        let pid = app.processIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = cachedContext, cache.pid == pid, now - cache.at < 0.35 { return cache.value }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0 }
        var title = front?[kCGWindowName as String] as? String ?? ""
        if title.isEmpty, AXIsProcessTrusted() {
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(unsafeBitCast(window, to: AXUIElement.self), kAXTitleAttribute as CFString, &value)
                title = value as? String ?? ""
            }
        }
        // Never request AXURL or browser history. Strip URLs if a window uses one as its title.
        title = urlPattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "[网址省略]")
            .replacingOccurrences(of: "\n", with: " ")
        let value = ("\(pid):\(front?[kCGWindowNumber as String] ?? "")", app.localizedName ?? "应用", String(title.prefix(240)))
        cachedContext = (pid, now, value)
        return value
    }
}
