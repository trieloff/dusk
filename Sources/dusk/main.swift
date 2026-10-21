import DuskCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let version = "0.1.0"
let label = "com.trieloff.dusk"
let plistURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(label).plist")
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/dusk.log")

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func say(_ s: String) { print("\(stamp())  \(s)") }

func die(_ s: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("dusk: \(s)\n".utf8))
    exit(code)
}

func loadConfig() -> Config {
    do { return try Config.load() } catch { die("\(Config.defaultURL.path): \(error)") }
}

func pct(_ b: Double?) -> String { b.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
func lux(_ l: Double?) -> String { l.map { $0 < 10 ? String(format: "%.1f lx", $0) : String(format: "%.0f lx", $0) } ?? "–" }

func time(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}

// MARK: commands

@MainActor func status() async {
    let config = loadConfig()
    let e = Engine(config: config, log: { _ in })
    let s = await e.sample()
    print("dusk \(version)   config: \(Config.defaultURL.path)\(FileManager.default.fileExists(atPath: Config.defaultURL.path) ? "" : " (defaults)")")
    print("")
    print("ambient light")
    if s.sensors.isEmpty { print("  no sensor found") }
    for r in s.sensors {
        print("  sensor \(r.key): \(lux(r.lux))" + (r.kelvin.map { String(format: ", %.0f K", $0) } ?? ""))
    }
    if s.sensors.count > 1 { print("  median: \(lux(s.medianLux))") }
    print("")
    print("sun and sky")
    if let sun = e.sun, let el = s.sunElevation {
        let up = sun.isUp(at: Date(), morning: config.sunThreshold(rising: true), evening: config.sunThreshold(rising: false))
        let rise = sun.crossings(on: Date(), threshold: config.sunThreshold(rising: true))?.rise
        let set = sun.crossings(on: Date(), threshold: config.sunThreshold(rising: false))?.set
        print(String(format: "  sun %.1f°, %@, %@", el, s.sunRising == true ? "rising" : "setting",
                     up ? "counts as day" : "counts as night")
              + "; day today \(rise.map(time) ?? "–")–\(set.map(time) ?? "–")")
    } else {
        print("  no location configured (set latitude/longitude)")
    }
    if let w = s.weather {
        print(String(format: "  outdoors %.0f W/m²", w.shortwave) + (w.cloudCover.map { String(format: ", %.0f%% cloud", $0) } ?? ""))
    } else if e.weather != nil {
        print("  outdoors: no weather data (\(await e.weather?.lastError ?? "offline?"))")
    }
    print("")
    print("appearance: \(s.appearance)")
    if let m = e.model {
        let p = m.probabilityDark(s.features)
        print("  model: \(m.summary)")
        print(String(format: "    p(dark) now %@, from %d correction(s), cross-validated %.0f%% right",
                     p.map { String(format: "%.2f", $0) } ?? "– (missing input)", m.corrections, m.correctionAccuracy * 100))
    } else {
        let v = verdict(source: config.source, lux: s.medianLux, sunUp: s.sunElevation.map { _ in
            e.sun!.isUp(at: Date(), morning: config.sunThreshold(rising: true), evening: config.sunThreshold(rising: false)) },
            darkBelow: config.darkBelowLux, lightAbove: config.lightAboveLux)
        print("  rules (\(config.source)) say: \(v.map { "\($0)" } ?? "keep (within \(fmtBand(config)))"); no model yet")
    }
    if SystemAppearance.switchesAutomatically {
        print("  warning: System Settings' appearance is set to Auto, which will fight dusk")
    }
    print("")
    print("displays (brightness mode: \(config.brightness.mode))")
    for d in e.displays.displays() {
        let auto = e.displays.autoBrightness(of: d.id).map { $0 ? "auto-brightness on" : "auto-brightness off" } ?? "no auto-brightness"
        print("  \(d.name)\(d.isMain ? " (main)" : ""): \(pct(e.displays.brightness(of: d.id))), \(auto)")
    }
    if config.brightness.mode == .curve, let l = s.medianLux {
        print("  curve target at \(lux(l)) in \(s.appearance) mode: \(pct(config.brightness.curve(for: s.appearance).brightness(forLux: l)))")
    }
    print("")
    let agent = launchctl(["print", "gui/\(getuid())/\(label)"], quiet: true) == 0
    let app = !NSRunningApplicationList.dusk.isEmpty
    print("running: \(app ? "Dusk.app" : agent ? "launch agent \(label)" : "nothing")")
    if let store = e.store {
        print("history: \(store.count("samples")) samples, \(e.confirmedCorrections) confirmed correction(s) in \(store.directory.path)")
    }
}

enum NSRunningApplicationList {
    static var dusk: [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "Dusk"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }
}

func fmtBand(_ c: Config) -> String { "\(lux(c.darkBelowLux))…\(lux(c.lightAboveLux))" }

func sense(_ args: [String]) {
    let every = args.first.flatMap(Double.init) ?? 0
    let sensors = AmbientLightSensors()
    repeat {
        let r = sensors.read()
        let parts = r.map { lux($0.lux) }.joined(separator: "  ")
        print("\(stamp())  median \(lux(median(r.map(\.lux))))   [\(parts)]")
        if every > 0 { Thread.sleep(forTimeInterval: every) }
    } while every > 0
}

@MainActor func runOnce() async {
    let e = Engine(config: loadConfig(), log: say)
    e.takeOverBrightness()
    await e.tick()
}

@MainActor func watch() {
    let config = loadConfig()
    let e = Engine(config: config, log: say)
    say("dusk \(version) watching every \(Int(config.intervalSeconds))s (source \(config.source), brightness \(config.brightness.mode))"
        + (e.model.map { "; model: \($0.summary)" } ?? ""))
    if e.sensors.read().isEmpty && config.source != .sun {
        say(e.sun == nil ? "no ambient light sensor and no location: only manual commands will work"
                         : "no ambient light sensor: falling back to the sun")
    }
    e.start()
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        // Auto-brightness stays off across restarts; `dusk uninstall` restores it.
        src.setEventHandler {
            say("stopping (signal \(sig))")
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
    engineRef = e
    dispatchMain()
}
nonisolated(unsafe) var engineRef: AnyObject?
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

@MainActor func setAppearance(_ args: [String]) async {
    guard let a = args.first.flatMap(Appearance.init(rawValue:)) else {
        die("usage: dusk appearance light|dark [--learn]", code: 64)
    }
    if args.contains("--learn") {
        // A correction needs five minutes to stand; the running app or agent
        // settles it, so this only records it as pending.
        let e = Engine(config: loadConfig(), log: say)
        await e.set(a, source: "cli")
    } else {
        do { try SystemAppearance.set(a) } catch { die("\(error)") }
    }
}

@MainActor func modelCommand(_ args: [String]) async {
    let e = Engine(config: loadConfig(), log: { print($0) })
    if args.first == "retrain" { await e.retrain() }
    guard let m = e.model else {
        print("no model yet: \(e.confirmedCorrections) confirmed correction(s)"); return
    }
    print("\(m.summary)")
    print("  features: \(m.features.joined(separator: ", "))")
    print(String(format: "  %d correction(s), %d example(s), cross-validated %.0f%% right on corrections, loss %.3f",
                 m.corrections, m.examples, m.correctionAccuracy * 100, m.loss))
    print("  trained \(m.trainedAt)")
}

func correctionsCommand() {
    guard let store = try? Store() else { die("cannot open the history") }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    for state in [Store.CorrectionState.confirmed, .pending, .reverted] {
        for c in store.corrections(state) {
            print("\(f.string(from: c.time))  \(state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) → \(c.to.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  \(c.source.padding(toLength: 9, withPad: " ", startingAt: 0))  \(lux(c.sample.medianLux))"
                  + (c.sample.sunElevation.map { String(format: ", sun %.1f°", $0) } ?? "")
                  + (c.sample.weather.map { String(format: ", %.0f W/m²", $0.shortwave) } ?? "")
                  + (c.sample.cameras.isEmpty ? "" : ", \(c.sample.cameras.count) photo(s)"))
        }
    }
}

func setBrightness(_ args: [String]) {
    guard let s = args.first, var v = Double(s.replacingOccurrences(of: "%", with: "")) else {
        die("usage: dusk brightness <0…1 or 0%…100%>", code: 64)
    }
    if s.hasSuffix("%") || v > 1 { v /= 100 }
    let d = DisplayControl()
    do { try d.fade(d.displays().map { ($0.id, v) }) } catch { die("\(error)") }
}

func configCommand(_ args: [String]) {
    var config = loadConfig()
    if args.first == "init" {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--lat": config.latitude = it.next().flatMap(Double.init)
            case "--lon": config.longitude = it.next().flatMap(Double.init)
            default: die("unknown option \(a)", code: 64)
            }
        }
        do { try config.validate(); try config.save() } catch { die("\(error)") }
        print("wrote \(Config.defaultURL.path)")
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! enc.encode(config), as: UTF8.self))
}

