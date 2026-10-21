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

func status() {
    let config = loadConfig()
    let c = Controller(config: config)
    let s = c.snapshot()
    print("dusk \(version)   config: \(Config.defaultURL.path)\(FileManager.default.fileExists(atPath: Config.defaultURL.path) ? "" : " (defaults)")")
    print("")
    print("ambient light")
    if s.readings.isEmpty { print("  no sensor found") }
    for r in s.readings {
        print("  \(r.product) @ \(String(format: "0x%08x", r.locationID)): \(lux(r.lux))"
              + (r.kelvin.map { String(format: ", %.0f K", $0) } ?? ""))
    }
    if s.readings.count > 1 { print("  median: \(lux(s.lux))") }
    print("")
    print("sun")
    if let sun = c.sun, let el = s.sunElevation {
        let rise = sun.crossings(on: Date(), threshold: config.sunThreshold(rising: true))?.rise
        let set = sun.crossings(on: Date(), threshold: config.sunThreshold(rising: false))?.set
        print(String(format: "  elevation %.1f°, %@, %@", el, sun.isRising(at: Date()) ? "rising" : "setting",
                     s.sunUp == true ? "counts as day" : "counts as night")
              + "; day today \(rise.map(time) ?? "–")–\(set.map(time) ?? "–")")
    } else {
        print("  no location configured (set latitude/longitude)")
    }
    print("")
    let v = verdict(source: config.source, lux: s.lux, sunUp: s.sunUp,
                    darkBelow: config.darkBelowLux, lightAbove: config.lightAboveLux)
    print("appearance: \(s.appearance)   verdict (\(config.source)): \(v.map { "\($0)" } ?? "keep (within \(fmtBand(config)))")")
    if SystemAppearance.switchesAutomatically {
        print("  warning: System Settings' appearance is set to Auto, which will fight dusk")
    }
    print("")
    print("displays (brightness mode: \(config.brightness.mode))")
    for d in c.displays.displays() {
        let auto = c.displays.autoBrightness(of: d.id).map { $0 ? "auto-brightness on" : "auto-brightness off" } ?? "no auto-brightness"
        print("  \(d.name)\(d.isMain ? " (main)" : ""): \(pct(c.displays.brightness(of: d.id))), \(auto)")
    }
    if config.brightness.mode == .curve, let l = s.lux {
        print("  curve target at \(lux(l)) in \(s.appearance) mode: \(pct(config.brightness.curve(for: s.appearance).brightness(forLux: l)))")
    }
    print("")
    let loaded = launchctl(["print", "gui/\(getuid())/\(label)"], quiet: true) == 0
    print("agent: \(loaded ? "running (\(plistURL.path))" : "not installed")")
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

func runOnce() {
    let c = Controller(config: loadConfig(), log: say)
    c.takeOverBrightness()
    c.tick(immediate: true)
}

func watch() {
    let config = loadConfig()
    let c = Controller(config: config, log: say)
    say("dusk \(version) watching every \(Int(config.intervalSeconds))s (source \(config.source), brightness \(config.brightness.mode))")
    if c.sensors.read().isEmpty && config.source != .sun {
        say(c.sun == nil ? "no ambient light sensor and no location: only manual commands will work"
                         : "no ambient light sensor: falling back to the sun")
    }
    c.takeOverBrightness()
    c.tick()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + config.intervalSeconds,
                   repeating: config.intervalSeconds, leeway: .seconds(2))
    timer.setEventHandler { c.tick() }
    timer.resume()
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        // Auto-brightness stays off across restarts (launchd restarts the agent
        // on every `kickstart -k`, and handing it back for a second makes the
        // displays visibly dip); `dusk uninstall` is what restores it.
        src.setEventHandler {
            say("stopping (signal \(sig))")
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
    dispatchMain()
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func setAppearance(_ args: [String]) {
    guard let a = args.first.flatMap(Appearance.init(rawValue:)) else { die("usage: dusk appearance light|dark", code: 64) }
    do { try SystemAppearance.set(a) } catch { die("\(error)") }
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

func uninstall() {
    launchctl(["bootout", "gui/\(getuid())/\(label)"], quiet: true)
    try? FileManager.default.removeItem(at: plistURL)
    Controller(config: loadConfig(), log: { print($0) }).restoreBrightness()
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
      dusk appearance light|dark   set the appearance by hand
      dusk brightness 0.8 | 80%    set every display's brightness by hand
      dusk config [init --lat N --lon N]   show, or write, \(Config.defaultURL.path)
    """)
}

// MARK: entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "status": status()
case "sense": sense(Array(args.dropFirst()))
case "run": runOnce()
case "watch": watch()
case "install": install()
case "uninstall": uninstall()
case "appearance": setAppearance(Array(args.dropFirst()))
case "brightness": setBrightness(Array(args.dropFirst()))
case "config": configCommand(Array(args.dropFirst()))
case "version", "--version": print("dusk \(version)")
case "help", "--help", "-h": help()
default: help(); exit(64)
}
