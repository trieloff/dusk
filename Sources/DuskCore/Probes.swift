import Foundation

/// A natural experiment: dusk changed one thing about the screens (appearance,
/// or brightness) and nothing else, and read every sensor just before and once
/// the readings had settled after. The difference is what that sensor sees of
/// the screens, which is most of what it reads in light mode in the evening.
public struct Probe: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case appearance, brightness }

    public var time: Date
    public var kind: Kind
    public var fromAppearance: Appearance
    public var toAppearance: Appearance
    public var fromBrightness: Double
    public var toBrightness: Double
    public var before: [SensorSample]
    public var after: [SensorSample]
    /// How long the sensors took to settle; nil for probes rebuilt from samples.
    public var settleSeconds: Double?
    /// "live", or "backfill" when reconstructed from minute samples.
    public var source: String

    public init(time: Date, kind: Kind, fromAppearance: Appearance, toAppearance: Appearance,
                fromBrightness: Double, toBrightness: Double, before: [SensorSample],
                after: [SensorSample], settleSeconds: Double?, source: String = "live") {
        self.time = time
        self.kind = kind
        self.fromAppearance = fromAppearance
        self.toAppearance = toAppearance
        self.fromBrightness = fromBrightness
        self.toBrightness = toBrightness
        self.before = before
        self.after = after
        self.settleSeconds = settleSeconds
        self.source = source
    }

    /// Per sensor: lux after minus lux before.
    public var deltas: [String: Double] {
        let b = Dictionary(before.map { ($0.key, $0.lux) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Double] = [:]
        for s in after { if let x = b[s.key] { out[s.key] = s.lux - x } }
        return out
    }

    /// What this probe says about one sensor, normalised per unit of brightness:
    /// for an appearance probe, light-mode minus dark-mode screen light; for a
    /// brightness probe, the slope in its appearance.
    public func perUnitBrightness(_ key: String) -> Double? {
        guard let d = deltas[key] else { return nil }
        switch kind {
        case .appearance:
            guard fromAppearance != toAppearance, toBrightness > 0.05,
                  abs(toBrightness - fromBrightness) < 0.02 else { return nil }
            return (toAppearance == .light ? d : -d) / toBrightness
        case .brightness:
            let db = toBrightness - fromBrightness
            guard fromAppearance == toAppearance, abs(db) >= 0.1 else { return nil }
            return d / db
        }
    }
}

/// One sensor's current estimate of what the screens contribute to it, in lux
/// per unit of screen brightness. Linear through zero: a first approximation,
/// and the raw probes are stored so a better one can be fitted later.
public struct ScreenSensorEstimate: Codable, Sendable, Equatable {
    public var key: String
    /// Light-mode minus dark-mode screen light, from appearance switches.
    public var delta: Double?
    /// Slope in light mode and in dark mode, from brightness changes (or, when
    /// only one is measured, derived from it and `delta`).
    public var lightGain: Double?
    public var darkGain: Double?
    public var probes: Int

    public func gain(_ a: Appearance) -> Double? { a == .light ? lightGain : darkGain }
}

public enum ScreenLight {
    /// Estimates from the most recent `recent` usable probes of each kind,
    /// per sensor; medians, so one odd probe (a lamp switched on mid-switch)
    /// does not move them.
    public static func estimate(_ probes: [Probe], recent: Int = 12) -> [ScreenSensorEstimate] {
        let keys = Set(probes.flatMap { $0.after.map(\.key) })
        let newest = probes.sorted { $0.time > $1.time }
        return keys.sorted().map { key in
            // Live probes take seconds; backfilled ones span a minute, in which
            // daylight can move too. Once there are live ones, use only those.
            func take(_ f: (Probe) -> Bool) -> [Double] {
                let usable = newest.filter { f($0) && $0.perUnitBrightness(key) != nil }
                let live = usable.filter { $0.source == "live" }
                return Array((live.isEmpty ? usable : live).compactMap { $0.perUnitBrightness(key) }.prefix(recent))
            }
            let deltas = take { $0.kind == .appearance }
            let light = take { $0.kind == .brightness && $0.toAppearance == .light }
            let dark = take { $0.kind == .brightness && $0.toAppearance == .dark }
            let delta = median(deltas)
            var lg = median(light), dg = median(dark)
            if lg == nil, let dg, let delta { lg = dg + delta }
            if dg == nil, let lg = lg, let delta { dg = lg - delta }
            return ScreenSensorEstimate(key: key, delta: delta,
                                        lightGain: lg.map { max(0, $0) },
                                        darkGain: dg.map { max(0, $0) },
                                        probes: deltas.count + light.count + dark.count)
        }
    }

    /// Rebuilds probes from minute samples: consecutive samples (at most
    /// `maxGap` apart) where only the appearance changed, or only brightness
    /// changed by at least 0.1. Coarser than live probes — the room can drift
    /// in a minute — so they are marked as backfill.
    public static func backfill(_ samples: [Sample], maxGap: TimeInterval = 150) -> [Probe] {
        var out: [Probe] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            guard b.time.timeIntervalSince(a.time) <= maxGap,
                  let ba = a.screenBrightness, let bb = b.screenBrightness else { continue }
            let kind: Probe.Kind
            if a.appearance != b.appearance, abs(bb - ba) < 0.01 { kind = .appearance }
            else if a.appearance == b.appearance, abs(bb - ba) >= 0.1 { kind = .brightness }
            else { continue }
            out.append(Probe(time: b.time, kind: kind, fromAppearance: a.appearance,
                             toAppearance: b.appearance, fromBrightness: ba, toBrightness: bb,
                             before: a.sensors, after: b.sensors, settleSeconds: nil,
                             source: "backfill"))
        }
        return out
    }
}

/// Reads the sensors until they stop moving: every `step`, at least `min`,
/// at most `max` seconds. Stable means every sensor moved less than 3% (or
/// 0.15 lx) across two consecutive reads.
func settledReading(_ sensors: AmbientLightSensors, min: TimeInterval = 1, max: TimeInterval = 6,
                    step: TimeInterval = 0.5) async -> (readings: [SensorSample], seconds: Double) {
    let start = Date()
    func read() -> [SensorSample] {
        sensors.read().map { SensorSample(key: String(format: "%08x", $0.locationID), lux: $0.lux, kelvin: $0.kelvin) }
    }
    var previous: [SensorSample] = []
    var calm = 0
    while true {
        try? await Task.sleep(nanoseconds: UInt64(step * 1e9))
        let now = read()
        let elapsed = Date().timeIntervalSince(start)
        let stable = !previous.isEmpty && previous.count == now.count && zip(previous, now).allSatisfy {
            abs($0.lux - $1.lux) <= Swift.max(0.15, 0.03 * Swift.max($0.lux, $1.lux))
        }
        calm = stable ? calm + 1 : 0
        previous = now
        if (calm >= 2 && elapsed >= min) || elapsed >= max { return (now, elapsed) }
    }
}