@discardableResult
func launchctl(_ args: [String], quiet: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    if quiet {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func install() {
    // argv[0] is just "dusk" when run from PATH; ask the loader for the real file.
    guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
          path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
        die("cannot determine the path of the dusk executable")
    }
    if path.contains("/.build/") {
        FileHandle.standardError.write(Data("dusk: note: installing the agent from a build directory; `swift build` will replace it under the running agent\n".utf8))
    }
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [path, "watch"],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ProcessType": "Background",
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
    ]
    do {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    } catch { die("writing \(plistURL.path): \(error)") }
    launchctl(["bootout", "gui/\(getuid())/\(label)"], quiet: true)
    guard launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else { die("launchctl bootstrap failed") }
    print("installed \(plistURL.path)\nlog: \(logURL.path)")
}

@MainActor func uninstall() {
    launchctl(["bootout", "gui/\(getuid())/\(label)"], quiet: true)
    try? FileManager.default.removeItem(at: plistURL)
    Engine(config: loadConfig(), log: { print($0) }).restoreBrightness()
    print("removed \(plistURL.path)")
}

func help() {
    print("""
    dusk \(version) — dark mode and display brightness from the room's light

      dusk status                  sensors, sun, displays, and what dusk would do
      dusk sense [SECONDS]         print ambient light (repeat every SECONDS to calibrate)
      dusk run                     decide once and apply, without the hold time
      dusk watch                   keep deciding (what the launch agent runs)
      dusk install | uninstall     manage the launch agent (\(label))
      dusk appearance light|dark [--learn]   set the appearance (and teach dusk)
      dusk model [retrain]         the learned predictor
      dusk corrections             every manual switch and what became of it
      dusk brightness 0.8 | 80%    set every display's brightness by hand
      dusk config [init --lat N --lon N]   show, or write, \(Config.defaultURL.path)
    """)
}

// MARK: entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "status": await status()
case "sense": sense(Array(args.dropFirst()))
case "run": await runOnce()
case "watch": watch()
case "install": install()
case "uninstall": uninstall()
case "appearance": await setAppearance(Array(args.dropFirst()))
case "model": await modelCommand(Array(args.dropFirst()))
case "corrections": correctionsCommand()
case "brightness": setBrightness(Array(args.dropFirst()))
case "config": configCommand(Array(args.dropFirst()))
case "version", "--version": print("dusk \(version)")
case "help", "--help", "-h": help()
default: help(); exit(64)
}
