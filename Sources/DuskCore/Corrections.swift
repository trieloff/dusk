import Foundation

/// A manual switch, waiting to see whether the user meant it.
public struct Correction: Codable, Sendable, Equatable {
    public var id: UUID
    public var time: Date
    public var from: Appearance
    public var to: Appearance
    /// Where it came from: "menu bar", "shortcut", "cli", …
    public var source: String
    public var sample: Sample

    public init(id: UUID = UUID(), time: Date, from: Appearance, to: Appearance,
                source: String, sample: Sample) {
        self.id = id
        self.time = time
        self.from = from
        self.to = to
        self.source = source
        self.sample = sample
    }
}

/// Turns manual switches into training labels. A switch only counts once it
/// has stood for `window` (five minutes): switching back sooner means it was a
/// look, a mistake or a test, and both clicks are dropped.
public struct CorrectionTracker: Sendable {
    public var window: TimeInterval
    public private(set) var pending: Correction?

    public init(window: TimeInterval = 300) { self.window = window }

    public enum Outcome: Equatable, Sendable {
        case confirmed(Correction)
        case reverted(Correction)
    }

    /// Record a manual switch. Returns what happened to the previous one.
    public mutating func record(_ c: Correction) -> Outcome? {
        guard let p = pending else { pending = c; return nil }
        if c.time.timeIntervalSince(p.time) < window && c.to == p.from {
            pending = nil
            return .reverted(p)
        }
        // A second switch that is not an undo (or comes late) settles the first.
        pending = c
        return .confirmed(p)
    }

    /// Pick up a switch that was still pending when the app last quit.
    public mutating func resume(_ c: Correction) { pending = c }

    /// Call periodically; confirms the pending switch once its window has passed.
    public mutating func tick(now: Date) -> Outcome? {
        guard let p = pending, now.timeIntervalSince(p.time) >= window else { return nil }
        pending = nil
        return .confirmed(p)
    }
}
