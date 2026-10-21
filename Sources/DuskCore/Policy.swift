import Foundation

public enum Appearance: String, Codable, Sendable {
    case light, dark
}

/// Maps room illuminance onto display brightness on a log scale, because
/// perceived brightness is roughly logarithmic in lux.
public struct BrightnessCurve: Sendable, Equatable {
    public var minLux: Double
    public var maxLux: Double
    public var minimum: Double
    public var maximum: Double

    public init(minLux: Double, maxLux: Double, minimum: Double, maximum: Double) {
        self.minLux = minLux
        self.maxLux = maxLux
        self.minimum = minimum
        self.maximum = maximum
    }

    public func brightness(forLux lux: Double) -> Double {
        guard lux > minLux else { return minimum }
        guard lux < maxLux else { return maximum }
        let t = (log10(lux) - log10(minLux)) / (log10(maxLux) - log10(minLux))
        return minimum + t * (maximum - minimum)
    }
}

/// What the inputs say right now, before any hold time.
public func verdict(source: Source, lux: Double?, sunUp: Bool?,
                    darkBelow: Double, lightAbove: Double) -> Appearance? {
    func fromLux(_ lux: Double) -> Appearance? {
        if lux < darkBelow { return .dark }
        if lux > lightAbove { return .light }
        return nil  // inside the hysteresis band: keep whatever we have
    }
    func fromSun() -> Appearance? { sunUp.map { $0 ? .light : .dark } }

    switch source {
    case .sun:
        return fromSun()
    case .ambient:
        if let lux { return fromLux(lux) }
        return fromSun()
    case .either:
        if sunUp == false { return .dark }
        guard let lux else { return fromSun() }
        return fromLux(lux)
    }
}

/// Turns a stream of verdicts into appearance changes: a new verdict must hold
/// for `hold` seconds before it wins, except on the very first decision.
///
/// A manual switch by the user is respected: it stands until the verdict itself
/// changes, so dusk never undoes your choice three minutes later, but evening
/// still brings dark mode.
public struct AppearanceDecider: Sendable {
    public private(set) var current: Appearance?
    public private(set) var pending: (target: Appearance, since: Date)?
    /// The verdict at the moment the user overrode us; ignored until it changes.
    public private(set) var overriddenVerdict: Appearance?
    private var lastVerdict: Appearance?
    public var hold: TimeInterval

    public init(current: Appearance? = nil, hold: TimeInterval) {
        self.current = current
        self.hold = hold
    }

    /// Feed one verdict; returns the appearance to switch to, if any.
    public mutating func update(_ verdict: Appearance?, now: Date) -> Appearance? {
        guard let verdict else { pending = nil; return nil }
        lastVerdict = verdict
        if let o = overriddenVerdict {
            if verdict == o { pending = nil; return nil }
            overriddenVerdict = nil
        }
        guard let current else {
            self.current = verdict
            return verdict
        }
        if verdict == current { pending = nil; return nil }
        if pending?.target != verdict { pending = (verdict, now) }
        if let p = pending, now.timeIntervalSince(p.since) >= hold {
            self.current = verdict
            pending = nil
            return verdict
        }
        return nil
    }

    /// Report the appearance actually in effect. If someone else changed it,
    /// adopt it and stand down until the verdict moves.
    public mutating func observe(_ actual: Appearance) {
        guard let current, actual != current else { return }
        self.current = actual
        pending = nil
        overriddenVerdict = lastVerdict
    }
}

/// Exponential moving average that starts at the first sample.
public struct Smoother: Sendable {
    public var alpha: Double
    public private(set) var value: Double?

    public init(alpha: Double) { self.alpha = alpha }

    @discardableResult
    public mutating func add(_ sample: Double) -> Double {
        let v = value.map { $0 + alpha * (sample - $0) } ?? sample
        value = v
        return v
    }
}

public func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}
