import CoreGraphics
import Foundation

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

/// Where the current verdict came from.
public enum Decider: Equatable, Sendable {
    case model(probabilityDark: Double)
    case rules
    case paused
}

/// The whole of dusk at runtime: sensing, recording, deciding, learning.
/// Runs on the main actor; the menu bar app and `dusk watch` both drive one.
@MainActor
public final class Engine {
    /// Mutable at runtime for the menu's toggles; not written back to disk.
    public var config: Config
    public let sensors = AmbientLightSensors()
    public let displays = DisplayControl()
    public let cameras = Cameras()
    public let store: Store?
    public let weather: Weather?
    public var log: (String) -> Void
    /// Called after anything visible changed (appearance, model, readings).
    public var onChange: (() -> Void)?

    /// Off: dusk records and learns, but never switches on its own.
    public var automatic = true { didSet { onChange?() } }

    public private(set) var model: Model?
    public private(set) var lastSample: Sample?
    public private(set) var lastDecider: Decider = .rules
    public private(set) var training = false
    public var pendingCorrection: Correction? { tracker.pending }
    public var confirmedCorrections: Int { store?.count("corrections WHERE state = 'confirmed'") ?? 0 }

    private var decider: AppearanceDecider
    private var smoother: Smoother
    private var tracker = CorrectionTracker()
    private var applied: [CGDirectDisplayID: Double] = [:]
    private var manualUntil: [CGDirectDisplayID: Date] = [:]
    public var manualOverride: TimeInterval = 3600
    private var lastStored = Date.distantPast
    private var lastLuxLog = Date.distantPast
    private var lastPeriodicPhoto = Date.distantPast
    private var timer: DispatchSourceTimer?

    public init(config: Config, store: Store? = try? Store(), log: @escaping (String) -> Void = { print($0) }) {
        self.config = config
        self.store = store
        self.log = log
        decider = AppearanceDecider(hold: config.holdSeconds)
        smoother = Smoother(alpha: config.smoothing)
        if let lat = config.latitude, let lon = config.longitude {
            weather = Weather(latitude: lat, longitude: lon)
        } else {
            weather = nil
        }
        model = store?.latestModel()
        // Settle switches that were still pending when we last quit.
        for c in store?.corrections(.pending) ?? [] {
            if Date().timeIntervalSince(c.time) >= tracker.window {
                store?.save(c, state: .confirmed)
            } else {
                tracker.resume(c)
            }
        }
    }

    public var sun: Sun? {
        guard let lat = config.latitude, let lon = config.longitude else { return nil }
        return Sun(latitude: lat, longitude: lon)
    }

    // MARK: running

