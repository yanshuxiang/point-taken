import Foundation

/// One paste of a sequence: a picture alone, or text alone.
public enum PasteStep: Equatable {
    case image(URL)
    case text(String)
}

/// The sequence, step by step: put a step on the clipboard, ⌘V, wait until the app read it (or a timeout), the next;
/// after the last, give the clipboard back (the app waits a moment first: a slow reader still gets the last step).
/// Something else written to the clipboard meanwhile (the user copied) stops it, and nothing is put back over that.
public struct PasteRun: Equatable {
    public enum Action: Equatable {
        case put(PasteStep)
        case paste
        /// the clipboard as it was before the sequence (the card copy)
        case restore
    }
    public enum Event: Equatable {
        /// the app asked for the step's data
        case read
        /// it didn't, in time
        case timeout
        /// the clipboard was written by someone else
        case clobbered
        /// the restore delay passed
        case restoreDue
    }
    public enum State: Equatable {
        case idle
        case pasting(Int)
        case restoring
        case done
        case aborted
    }

    public let steps: [PasteStep]
    public private(set) var state: State = .idle
    /// steps the app read / steps whose read we didn't see
    public private(set) var read = 0
    public private(set) var unconfirmed = 0

    public init(steps: [PasteStep]) { self.steps = steps }

    public mutating func start() -> [Action] {
        guard state == .idle, let first = steps.first else { state = .done; return [] }
        state = .pasting(0)
        return [.put(first), .paste]
    }

    public mutating func handle(_ e: Event) -> [Action] {
        switch (state, e) {
        case (.pasting, .clobbered), (.restoring, .clobbered):
            state = .aborted
            return []
        case (.pasting(let i), .read), (.pasting(let i), .timeout):
            if e == .read { read += 1 } else { unconfirmed += 1 }
            guard i + 1 < steps.count else { state = .restoring; return [] }
            state = .pasting(i + 1)
            return [.put(steps[i + 1]), .paste]
        case (.restoring, .restoreDue):
            state = .done
            return [.restore]
        default:
            return []
        }
    }

    public var finished: Bool { state == .done || state == .aborted }
}
