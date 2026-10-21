import CoreGraphics
import Foundation

/// Everything dusk knows at one instant.
public struct Snapshot: Sendable {
    public let readings: [LightReading]
    /// Median across sensors, unsmoothed.
    public let lux: Double?
    public let sunElevation: Double?
    public let sunUp: Bool?
    public let appearance: Appearance
}

/// Remembers the auto-brightness setting dusk found, so it can be put back.
struct SavedState: Codable {
    var autoBrightness: [String: Bool] = [:]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dusk/state.json")
    }

    static func load() -> SavedState {
        (try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))) ?? SavedState()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

public final class Controller {
    public let config: Config
    public let sensors = AmbientLightSensors()
    public let displays = DisplayControl()
    private let log: (String) -> Void

    private var decider: AppearanceDecider
    private var smoother: Smoother
    /// What dusk last set per display, to tell its own changes from the user's.
    private var applied: [CGDirectDisplayID: Double] = [:]
    /// Displays the user adjusted by hand, and until when dusk leaves them be.
    private var manualUntil: [CGDirectDisplayID: Date] = [:]
    public var manualOverride: TimeInterval = 3600
    private var lastLuxLog = Date.distantPast

    public init(config: Config, log: @escaping (String) -> Void = { print($0) }) {
        self.config = config
        self.log = log
        decider = AppearanceDecider(hold: config.holdSeconds)
        smoother = Smoother(alpha: config.smoothing)
    }

    public var sun: Sun? {
        guard let lat = config.latitude, let lon = config.longitude else { return nil }
        return Sun(latitude: lat, longitude: lon)
    }

    public func snapshot(now: Date = Date()) -> Snapshot {
        let readings = sensors.read()
        let elevation = sun?.elevation(at: now)
        let up = sun.map {
            $0.isUp(at: now, morning: config.sunThreshold(rising: true),
                    evening: config.sunThreshold(rising: false))
        }
        return Snapshot(readings: readings, lux: median(readings.map(\.lux)),
                        sunElevation: elevation, sunUp: up,
                        appearance: SystemAppearance.current)
    }

    /// One decision cycle. `immediate` skips the hold time (for one-shot runs).
    public func tick(now: Date = Date(), immediate: Bool = false) {
        let s = snapshot(now: now)
        let lux = s.lux.map { smoother.add($0) }
        if now.timeIntervalSince(lastLuxLog) >= 600 {
            lastLuxLog = now
            log("lux \(fmt(lux)) (sensors: \(s.readings.map { fmt($0.lux) }.joined(separator: ", ")))"
                + (s.sunElevation.map { String(format: ", sun %.1f°", $0) } ?? ""))
        }

        var appearance = s.appearance
        if config.manageAppearance {
            if decider.current != nil { decider.observe(s.appearance) }
            if immediate { decider.hold = 0 }
            let v = verdict(source: config.source, lux: lux, sunUp: s.sunUp,
                            darkBelow: config.darkBelowLux, lightAbove: config.lightAboveLux)
            if let target = decider.update(v, now: now), target != s.appearance {
                do {
                    try SystemAppearance.set(target)
                    appearance = target
                    log("appearance → \(target) (lux \(fmt(lux))"
                        + (s.sunUp.map { $0 ? ", sun up" : ", sun down" } ?? "") + ")")
                } catch {
                    log("appearance: \(error)")
                }
            }
            decider.hold = config.holdSeconds
        }

        let target: Double?
        switch config.brightness.mode {
        case .system: target = nil
        case .fixed: target = appearance == .dark ? config.brightness.dark : config.brightness.light
        case .curve: target = lux.map { config.brightness.curve(for: appearance).brightness(forLux: $0) }
        }
        if let target { applyBrightness(target, now: now) }
    }

    private func applyBrightness(_ target: Double, now: Date) {
        var changes: [(display: Display, from: Double)] = []
        for d in displays.displays() {
            guard let current = displays.brightness(of: d.id) else { continue }
            if let until = manualUntil[d.id] {
                if now < until { continue }
                manualUntil[d.id] = nil
                applied[d.id] = nil
            }
            if let last = applied[d.id], abs(current - last) > 0.05 {
                manualUntil[d.id] = now.addingTimeInterval(manualOverride)
                log("\(d.name): brightness changed by hand to \(pct(current)); leaving it for \(Int(manualOverride / 60)) min")
                continue
            }
            if abs(current - target) >= config.brightness.deadband { changes.append((d, current)) }
        }
        guard !changes.isEmpty else { return }
        do {
            try displays.fade(changes.map { ($0.display.id, target) })
            for c in changes { applied[c.display.id] = target }
            let from = Set(changes.map { pct($0.from) }).sorted().joined(separator: "/")
            log("brightness \(from) → \(pct(target)) on \(changes.count) display(s)")
        } catch {
            log("brightness: \(error)")
        }
    }

    // MARK: auto-brightness hand-over

    private static func key(_ id: CGDirectDisplayID) -> String {
        let serial = CGDisplaySerialNumber(id)
        return serial == 0 ? "id-\(id)" : "serial-\(serial)"
    }

    /// When dusk drives brightness, macOS's auto-brightness would fight it, so
    /// turn it off and remember how it was.
    public func takeOverBrightness() {
        guard config.brightness.mode != .system else { return }
        var state = SavedState.load()
        for d in displays.displays() {
            guard let on = displays.autoBrightness(of: d.id) else { continue }
            let k = Self.key(d.id)
            if state.autoBrightness[k] == nil { state.autoBrightness[k] = on }
            if on {
                do {
                    try displays.setAutoBrightness(false, on: d.id)
                    log("\(d.name): macOS auto-brightness off while dusk runs")
                } catch { log("\(d.name): \(error)") }
            }
        }
        state.save()
    }

    /// Puts auto-brightness back the way dusk found it.
    public func restoreBrightness() {
        let state = SavedState.load()
        guard !state.autoBrightness.isEmpty else { return }
        for d in displays.displays() {
            guard let was = state.autoBrightness[Self.key(d.id)],
                  displays.autoBrightness(of: d.id) != was else { continue }
            do {
                try displays.setAutoBrightness(was, on: d.id)
                log("\(d.name): macOS auto-brightness restored (\(was ? "on" : "off"))")
            } catch { log("\(d.name): \(error)") }
        }
        try? FileManager.default.removeItem(at: SavedState.url)
    }
}

func fmt(_ lux: Double?) -> String {
    guard let lux else { return "–" }
    return lux < 10 ? String(format: "%.1f", lux) : String(format: "%.0f", lux)
}

func pct(_ b: Double) -> String { "\(Int((b * 100).rounded()))%" }