    public func start() {
        takeOverBrightness()
        Task { await tick() }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + config.intervalSeconds, repeating: config.intervalSeconds,
                   leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            Task { @MainActor in await self?.tick() }
        }
        t.resume()
        timer = t
        if model == nil, confirmedCorrections > 0 { Task { await retrain() } }
    }

    /// Everything known right now. Weather may come from a 15-minute cache.
    public func sample(now: Date = Date(), cameras: [CameraSample] = []) async -> Sample {
        let readings = sensors.read()
        let levels = displays.displays().compactMap { displays.brightness(of: $0.id) }
        var s = Sample(time: now,
                       sensors: readings.map {
                           SensorSample(key: String(format: "%08x", $0.locationID), lux: $0.lux, kelvin: $0.kelvin)
                       },
                       screenBrightness: levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count),
                       appearance: SystemAppearance.current, cameras: cameras)
        if let sun {
            s.sunElevation = sun.elevation(at: now)
            s.sunRising = sun.isRising(at: now)
            if let c = sun.crossings(on: now) {
                s.minutesToSunset = c.set.timeIntervalSince(now) / 60
                s.minutesSinceSunrise = now.timeIntervalSince(c.rise) / 60
            }
        }
        s.weather = await weather?.current(now: now)
        return s
    }

    public func tick() async {
        let now = Date()
        let s = await sample(now: now)
        lastSample = s
        let lux = s.medianLux.map { smoother.add($0) }

        if now.timeIntervalSince(lastStored) >= config.sampleSeconds {
            lastStored = now
            store?.add(s)
        }
        if config.cameraEveryMinutes > 0, Cameras.authorized,
           now.timeIntervalSince(lastPeriodicPhoto) >= config.cameraEveryMinutes * 60 {
            lastPeriodicPhoto = now
            Task { await self.recordPhotos(base: s) }
        }
        if now.timeIntervalSince(lastLuxLog) >= 600 {
            lastLuxLog = now
            log("lux \(fmt(lux)) (sensors: \(s.sensors.map { fmt($0.lux) }.joined(separator: ", ")))"
                + (s.sunElevation.map { String(format: ", sun %.1f°", $0) } ?? "")
                + (s.weather.map { String(format: ", outdoors %.0f W/m²", $0.shortwave) + ($0.cloudCover.map { String(format: " %.0f%% cloud", $0) } ?? "") } ?? "")
                + (lastDecider.probability.map { String(format: ", model p(dark) %.2f", $0) } ?? ""))
        }
        if let outcome = tracker.tick(now: now) { settle(outcome) }

        var appearance = s.appearance
        if config.manageAppearance {
            if decider.current != nil { decider.observe(s.appearance) }
            let v = verdict(for: s, smoothedLux: lux)
            if automatic, let target = decider.update(v, now: now), target != s.appearance {
                do {
                    try SystemAppearance.set(target)
                    appearance = target
                    log("appearance → \(target) (\(describe(lastDecider)))")
                } catch {
                    log("appearance: \(error)")
                }
            }
        }
        if automatic { brightness(for: appearance, lux: lux, now: now) }
        onChange?()
    }

    /// The model's verdict when there is one, else the configured rules.
    func verdict(for s: Sample, smoothedLux lux: Double?) -> Appearance? {
        if !automatic { lastDecider = .paused }
        if config.useModel, let model, let p = model.probabilityDark(s.features) {
            if automatic { lastDecider = .model(probabilityDark: p) }
            if p >= config.modelDarkAbove { return .dark }
            if p <= config.modelLightBelow { return .light }
            return nil
        }
        if automatic { lastDecider = .rules }
        return DuskCore.verdict(source: config.source, lux: lux, sunUp: s.sunElevation.map { _ in
            sun!.isUp(at: s.time, morning: config.sunThreshold(rising: true),
                      evening: config.sunThreshold(rising: false))
        }, darkBelow: config.darkBelowLux, lightAbove: config.lightAboveLux)
    }

    private func describe(_ d: Decider) -> String {
        switch d {
        case .model(let p): return String(format: "model, p(dark) %.2f", p)
        case .rules: return "rules"
        case .paused: return "paused"
        }
    }

    // MARK: manual switches

    /// The user (menu bar click, Shortcut, CLI) asked for an appearance.
    /// With `learn`, it becomes a correction once it has stood five minutes.
    public func set(_ target: Appearance, source: String, learn: Bool = true) async {
        let now = Date()
        let before = await sample(now: now)  // the room as it was when the user objected
        let from = before.appearance
        guard target != from else { return }
        do { try SystemAppearance.set(target) } catch { log("appearance: \(error)"); return }
        decider.observe(target)
        log("appearance → \(target) by hand (\(source))")
        onChange?()
        guard learn else { return }

        var correction = Correction(time: now, from: from, to: target, source: source, sample: before)
        var allowed = Cameras.authorized
        if config.cameraOnCorrection, !allowed { allowed = await Cameras.requestAccess() }
        if config.cameraOnCorrection, allowed {
            correction.sample.cameras = await cameras.capture(matching: config.cameraFilter,
                                                              into: store?.photos)
        }
        store?.save(correction, state: .pending)
        if let outcome = tracker.record(correction) {
            if case .reverted = outcome { store?.save(correction, state: .reverted) }
            settle(outcome)
        }
        onChange?()
    }

    public func toggle(source: String, learn: Bool = true) async {
        await set(SystemAppearance.current == .dark ? .light : .dark, source: source, learn: learn)
    }

    private func settle(_ outcome: CorrectionTracker.Outcome) {
        switch outcome {
        case .reverted(let c):
            store?.save(c, state: .reverted)
            log("switch to \(c.to) undone within five minutes; not learning from it")
        case .confirmed(let c):
            store?.save(c, state: .confirmed)
            log("learned: \(c.to) at \(fmt(c.sample.medianLux)) lx"
                + (c.sample.sunElevation.map { String(format: ", sun %.1f°", $0) } ?? ""))
            Task { await retrain() }
        }
        onChange?()
    }

    // MARK: learning

    public func retrain() async {
        guard let store, !training else { return }
        training = true
        onChange?()
        let corrections = store.corrections(.confirmed)
        let hourly = store.hourlySamples(since: Date().addingTimeInterval(-30 * 86400))
        let model = await Task.detached(priority: .utility) {
            Trainer.train(examples(corrections: corrections, samples: hourly))
        }.value
        training = false
        if let model {
            store.save(model)
            self.model = model
            log("model: \(model.summary) — \(model.corrections) correction(s), "
                + String(format: "cross-validated %.0f%% right on them", model.correctionAccuracy * 100))
        }
        onChange?()
    }

    private func recordPhotos(base: Sample) async {
        var s = base
        s.cameras = await cameras.capture(matching: config.cameraFilter, into: store?.photos)
        if !s.cameras.isEmpty { store?.add(s) }
    }

    // MARK: brightness

    private func brightness(for appearance: Appearance, lux: Double?, now: Date) {
        let b = config.brightness
        let target: Double?
        switch b.mode {
        case .system: target = nil
        case .fixed: target = appearance == .dark ? b.dark : b.light
        case .curve: target = lux.map { b.curve(for: appearance).brightness(forLux: $0) }
        }
        guard let target else { return }
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
            if abs(current - target) >= b.deadband { changes.append((d, current)) }
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

extension Decider {
    public var probability: Double? {
        if case .model(let p) = self { return p }
        return nil
    }
}

public func fmt(_ lux: Double?) -> String {
    guard let lux else { return "–" }
    return lux < 10 ? String(format: "%.1f", lux) : String(format: "%.0f", lux)
}

func pct(_ b: Double) -> String { "\(Int((b * 100).rounded()))%" }
