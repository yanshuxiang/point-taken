import Foundation
import CoreGraphics

/// A small visual fingerprint used only for detecting page boundaries; never used as exported image data.
public struct BoardFrameFingerprint {
    public let values: [UInt8]
    public init(values: [UInt8]) { self.values = values }
    public init(_ image: CGImage) {
        let width = 64, height = 40
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        values = bytes
    }
    public func distance(to other: Self) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 1 }
        return zip(values, other.values).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(values.count * 255)
    }
}

/// Debounces navigation and scroll bursts. It never sees key contents and never consumes input events.
public struct BoardPageGate {
    public enum Decision { case reference, leave, settling }
    private var context: String?
    private var previous: BoardFrameFingerprint?
    private var settling = false
    private var stableSince: Double?
    private var lastScroll = -Double.infinity
    private var lastInput = -Double.infinity
    public init() {}

    public mutating func interaction(at time: Double, scroll: Bool) {
        lastInput = time
        if scroll { lastScroll = time }
    }

    /// `mask`: what moves on its own on this page (BoardMotionMask) is left out of the comparison, so a turning
    /// carousel near a click or a scroll does not look like navigation.
    public mutating func observe(_ next: BoardFrameFingerprint, context nextContext: String, at time: Double,
                                 mask: BoardMotionMask = BoardMotionMask()) -> Decision {
        defer { previous = next; context = nextContext }
        guard let previous, let context else { return .reference }
        let difference = mask.distance(next, previous)
        if context != nextContext {
            settling = true; stableSince = nil
            return .leave
        }
        if settling {
            if difference < 0.018 && time - lastScroll > 0.4 {
                if stableSince == nil { stableSince = time }
                if time - stableSince! >= 0.35 { settling = false; return .reference }
            } else { stableSince = nil }
            return .settling
        }
        if (time - lastScroll < 0.6 && difference > 0.008) || (time - lastInput < 1.5 && difference > 0.045) {
            settling = true; stableSince = nil
            return .leave
        }
        return .reference
    }
}
