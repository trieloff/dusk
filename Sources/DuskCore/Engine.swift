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
    private var lastPrune = Date.distantPast
    /// The latest camera readings, carried into samples until they go stale.
    private var latestCameras: [CameraSample] = []
    /// Set while a probe is measuring; nothing else may touch the screens then.
    private var probing = false
    private var probes: [Probe] = []
    public private(set) var screenLight: [ScreenSensorEstimate] = []
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
        if let store {
            probes = store.probes(since: Date().addingTimeInterval(-60 * 86400))
            if !probes.contains(where: { $0.source == "backfill" }) {
                let rebuilt = ScreenLight.backfill(store.samples(since: Date().addingTimeInterval(-60 * 86400)))
                for p in rebuilt { store.add(p) }
                probes = store.probes(since: Date().addingTimeInterval(-60 * 86400))
                if !rebuilt.isEmpty { log("rebuilt \(rebuilt.count) screen-light probe(s) from history") }
            }
            screenLight = ScreenLight.estimate(probes)
        }
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
        let perDisplay = displays.displays().compactMap { d in
            displays.brightness(of: d.id).map {
                DisplaySample(key: String(CGDisplaySerialNumber(d.id), radix: 16, uppercase: true), brightness: $0)
            }
        }
        let levels = perDisplay.map(\.brightness)
        if cameras.isEmpty, let taken = latestCameras.first?.takenAt,
           now.timeIntervalSince(taken) > max(1, config.cameraEveryMinutes) * 60 * 1.5 {
            latestCameras = []  // stale: no capture for one and a half intervals
        }
        let carried = latestCameras.map { c -> CameraSample in var c = c; c.photo = nil; return c }
        var s = Sample(time: now,
                       sensors: readings.map {
                           SensorSample(key: String(format: "%08x", $0.locationID), lux: $0.lux, kelvin: $0.kelvin)
                       },
                       screenBrightness: levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count),
                       appearance: SystemAppearance.current,
                       cameras: cameras.isEmpty ? carried : cameras)
        s.displays = perDisplay
        s.screenLight = screenLight
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
        guard !probing else { return }
        let now = Date()
        let s = await sample(now: now)
        guard !probing else { return }
        lastSample = s
        let measured = config.brightness.useRoomLux ? (s.medianRoomLux ?? s.medianLux) : s.medianLux
        let lux = measured.map { smoother.add($0) }

        if now.timeIntervalSince(lastStored) >= config.sampleSeconds {
            lastStored = now
            store?.add(s)
        }
        if config.cameraEveryMinutes > 0,
           now.timeIntervalSince(lastPeriodicPhoto) >= config.cameraEveryMinutes * 60 {
            lastPeriodicPhoto = now
            Task {
                if !Cameras.authorized, !(await Cameras.requestAccess()) { return }
                await self.recordPhotos(base: s)
            }
        }
        if now.timeIntervalSince(lastPrune) >= 6 * 3600 {
            lastPrune = now
            prunePhotos(now: now)
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
                if await switchAppearance(to: target) {
                    appearance = target
                    log("appearance → \(target) (\(describe(lastDecider)))")
                }
            }
        }
        if automatic { await brightness(for: appearance, lux: lux, now: now) }
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
        guard await switchAppearance(to: target) else { return }
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
            if !correction.sample.cameras.isEmpty { latestCameras = correction.sample.cameras }
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
        guard !s.cameras.isEmpty else { return }
        latestCameras = s.cameras
        store?.add(s)
        log("photographed the room: luma " + s.cameras.map { String(format: "%.2f", $0.luma) }.joined(separator: ", "))
    }

    /// Deletes scheduled photos past the retention period; photos that belong
    /// to a correction are what the user disagreed about, so they stay.
    private func prunePhotos(now: Date) {
        guard let store, config.photoRetentionDays > 0 else { return }
        let keep = Set(store.corrections(.confirmed).flatMap { $0.sample.cameras.compactMap(\.photo) })
        let cutoff = now.addingTimeInterval(-config.photoRetentionDays * 86400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: store.photos, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for f in files where !keep.contains(f.lastPathComponent) {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                if (try? fm.removeItem(at: f)) != nil { removed += 1 }
            }
        }
        if removed > 0 { log("deleted \(removed) photo(s) older than \(Int(config.photoRetentionDays)) days") }
    }

    // MARK: probes

    private func readSensors() -> [SensorSample] {
        sensors.read().map { SensorSample(key: String(format: "%08x", $0.locationID), lux: $0.lux, kelvin: $0.kelvin) }
    }

    private func meanBrightness() -> Double? {
        let levels = displays.displays().compactMap { displays.brightness(of: $0.id) }
        return levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count)
    }

    /// Switches appearance, holding brightness still and measuring what every
    /// sensor saw change. Returns whether the switch happened.
    private func switchAppearance(to target: Appearance) async -> Bool {
        let from = SystemAppearance.current
        probing = true
        defer { probing = false }
        let before = readSensors()
        let b = meanBrightness()
        do { try SystemAppearance.set(target) } catch { log("appearance: \(error)"); return false }
        let after = await settledReading(sensors)
        if let b, let b2 = meanBrightness() {
            record(Probe(time: Date(), kind: .appearance, fromAppearance: from, toAppearance: target,
                         fromBrightness: b, toBrightness: b2, before: before, after: after.readings,
                         settleSeconds: after.seconds))
        }
        return true
    }

    private func record(_ p: Probe) {
        store?.add(p)
        probes.append(p)
        screenLight = ScreenLight.estimate(probes)
        let per = p.after.compactMap { s in p.perUnitBrightness(s.key).map { String(format: "%@ %+.1f", s.key, $0) } }
        log("probe (\(p.kind.rawValue), \(String(format: "%.1f", p.settleSeconds ?? 0)) s): "
            + (per.isEmpty ? "unusable" : per.joined(separator: ", ") + " lx per unit brightness"))
    }

    public var allProbes: [Probe] { probes }

    // MARK: brightness

    private func brightness(for appearance: Appearance, lux: Double?, now: Date) async {
        guard !probing else { return }
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
        // Only a change on every display is a clean experiment.
        let probe = changes.count == displays.displays().count
            && changes.allSatisfy { abs($0.from - target) >= 0.1 }
        probing = probe
        defer { probing = false }
        let before = probe ? readSensors() : []
        let fromB = meanBrightness()
        do {
            try displays.fade(changes.map { ($0.display.id, target) })
            for c in changes { applied[c.display.id] = target }
            if probe, let fromB {
                let after = await settledReading(sensors)
                record(Probe(time: Date(), kind: .brightness, fromAppearance: appearance,
                             toAppearance: SystemAppearance.current, fromBrightness: fromB,
                             toBrightness: meanBrightness() ?? target, before: before,
                             after: after.readings, settleSeconds: after.seconds))
            }
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
